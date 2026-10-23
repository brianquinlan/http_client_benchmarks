// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// Command server is the HTTP server used by package:http_client_benchmarks.
//
// The same endpoints are served over several protocols, each on its own port,
// so that a client can be steered towards a particular protocol:
//
//   - h1c: HTTP/1.1 without TLS.
//   - h1:  HTTP/1.1 over TLS. Only "http/1.1" is offered during ALPN.
//   - h2:  HTTP/2 over TLS. Only "h2" is offered during ALPN.
//   - h3:  HTTP/3 over QUIC. A UDP socket serves HTTP/3 and a TCP socket with
//     the same port number advertises it (using an "Alt-Svc" header) to
//     clients that have not yet discovered HTTP/3. The TCP socket closes
//     every connection after one response so that clients switch to HTTP/3
//     as soon as possible.
//
// The set of listeners is repeated for each "origin" so that clients can be
// benchmarked when talking to several hosts at once.
//
// Endpoints:
//
//   - GET  /bytes?size=N&delay_ms=D&chunked=1&write_size=W
//     Responds with N incompressible bytes after waiting D milliseconds,
//     writing at most W bytes at a time (default and maximum 1 MiB). The
//     "Content-Length" header is omitted if chunked=1.
//   - GET  /sse?events=N&size=S&interval_us=I
//     Streams N server-sent events, each S bytes long, one every I
//     microseconds. Every event has the form "data: <seq> <unix_us> ...".
//   - POST /discard
//     Reads and discards the request body and responds with its length.
//   - GET  /headers?count=N&size=S
//     Responds with N "X-Bench-Response-<i>" headers, each with an S byte
//     value. The body is the number of "X-Bench-Request-*" request headers.
//   - GET  /json?items=N
//     Responds with a JSON array containing N realistic "feed items".
//   - GET  /text?size=N&gzip=1
//     Responds with N bytes of compressible text, gzip-encoded if gzip=1.
//
// Every response includes an "X-Protocol" header containing the protocol that
// the server used to receive the request (e.g. "HTTP/2.0") and a
// "Cache-Control: no-store" header.
//
// If a request to /bytes or /discard has an "id=<string>" query parameter,
// the server counts the body bytes that it has written or read so far for
// that ID (see /progress below). Writes are counted once they complete, so
// the count for /bytes can lag by up to one write (see write_size).
//
// A separate, cleartext "control" port serves:
//
//   - GET  /stats: connection and request counters, as JSON.
//   - POST /stats/reset: resets the counters and forgets all progress IDs.
//   - GET  /progress?id=<string>: the number of body bytes written (/bytes)
//     or read (/discard) so far for the request with that ID, as JSON:
//     {"bytes": N}.
//
// The server prints a single line of JSON to stdout once it is ready to accept
// connections and exits when stdin is closed.
package main

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"log/slog"
	"math/big"
	mathrand "math/rand/v2"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/quic-go/quic-go"
	"github.com/quic-go/quic-go/http3"
)

// The kinds of listeners created for each origin.
const (
	kindH1C    = "h1c"
	kindH1     = "h1"
	kindH2     = "h2"
	kindH3TCP  = "h3tcp"
	kindH3QUIC = "h3quic"
)

var allKinds = []string{kindH1C, kindH1, kindH2, kindH3TCP, kindH3QUIC}

// connIDKey is the context key for the unique ID of a connection.
type connIDKey struct{}

var nextConnID atomic.Uint64

// connStats tracks the connections accepted by one kind of listener.
type connStats struct {
	opened   int64           // Connections accepted since the last reset.
	open     int64           // Connections currently open.
	peakOpen int64           // The maximum value of open since the last reset.
	used     map[uint64]bool // Connections that served a request since the last reset.
}

type serverStats struct {
	mu       sync.Mutex
	conns    map[string]*connStats
	requests map[string]int64 // Keyed by request protocol e.g. "HTTP/2.0".
}

