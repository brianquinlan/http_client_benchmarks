// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

package main

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/quic-go/quic-go/http3"
)

type testServer struct {
	server *benchServer
	ports  originPorts
	roots  *x509.CertPool
}

func startTestServer(t testing.TB) *testServer {
	t.Helper()
	ca, caKey, caPath, err := loadOrCreateCA(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	leaf, err := issueLeaf(ca, caKey)
	if err != nil {
		t.Fatal(err)
	}
	server, err := newBenchServer(false)
	if err != nil {
		t.Fatal(err)
	}
	ports, err := server.startOrigin("127.0.0.1", leaf)
	if err != nil {
		t.Fatal(err)
	}
	caPEM, err := os.ReadFile(caPath)
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(caPEM) {
		t.Fatal("failed to parse the CA certificate")
	}
	return &testServer{server: server, ports: ports, roots: roots}
}

// client returns an HTTP client that only speaks the given protocol.
func (s *testServer) client(t testing.TB, protocol string) *http.Client {
	t.Helper()
	tlsConfig := &tls.Config{RootCAs: s.roots}
	switch protocol {
	case "h1":
		return &http.Client{Transport: &http.Transport{
			Proxy:           nil,
			TLSClientConfig: tlsConfig,
			// Reuse connections rather than exhausting ephemeral ports when
			// requests are sent in parallel.
			MaxIdleConnsPerHost: 256,
			// A non-nil, empty map disables HTTP/2.
			TLSNextProto: map[string]func(string, *tls.Conn) http.RoundTripper{},
		}}
	case "h2":
		return &http.Client{Transport: &http.Transport{
			Proxy:               nil,
			TLSClientConfig:     tlsConfig,
			MaxIdleConnsPerHost: 256,
			ForceAttemptHTTP2:   true,
		}}
	case "h3":
		transport := &http3.Transport{TLSClientConfig: tlsConfig}
		t.Cleanup(func() { transport.Close() })
		return &http.Client{Transport: transport}
	}
	t.Fatalf("unknown protocol %q", protocol)
	return nil
}

func get(t *testing.T, client *http.Client, url string) (*http.Response, []byte) {
	t.Helper()
	resp, err := client.Get(url)
	if err != nil {
		t.Fatalf("GET %s: %v", url, err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("GET %s: reading body: %v", url, err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET %s: status %d: %s", url, resp.StatusCode, body)
	}
	return resp, body
}

func TestProtocols(t *testing.T) {
	s := startTestServer(t)
	tests := []struct {
		name     string
		client   string
		url      string
		wantHTTP string
	}{
		{"h1c", "h1", fmt.Sprintf("http://127.0.0.1:%d", s.ports.H1C), "HTTP/1.1"},
		// The client offers HTTP/2 but the listener only accepts HTTP/1.1.
		{"h1", "h2", fmt.Sprintf("https://127.0.0.1:%d", s.ports.H1), "HTTP/1.1"},
		{"h2", "h2", fmt.Sprintf("https://127.0.0.1:%d", s.ports.H2), "HTTP/2.0"},
		{"h3 via TCP", "h2", fmt.Sprintf("https://localhost:%d", s.ports.H3), "HTTP/2.0"},
		{"h3", "h3", fmt.Sprintf("https://localhost:%d", s.ports.H3), "HTTP/3.0"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			resp, body := get(t, s.client(t, test.client), test.url+"/bytes?size=100000")
			if len(body) != 100000 {
				t.Errorf("got %d bytes, want 100000", len(body))
			}
			if got := resp.Header.Get("X-Protocol"); got != test.wantHTTP {
				t.Errorf("X-Protocol = %q, want %q", got, test.wantHTTP)
			}
			if got := resp.Header.Get("Cache-Control"); got != "no-store" {
				t.Errorf("Cache-Control = %q, want no-store", got)
			}
		})
	}
}

func TestHTTP3Bootstrap(t *testing.T) {
	s := startTestServer(t)
	resp, _ := get(t, s.client(t, "h2"), fmt.Sprintf("https://localhost:%d/bytes", s.ports.H3))
	want := fmt.Sprintf(`h3=":%d"; ma=86400`, s.ports.H3)
	if got := resp.Header.Get("Alt-Svc"); got != want {
		t.Errorf("Alt-Svc = %q, want %q", got, want)
	}
	s.server.stats.reset()
	get(t, s.client(t, "h3"), fmt.Sprintf("https://localhost:%d/bytes", s.ports.H3))
	snapshot := s.server.stats.snapshot()
	if got := snapshot.Connections[kindH3QUIC]; got.Opened != 1 || got.Used != 1 {
		t.Errorf("h3quic connections = %+v, want one opened and used", got)
	}
	if got := snapshot.Requests["HTTP/3.0"]; got != 1 {
		t.Errorf("HTTP/3.0 requests = %d, want 1", got)
	}
}

func TestDiscard(t *testing.T) {
	s := startTestServer(t)
	for _, protocol := range []string{"h2", "h3"} {
		t.Run(protocol, func(t *testing.T) {
			port := s.ports.H2
			if protocol == "h3" {
				port = s.ports.H3
			}
			body := bytes.Repeat([]byte("x"), 3<<20)
			resp, err := s.client(t, protocol).Post(
				fmt.Sprintf("https://localhost:%d/discard", port),
				"application/octet-stream", bytes.NewReader(body))
			if err != nil {
				t.Fatal(err)
			}
			defer resp.Body.Close()
			got, _ := io.ReadAll(resp.Body)
			if string(got) != strconv.Itoa(len(body)) {
				t.Errorf("got %q, want %d", got, len(body))
			}
		})
	}
}

func TestServerSentEvents(t *testing.T) {
	s := startTestServer(t)
	resp, err := s.client(t, "h1").Get(
		fmt.Sprintf("http://127.0.0.1:%d/sse?events=5&size=64&interval_us=100", s.ports.H1C))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	scanner := bufio.NewScanner(resp.Body)
	events := 0
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			continue
		}
		fields := strings.Fields(strings.TrimPrefix(line, "data: "))
		if len(line) != 62 || len(fields) != 3 || fields[0] != strconv.Itoa(events) {
			t.Errorf("unexpected event %q", line)
		}
		events++
	}
	if events != 5 {
		t.Errorf("got %d events, want 5", events)
	}
}

