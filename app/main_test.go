package main

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
)

func newTestServer(t *testing.T) *httptest.Server {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	ts := httptest.NewServer(newServer(":0", logger).Handler)
	t.Cleanup(ts.Close)
	return ts
}

func TestRoutes(t *testing.T) {
	ts := newTestServer(t)

	cases := []struct {
		name       string
		path       string
		wantStatus int
		wantBody   string
	}{
		{name: "root greeting", path: "/", wantStatus: http.StatusOK, wantBody: "Hello, World!\n"},
		{name: "catch-all serves subpaths", path: "/anything", wantStatus: http.StatusOK, wantBody: "Hello, World!\n"},
		{name: "health check", path: "/healthz", wantStatus: http.StatusOK, wantBody: "ok\n"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			resp, err := http.Get(ts.URL + tc.path)
			if err != nil {
				t.Fatalf("GET %s: %v", tc.path, err)
			}
			defer resp.Body.Close()

			if resp.StatusCode != tc.wantStatus {
				t.Errorf("GET %s status = %d, want %d", tc.path, resp.StatusCode, tc.wantStatus)
			}
			body, err := io.ReadAll(resp.Body)
			if err != nil {
				t.Fatalf("read body: %v", err)
			}
			if string(body) != tc.wantBody {
				t.Errorf("GET %s body = %q, want %q", tc.path, string(body), tc.wantBody)
			}
		})
	}
}

func TestServerTimeoutsConfigured(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	srv := newServer(":5678", logger)

	if srv.ReadHeaderTimeout == 0 {
		t.Error("ReadHeaderTimeout must be set to protect against slowloris")
	}
	if srv.ReadTimeout == 0 || srv.WriteTimeout == 0 {
		t.Error("Read/Write timeouts must be set")
	}
}