func newServerStats() *serverStats {
	s := &serverStats{
		conns:    map[string]*connStats{},
		requests: map[string]int64{},
	}
	for _, kind := range allKinds {
		s.conns[kind] = &connStats{used: map[uint64]bool{}}
	}
	return s
}

func (s *serverStats) connOpened(kind string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.conns[kind]
	c.opened++
	c.open++
	c.peakOpen = max(c.peakOpen, c.open)
}

func (s *serverStats) connClosed(kind string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.conns[kind].open--
}

func (s *serverStats) requestReceived(kind string, connID uint64, proto string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.conns[kind].used[connID] = true
	s.requests[proto]++
}

func (s *serverStats) reset() {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, c := range s.conns {
		c.opened = 0
		c.peakOpen = c.open
		clear(c.used)
	}
	clear(s.requests)
}

type connSnapshot struct {
	Opened   int64 `json:"opened"`
	Used     int   `json:"used"`
	Open     int64 `json:"open"`
	PeakOpen int64 `json:"peakOpen"`
}

type statsSnapshot struct {
	Connections map[string]connSnapshot `json:"connections"`
	Requests    map[string]int64        `json:"requests"`
}

func (s *serverStats) snapshot() statsSnapshot {
	s.mu.Lock()
	defer s.mu.Unlock()
	snapshot := statsSnapshot{
		Connections: map[string]connSnapshot{},
		Requests:    map[string]int64{},
	}
	for kind, c := range s.conns {
		snapshot.Connections[kind] = connSnapshot{
			Opened:   c.opened,
			Used:     len(c.used),
			Open:     c.open,
			PeakOpen: c.peakOpen,
		}
	}
	for proto, n := range s.requests {
		snapshot.Requests[proto] = n
	}
	return snapshot
}

type textBody struct {
	plain   []byte
	gzipped []byte
}

// progressTracker counts the body bytes transferred by requests that have an
// "id" query parameter.
type progressTracker struct {
	counters sync.Map // string -> *atomic.Int64
}

// counter returns the counter for r, or nil if r has no "id" parameter.
func (p *progressTracker) counter(r *http.Request) *atomic.Int64 {
	id := r.URL.Query().Get("id")
	if id == "" {
		return nil
	}
	c, _ := p.counters.LoadOrStore(id, new(atomic.Int64))
	return c.(*atomic.Int64)
}

func (p *progressTracker) get(id string) (int64, bool) {
	c, ok := p.counters.Load(id)
	if !ok {
		return 0, false
	}
	return c.(*atomic.Int64).Load(), true
}

func (p *progressTracker) reset() {
	p.counters.Clear()
}

type benchServer struct {
	stats       *serverStats
	progress    progressTracker
	random      []byte // Incompressible data used for response bodies.
	bufPool     sync.Pool
	jsonCache   sync.Map // int -> []byte
	textCache   sync.Map // int -> *textBody
	headerCache sync.Map // [2]int -> string
	errorLog    *log.Logger
	quicLogger  *slog.Logger
}

func newBenchServer(verbose bool) (*benchServer, error) {
	random := make([]byte, 1<<20)
	if _, err := rand.Read(random); err != nil {
		return nil, err
	}
	s := &benchServer{
		stats:      newServerStats(),
		random:     random,
		errorLog:   log.New(io.Discard, "", 0),
		quicLogger: slog.New(slog.NewTextHandler(io.Discard, nil)),
	}
	if verbose {
		s.errorLog = log.New(os.Stderr, "", log.LstdFlags)
		s.quicLogger = slog.New(slog.NewTextHandler(os.Stderr, nil))
	}
	s.bufPool.New = func() any {
		b := make([]byte, 256<<10)
		return &b
	}
	return s, nil
}

func (s *benchServer) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/bytes", s.handleBytes)
	mux.HandleFunc("/sse", s.handleSSE)
	mux.HandleFunc("/discard", s.handleDiscard)
	mux.HandleFunc("/headers", s.handleHeaders)
	mux.HandleFunc("/json", s.handleJSON)
	mux.HandleFunc("/text", s.handleText)
	return mux
}