func TestHeaders(t *testing.T) {
	s := startTestServer(t)
	req, _ := http.NewRequest("GET",
		fmt.Sprintf("https://127.0.0.1:%d/headers?count=10&size=32", s.ports.H2), nil)
	for i := range 7 {
		req.Header.Set(fmt.Sprintf("X-Bench-Request-%d", i), "value")
	}
	resp, err := s.client(t, "h2").Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if string(body) != "7" {
		t.Errorf("server counted %q request headers, want 7", body)
	}
	for i := range 10 {
		if v := resp.Header.Get(fmt.Sprintf("X-Bench-Response-%d", i)); len(v) != 32 {
			t.Errorf("X-Bench-Response-%d = %q, want 32 bytes", i, v)
		}
	}
}

func TestJSONAndText(t *testing.T) {
	s := startTestServer(t)
	client := s.client(t, "h1")
	base := fmt.Sprintf("http://127.0.0.1:%d", s.ports.H1C)

	_, body := get(t, client, base+"/json?items=25")
	var items []map[string]any
	if err := json.Unmarshal(body, &items); err != nil || len(items) != 25 {
		t.Errorf("got %d items (err=%v), want 25", len(items), err)
	}

	// Disable Go's transparent decompression to check the encoded body.
	transport := &http.Transport{Proxy: nil, DisableCompression: true}
	resp, compressed := get(t, &http.Client{Transport: transport}, base+"/text?size=500000&gzip=1")
	if resp.Header.Get("Content-Encoding") != "gzip" {
		t.Errorf("Content-Encoding = %q, want gzip", resp.Header.Get("Content-Encoding"))
	}
	zr, err := gzip.NewReader(bytes.NewReader(compressed))
	if err != nil {
		t.Fatal(err)
	}
	plain, err := io.ReadAll(zr)
	if err != nil || len(plain) != 500000 {
		t.Errorf("decompressed %d bytes (err=%v), want 500000", len(plain), err)
	}
	if len(compressed)*3 > len(plain) {
		t.Errorf("text compressed to %d bytes; expected at least 3x compression", len(compressed))
	}
}

func TestCertificateNameConstraints(t *testing.T) {
	dir := t.TempDir()
	ca, caKey, _, err := loadOrCreateCA(dir)
	if err != nil {
		t.Fatal(err)
	}
	// The CA is reused rather than regenerated.
	again, _, _, err := loadOrCreateCA(dir)
	if err != nil || !again.Equal(ca) {
		t.Fatalf("loadOrCreateCA did not reuse the existing CA (err=%v)", err)
	}
	leaf, err := issueLeaf(ca, caKey)
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	roots.AddCert(ca)
	for _, name := range []string{"localhost", "127.0.0.1", "::1"} {
		if _, err := leaf.Leaf.Verify(x509.VerifyOptions{Roots: roots, DNSName: name}); err != nil {
			t.Errorf("verifying for %s: %v", name, err)
		}
	}
	if ca.PermittedDNSDomains[0] != "localhost" || !ca.PermittedDNSDomainsCritical {
		t.Errorf("CA is not constrained to localhost: %v", ca.PermittedDNSDomains)
	}
	if len(ca.ExtKeyUsage) != 1 || ca.ExtKeyUsage[0] != x509.ExtKeyUsageServerAuth {
		t.Errorf("CA is not restricted to server authentication: %v", ca.ExtKeyUsage)
	}
}

func TestProgress(t *testing.T) {
	s := startTestServer(t)
	client := s.client(t, "h1")
	base := fmt.Sprintf("http://127.0.0.1:%d", s.ports.H1C)

	get(t, client, base+"/bytes?size=100000&id=download")
	if n, ok := s.server.progress.get("download"); !ok || n != 100000 {
		t.Errorf("download progress = %d (found: %v), want 100000", n, ok)
	}

	resp, err := client.Post(base+"/discard?id=upload", "application/octet-stream",
		bytes.NewReader(make([]byte, 50000)))
	if err != nil {
		t.Fatal(err)
	}
	drain(resp.Body)
	resp.Body.Close()
	if n, ok := s.server.progress.get("upload"); !ok || n != 50000 {
		t.Errorf("upload progress = %d (found: %v), want 50000", n, ok)
	}

	// When the client stops reading, the server stops writing once the
	// socket buffers are full.
	resp, err = client.Get(base + "/bytes?size=268435456&id=paused&write_size=16384")
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(500 * time.Millisecond)
	n, _ := s.server.progress.get("paused")
	resp.Body.Close()
	if n == 0 || n > 64<<20 {
		t.Errorf("the server wrote %d bytes to a client that was not reading", n)
	}

	s.server.progress.reset()
	if _, ok := s.server.progress.get("download"); ok {
		t.Error("progress was not reset")
	}
}
