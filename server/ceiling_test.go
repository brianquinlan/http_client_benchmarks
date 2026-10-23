// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

package main

import (
	"bytes"
	"fmt"
	"io"
	"net/http"
	"testing"
)

// These benchmarks measure the server's throughput using Go's HTTP clients.
// They establish the ceiling that the server can sustain on this machine:
// client results that approach these numbers are limited by the server (or
// the machine) rather than by the client. Run them with:
//
//	go test -bench=. -run='^$'

const benchmarkPayload = 64 << 20

func (s *testServer) baseURL(protocol string) string {
	switch protocol {
	case "h1c":
		return fmt.Sprintf("http://127.0.0.1:%d", s.ports.H1C)
	case "h1":
		return fmt.Sprintf("https://127.0.0.1:%d", s.ports.H1)
	case "h2":
		return fmt.Sprintf("https://127.0.0.1:%d", s.ports.H2)
	case "h3":
		return fmt.Sprintf("https://127.0.0.1:%d", s.ports.H3)
	}
	panic("unknown protocol " + protocol)
}

func benchmarkProtocols(b *testing.B, run func(b *testing.B, client *http.Client, baseURL string)) {
	s := startTestServer(b)
	for _, protocol := range []string{"h1c", "h1", "h2", "h3"} {
		b.Run(protocol, func(b *testing.B) {
			clientProtocol := protocol
			if protocol == "h1c" {
				clientProtocol = "h1"
			}
			run(b, s.client(b, clientProtocol), s.baseURL(protocol))
		})
	}
}

func BenchmarkDownload(b *testing.B) {
	benchmarkProtocols(b, func(b *testing.B, client *http.Client, baseURL string) {
		url := fmt.Sprintf("%s/bytes?size=%d", baseURL, benchmarkPayload)
		buf := make([]byte, 1<<20)
		b.SetBytes(benchmarkPayload)
		for b.Loop() {
			resp, err := client.Get(url)
			if err != nil {
				b.Fatal(err)
			}
			if _, err := io.CopyBuffer(io.Discard, resp.Body, buf); err != nil {
				b.Fatal(err)
			}
			resp.Body.Close()
		}
	})
}

func BenchmarkUpload(b *testing.B) {
	benchmarkProtocols(b, func(b *testing.B, client *http.Client, baseURL string) {
		body := make([]byte, benchmarkPayload)
		b.SetBytes(benchmarkPayload)
		for b.Loop() {
			resp, err := client.Post(baseURL+"/discard", "application/octet-stream",
				bytes.NewReader(body))
			if err != nil {
				b.Fatal(err)
			}
			_, _ = io.Copy(io.Discard, resp.Body)
			resp.Body.Close()
		}
	})
}

func BenchmarkSmallRequests(b *testing.B) {
	benchmarkProtocols(b, func(b *testing.B, client *http.Client, baseURL string) {
		url := baseURL + "/bytes?size=1024"
		b.RunParallel(func(pb *testing.PB) {
			for pb.Next() {
				resp, err := client.Get(url)
				if err != nil {
					b.Fatal(err)
				}
				_, _ = io.Copy(io.Discard, resp.Body)
				resp.Body.Close()
			}
		})
	})
}