// instrument wraps h with the behavior shared by every benchmark listener.
//
// If altSvcPort is not zero then responses advertise HTTP/3 on that port and
// ask the client to close the connection.
func (s *benchServer) instrument(kind string, h http.Handler, altSvcPort int) http.Handler {
	altSvc := fmt.Sprintf(`h3=":%d"; ma=86400`, altSvcPort)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id, _ := r.Context().Value(connIDKey{}).(uint64)
		s.stats.requestReceived(kind, id, r.Proto)
		header := w.Header()
		header.Set("X-Protocol", r.Proto)
		header.Set("Cache-Control", "no-store")
		if altSvcPort != 0 {
			header.Set("Alt-Svc", altSvc)
			// For HTTP/1.1 this closes the connection after the response. For
			// HTTP/2, Go's server sends GOAWAY.
			header.Set("Connection", "close")
		}
		h.ServeHTTP(w, r)
	})
}

func queryInt(q url.Values, name string, defaultValue int) int {
	if v := q.Get(name); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n >= 0 {
			return n
		}
	}
	return defaultValue
}

// sleepUntil waits until t, returning false if ctx is done first.
func sleepUntil(ctx context.Context, t time.Time) bool {
	d := time.Until(t)
	if d <= 0 {
		return ctx.Err() == nil
	}
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-timer.C:
		return true
	case <-ctx.Done():
		return false
	}
}

func drain(r io.Reader) {
	_, _ = io.Copy(io.Discard, r)
}

func (s *benchServer) handleBytes(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	size := queryInt(q, "size", 1024)
	delay := time.Duration(queryInt(q, "delay_ms", 0)) * time.Millisecond
	drain(r.Body)
	if delay > 0 && !sleepUntil(r.Context(), time.Now().Add(delay)) {
		return
	}
	header := w.Header()
	header.Set("Content-Type", "application/octet-stream")
	if q.Get("chunked") != "1" {
		header.Set("Content-Length", strconv.Itoa(size))
	}
	w.WriteHeader(http.StatusOK)
	// The size of each write. Many streaming servers and proxies write small
	// pieces, which some clients handle much less efficiently.
	writeSize := min(max(queryInt(q, "write_size", len(s.random)), 1<<10), len(s.random))
	progress := s.progress.counter(r)
	for size > 0 {
		n := min(size, writeSize)
		if _, err := w.Write(s.random[:n]); err != nil {
			return
		}
		if progress != nil {
			progress.Add(int64(n))
		}
		size -= n
	}
}

func (s *benchServer) handleSSE(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	events := queryInt(q, "events", 100)
	size := queryInt(q, "size", 256)
	interval := time.Duration(queryInt(q, "interval_us", 2000)) * time.Microsecond
	drain(r.Body)

	rc := http.NewResponseController(w)
	w.Header().Set("Content-Type", "text/event-stream")
	w.WriteHeader(http.StatusOK)
	if err := rc.Flush(); err != nil {
		return
	}
	start := time.Now()
	buf := make([]byte, 0, size+64)
	for i := range events {
		// Pace events relative to the start time so that delays don't
		// accumulate.
		if i > 0 && !sleepUntil(r.Context(), start.Add(time.Duration(i)*interval)) {
			return
		}
		buf = append(buf[:0], "data: "...)
		buf = strconv.AppendInt(buf, int64(i), 10)
		buf = append(buf, ' ')
		buf = strconv.AppendInt(buf, time.Now().UnixMicro(), 10)
		buf = append(buf, ' ')
		for len(buf) < size-2 {
			buf = append(buf, 'x')
		}
		buf = append(buf, '\n', '\n')
		if _, err := w.Write(buf); err != nil {
			return
		}
		if err := rc.Flush(); err != nil {
			return
		}
	}
}

func (s *benchServer) handleDiscard(w http.ResponseWriter, r *http.Request) {
	bufp := s.bufPool.Get().(*[]byte)
	defer s.bufPool.Put(bufp)
	buf := *bufp
	progress := s.progress.counter(r)
	var total int64
	for {
		n, err := r.Body.Read(buf)
		total += int64(n)
		if progress != nil {
			progress.Add(int64(n))
		}
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
	}
	w.Header().Set("Content-Type", "text/plain")
	_, _ = io.WriteString(w, strconv.FormatInt(total, 10))
}

// headerValue returns a deterministic, pseudo-random header value.
func (s *benchServer) headerValue(index, size int) string {
	key := [2]int{index, size}
	if v, ok := s.headerCache.Load(key); ok {
		return v.(string)
	}
	const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	rng := mathrand.New(mathrand.NewPCG(uint64(index), uint64(size)))
	b := make([]byte, size)
	for i := range b {
		b[i] = alphabet[rng.IntN(len(alphabet))]
	}
	v := string(b)
	s.headerCache.Store(key, v)
	return v
}

func (s *benchServer) handleHeaders(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	count := min(queryInt(q, "count", 50), 1000)
	size := min(queryInt(q, "size", 64), 8192)
	drain(r.Body)
	received := 0
	for name := range r.Header {
		if strings.HasPrefix(strings.ToLower(name), "x-bench-request-") {
			received++
		}
	}
	header := w.Header()
	for i := range count {
		header.Set("X-Bench-Response-"+strconv.Itoa(i), s.headerValue(i, size))
	}
	header.Set("Content-Type", "text/plain")
	_, _ = io.WriteString(w, strconv.Itoa(received))
}

var words = strings.Fields(`
	alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima
	mike november oscar papa quebec romeo sierra tango uniform victor whiskey
	xray yankee zulu network stream request response client server latency
	throughput protocol connection packet socket buffer header payload cache
	mobile desktop browser native bridge isolate future async benchmark`)

func sentence(rng *mathrand.Rand, n int) string {
	parts := make([]string, n)
	for i := range parts {
		parts[i] = words[rng.IntN(len(words))]
	}
	return strings.Join(parts, " ")
}

func (s *benchServer) jsonBody(items int) []byte {
	if v, ok := s.jsonCache.Load(items); ok {
		return v.([]byte)
	}
	type author struct {
		ID        int    `json:"id"`
		Name      string `json:"name"`
		Handle    string `json:"handle"`
		Followers int    `json:"followers"`
		Verified  bool   `json:"verified"`
	}
	type item struct {
		ID        int      `json:"id"`
		Title     string   `json:"title"`
		Summary   string   `json:"summary"`
		URL       string   `json:"url"`
		Author    author   `json:"author"`
		Tags      []string `json:"tags"`
		Score     float64  `json:"score"`
		Likes     int      `json:"likes"`
		Comments  int      `json:"comments"`
		CreatedAt string   `json:"createdAt"`
	}
	rng := mathrand.New(mathrand.NewPCG(42, uint64(items)))
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	list := make([]item, items)
	for i := range list {
		authorID := rng.IntN(10000)
		list[i] = item{
			ID:      i + 1,
			Title:   sentence(rng, 6),
			Summary: sentence(rng, 20),
			URL:     fmt.Sprintf("https://example.com/items/%d", i+1),
			Author: author{
				ID:        authorID,
				Name:      sentence(rng, 2),
				Handle:    fmt.Sprintf("@user%d", authorID),
				Followers: rng.IntN(1000000),
				Verified:  rng.IntN(10) == 0,
			},
			Tags:      strings.Fields(sentence(rng, 3)),
			Score:     float64(rng.IntN(100000)) / 100,
			Likes:     rng.IntN(5000),
			Comments:  rng.IntN(500),
			CreatedAt: base.Add(time.Duration(rng.IntN(1<<30)) * time.Second).Format(time.RFC3339),
		}
	}
	body, err := json.Marshal(list)
	if err != nil {
		panic(err)
	}
	s.jsonCache.Store(items, body)
	return body
}

func (s *benchServer) handleJSON(w http.ResponseWriter, r *http.Request) {
	items := min(queryInt(r.URL.Query(), "items", 100), 100000)
	drain(r.Body)
	body := s.jsonBody(items)
	header := w.Header()
	header.Set("Content-Type", "application/json")
	header.Set("Content-Length", strconv.Itoa(len(body)))
	_, _ = w.Write(body)
}

func (s *benchServer) textBody(size int) (*textBody, error) {
	if v, ok := s.textCache.Load(size); ok {
		return v.(*textBody), nil
	}
	rng := mathrand.New(mathrand.NewPCG(7, uint64(size)))
	levels := []string{"DEBUG", "INFO", "INFO", "INFO", "WARN", "ERROR"}
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	var plain bytes.Buffer
	plain.Grow(size + 256)
	for i := 0; plain.Len() < size; i++ {
		fmt.Fprintf(&plain,
			"%s %-5s request_id=%08x method=GET path=/api/v1/%s/%d status=%d duration_ms=%d msg=%q\n",
			base.Add(time.Duration(i)*time.Millisecond).Format(time.RFC3339Nano),
			levels[rng.IntN(len(levels))],
			rng.Uint32(),
			words[rng.IntN(len(words))],
			rng.IntN(100000),
			[]int{200, 200, 200, 201, 304, 404, 500}[rng.IntN(7)],
			rng.IntN(2000),
			sentence(rng, 5))
	}
	body := &textBody{plain: plain.Bytes()[:size]}
	var compressed bytes.Buffer
	zw, err := gzip.NewWriterLevel(&compressed, gzip.BestCompression)
	if err != nil {
		return nil, err
	}
	if _, err := zw.Write(body.plain); err != nil {
		return nil, err
	}
	if err := zw.Close(); err != nil {
		return nil, err
	}
	body.gzipped = compressed.Bytes()
	s.textCache.Store(size, body)
	return body, nil
}

func (s *benchServer) handleText(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	size := min(queryInt(q, "size", 1<<20), 256<<20)
	drain(r.Body)
	body, err := s.textBody(size)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	data := body.plain
	header := w.Header()
	header.Set("Content-Type", "text/plain; charset=utf-8")
	if q.Get("gzip") == "1" {
		header.Set("Content-Encoding", "gzip")
		data = body.gzipped
	}
	header.Set("Content-Length", strconv.Itoa(len(data)))
	_, _ = w.Write(data)
}

func newProtocols(http1, http2 bool) *http.Protocols {
	p := new(http.Protocols)
	p.SetHTTP1(http1)
	p.SetHTTP2(http2)
	return p
}

// serveTCP serves handler on ln, using TLS if tlsConfig is not nil.
func (s *benchServer) serveTCP(kind string, ln net.Listener, tlsConfig *tls.Config,
	protocols *http.Protocols, handler http.Handler) {
	srv := &http.Server{
		Handler:           handler,
		TLSConfig:         tlsConfig,
		Protocols:         protocols,
		ReadHeaderTimeout: 30 * time.Second,
		IdleTimeout:       2 * time.Minute,
		HTTP2: &http.HTTP2Config{
			MaxConcurrentStreams: 1000,
			// The largest valid values; larger flow control windows prevent the
			// server from limiting upload throughput.
			MaxReceiveBufferPerConnection: (4 << 20) - 1,
			MaxReceiveBufferPerStream:     (4 << 20) - 1,
		},
		ConnContext: func(ctx context.Context, _ net.Conn) context.Context {
			return context.WithValue(ctx, connIDKey{}, nextConnID.Add(1))
		},
		ConnState: func(_ net.Conn, state http.ConnState) {
			switch state {
			case http.StateNew:
				s.stats.connOpened(kind)
			case http.StateClosed, http.StateHijacked:
				s.stats.connClosed(kind)
			}
		},
		ErrorLog: s.errorLog,
	}
	go func() {
		var err error
		if tlsConfig != nil {
			err = srv.ServeTLS(ln, "", "")
		} else {
			err = srv.Serve(ln)
		}
		log.Fatalf("%s listener failed: %v", kind, err)
	}()
}

// serveQUIC serves HTTP/3 on conn.
func (s *benchServer) serveQUIC(conn net.PacketConn, tlsConfig *tls.Config, handler http.Handler) {
	srv := &http3.Server{
		Handler:   handler,
		TLSConfig: http3.ConfigureTLSConfig(tlsConfig),
		QUICConfig: &quic.Config{
			MaxIncomingStreams:             1000,
			MaxIdleTimeout:                 2 * time.Minute,
			InitialStreamReceiveWindow:     1 << 20,
			MaxStreamReceiveWindow:         8 << 20,
			InitialConnectionReceiveWindow: 2 << 20,
			MaxConnectionReceiveWindow:     16 << 20,
			Allow0RTT:                      true,
		},
		ConnContext: func(ctx context.Context, c *quic.Conn) context.Context {
			s.stats.connOpened(kindH3QUIC)
			go func() {
				<-c.Context().Done()
				s.stats.connClosed(kindH3QUIC)
			}()
			return context.WithValue(ctx, connIDKey{}, nextConnID.Add(1))
		},
		Logger: s.quicLogger,
	}
	go func() {
		err := srv.Serve(conn)
		log.Fatalf("%s listener failed: %v", kindH3QUIC, err)
	}()
}

func listenTCP(host string) (net.Listener, int, error) {
	ln, err := net.Listen("tcp", net.JoinHostPort(host, "0"))
	if err != nil {
		return nil, 0, err
	}
	return ln, ln.Addr().(*net.TCPAddr).Port, nil
}

// listenTCPAndUDP binds a TCP and a UDP socket with the same port number.
func listenTCPAndUDP(host string) (net.Listener, net.PacketConn, int, error) {
	for range 50 {
		tcp, port, err := listenTCP(host)
		if err != nil {
			return nil, nil, 0, err
		}
		udp, err := net.ListenPacket("udp", net.JoinHostPort(host, strconv.Itoa(port)))
		if err == nil {
			return tcp, udp, port, nil
		}
		tcp.Close()
	}
	return nil, nil, 0, errors.New("unable to bind TCP and UDP sockets to the same port")
}

type originPorts struct {
	H1C int `json:"h1c"`
	H1  int `json:"h1"`
	H2  int `json:"h2"`
	H3  int `json:"h3"`
}

// startOrigin starts one set of listeners, one per protocol.
func (s *benchServer) startOrigin(host string, cert tls.Certificate) (originPorts, error) {
	var ports originPorts
	base := &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS12,
	}
	handler := s.routes()

	h1c, port, err := listenTCP(host)
	if err != nil {
		return ports, err
	}
	ports.H1C = port
	s.serveTCP(kindH1C, h1c, nil, newProtocols(true, false),
		s.instrument(kindH1C, handler, 0))

	h1, port, err := listenTCP(host)
	if err != nil {
		return ports, err
	}
	ports.H1 = port
	s.serveTCP(kindH1, h1, base.Clone(), newProtocols(true, false),
		s.instrument(kindH1, handler, 0))

	h2, port, err := listenTCP(host)
	if err != nil {
		return ports, err
	}
	ports.H2 = port
	s.serveTCP(kindH2, h2, base.Clone(), newProtocols(false, true),
		s.instrument(kindH2, handler, 0))

	h3tcp, h3udp, port, err := listenTCPAndUDP(host)
	if err != nil {
		return ports, err
	}
	ports.H3 = port
	s.serveTCP(kindH3TCP, h3tcp, base.Clone(), newProtocols(true, true),
		s.instrument(kindH3TCP, handler, port))
	s.serveQUIC(h3udp, base.Clone(), s.instrument(kindH3QUIC, handler, 0))
	return ports, nil
}

// startControl starts the cleartext control server and returns its port.
func (s *benchServer) startControl(host string) (int, error) {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /stats", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(s.stats.snapshot())
	})
	mux.HandleFunc("POST /stats/reset", func(w http.ResponseWriter, _ *http.Request) {
		s.stats.reset()
		s.progress.reset()
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("GET /progress", func(w http.ResponseWriter, r *http.Request) {
		n, ok := s.progress.get(r.URL.Query().Get("id"))
		if !ok {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]int64{"bytes": n})
	})
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, "ok")
	})
	ln, port, err := listenTCP(host)
	if err != nil {
		return 0, err
	}
	srv := &http.Server{Handler: mux, ErrorLog: s.errorLog, ReadHeaderTimeout: 30 * time.Second}
	go func() {
		log.Fatalf("control listener failed: %v", srv.Serve(ln))
	}()
	return port, nil
}

func randomSerial() (*big.Int, error) {
	return rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 127))
}

func writePEM(path, blockType string, der []byte, mode os.FileMode) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, mode)
	if err != nil {
		return err
	}
	if err := pem.Encode(f, &pem.Block{Type: blockType, Bytes: der}); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

func readPEM(path, blockType string) ([]byte, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(data)
	if block == nil || block.Type != blockType {
		return nil, fmt.Errorf("%s does not contain a %q PEM block", path, blockType)
	}
	return block.Bytes, nil
}

func loadCA(certPath, keyPath string) (*x509.Certificate, crypto.Signer, error) {
	certDER, err := readPEM(certPath, "CERTIFICATE")
	if err != nil {
		return nil, nil, err
	}
	cert, err := x509.ParseCertificate(certDER)
	if err != nil {
		return nil, nil, err
	}
	keyDER, err := readPEM(keyPath, "PRIVATE KEY")
	if err != nil {
		return nil, nil, err
	}
	key, err := x509.ParsePKCS8PrivateKey(keyDER)
	if err != nil {
		return nil, nil, err
	}
	signer, ok := key.(crypto.Signer)
	if !ok {
		return nil, nil, fmt.Errorf("%s does not contain a signing key", keyPath)
	}
	return cert, signer, nil
}

// loadOrCreateCA returns the benchmark certificate authority, creating it if
// necessary.
//
// The CA is persisted so that it only has to be trusted once (e.g. in the
// macOS keychain, which is needed to benchmark CupertinoClient over TLS). It
// uses X.509 name constraints and is restricted to TLS server authentication
// so that, even if its private key were leaked, it could only be used to
// issue server certificates for loopback addresses.
func loadOrCreateCA(dir string) (*x509.Certificate, crypto.Signer, string, error) {
	certPath := filepath.Join(dir, "ca.pem")
	keyPath := filepath.Join(dir, "ca-key.pem")
	if cert, key, err := loadCA(certPath, keyPath); err == nil {
		serverAuthOnly := len(cert.ExtKeyUsage) == 1 &&
			cert.ExtKeyUsage[0] == x509.ExtKeyUsageServerAuth
		if time.Until(cert.NotAfter) > 30*24*time.Hour && serverAuthOnly {
			return cert, key, certPath, nil
		}
		fmt.Fprintf(os.Stderr, "Regenerating the benchmark CA %s\n", certPath)
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, nil, "", err
	}

	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, nil, "", err
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, "", err
	}
	serial, err := randomSerial()
	if err != nil {
		return nil, nil, "", err
	}
	now := time.Now()
	template := &x509.Certificate{
		SerialNumber: serial,
		Subject: pkix.Name{
			CommonName:   "package:http benchmark CA (localhost only)",
			Organization: []string{"http_client_benchmarks"},
		},
		NotBefore:                   now.Add(-time.Hour),
		NotAfter:                    now.AddDate(10, 0, 0),
		KeyUsage:                    x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		ExtKeyUsage:                 []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid:       true,
		IsCA:                        true,
		MaxPathLenZero:              true,
		PermittedDNSDomainsCritical: true,
		PermittedDNSDomains:         []string{"localhost"},
		PermittedIPRanges: []*net.IPNet{
			{IP: net.IPv4(127, 0, 0, 0).To4(), Mask: net.CIDRMask(8, 32)},
			{IP: net.IPv6loopback, Mask: net.CIDRMask(128, 128)},
		},
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		return nil, nil, "", err
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return nil, nil, "", err
	}
	if err := writePEM(keyPath, "PRIVATE KEY", keyDER, 0o600); err != nil {
		return nil, nil, "", err
	}
	if err := writePEM(certPath, "CERTIFICATE", der, 0o644); err != nil {
		return nil, nil, "", err
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		return nil, nil, "", err
	}
	return cert, key, certPath, nil
}

// issueLeaf creates a short-lived server certificate signed by the CA.
func issueLeaf(ca *x509.Certificate, caKey crypto.Signer) (tls.Certificate, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, err
	}
	serial, err := randomSerial()
	if err != nil {
		return tls.Certificate{}, err
	}
	now := time.Now()
	template := &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: "localhost"},
		DNSNames:     []string{"localhost"},
		IPAddresses:  []net.IP{net.IPv4(127, 0, 0, 1), net.IPv6loopback},
		NotBefore:    now.Add(-time.Hour),
		NotAfter:     now.Add(7 * 24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, template, ca, &key.PublicKey, caKey)
	if err != nil {
		return tls.Certificate{}, err
	}
	leaf, err := x509.ParseCertificate(der)
	if err != nil {
		return tls.Certificate{}, err
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key, Leaf: leaf}, nil
}

func moduleVersion(path string) string {
	if info, ok := debug.ReadBuildInfo(); ok {
		for _, dep := range info.Deps {
			if dep.Path == path {
				return dep.Version
			}
		}
	}
	return "unknown"
}

type startupInfo struct {
	Event         string        `json:"event"`
	Host          string        `json:"host"`
	ControlPort   int           `json:"controlPort"`
	Origins       []originPorts `json:"origins"`
	CACertificate string        `json:"caCertificate"`
	GoVersion     string        `json:"goVersion"`
	QUICGoVersion string        `json:"quicGoVersion"`
}

func run() error {
	certDir := flag.String("cert-dir", "", "directory containing (or that will contain) the benchmark CA")
	host := flag.String("host", "127.0.0.1", "address to listen on")
	origins := flag.Int("origins", 4, "number of origins (sets of listeners) to start")
	exitOnEOF := flag.Bool("exit-on-stdin-eof", true, "exit when stdin is closed")
	verbose := flag.Bool("verbose", false, "log server errors to stderr")
	flag.Parse()
	if *certDir == "" {
		return errors.New("-cert-dir is required")
	}
	if *origins < 1 {
		return errors.New("-origins must be at least 1")
	}
	absCertDir, err := filepath.Abs(*certDir)
	if err != nil {
		return err
	}
	// quic-go warns if it can't increase the UDP receive buffer size, which is
	// common on macOS and harmless for loopback benchmarks.
	os.Setenv("QUIC_GO_DISABLE_RECEIVE_BUFFER_WARNING", "true")

	ca, caKey, caPath, err := loadOrCreateCA(absCertDir)
	if err != nil {
		return fmt.Errorf("loading the benchmark CA: %w", err)
	}
	leaf, err := issueLeaf(ca, caKey)
	if err != nil {
		return fmt.Errorf("issuing the server certificate: %w", err)
	}
	server, err := newBenchServer(*verbose)
	if err != nil {
		return err
	}
	info := startupInfo{
		Event:         "ready",
		Host:          *host,
		CACertificate: caPath,
		GoVersion:     runtime.Version(),
		QUICGoVersion: moduleVersion("github.com/quic-go/quic-go"),
	}
	for range *origins {
		ports, err := server.startOrigin(*host, leaf)
		if err != nil {
			return fmt.Errorf("starting listeners: %w", err)
		}
		info.Origins = append(info.Origins, ports)
	}
	if info.ControlPort, err = server.startControl(*host); err != nil {
		return fmt.Errorf("starting the control listener: %w", err)
	}
	if err := json.NewEncoder(os.Stdout).Encode(info); err != nil {
		return err
	}

	done := make(chan struct{})
	if *exitOnEOF {
		go func() {
			_, _ = io.Copy(io.Discard, os.Stdin)
			close(done)
		}()
	}
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	select {
	case <-done:
	case <-signals:
	}
	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}
