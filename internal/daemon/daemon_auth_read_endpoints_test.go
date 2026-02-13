package daemon

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"baxter/internal/backup"
	"baxter/internal/config"
)

func TestReadEndpointsRejectMissingTokenWhenConfigured(t *testing.T) {
	seedReadAuthTestData(t)

	d := New(config.DefaultConfig())
	d.SetIPCAuthToken("secret-token")

	tests := []struct {
		name   string
		method string
		path   string
		body   []byte
	}{
		{name: "status", method: http.MethodGet, path: "/v1/status"},
		{name: "snapshots", method: http.MethodGet, path: "/v1/snapshots"},
		{name: "restore list", method: http.MethodGet, path: "/v1/restore/list"},
		{name: "restore dry-run", method: http.MethodPost, path: "/v1/restore/dry-run", body: []byte(`{"path":"/Users/me/Documents/report.txt"}`)},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var body *bytes.Buffer
			if len(tc.body) > 0 {
				body = bytes.NewBuffer(tc.body)
			} else {
				body = bytes.NewBuffer(nil)
			}
			req := httptest.NewRequest(tc.method, tc.path, body)
			if len(tc.body) > 0 {
				req.Header.Set("Content-Type", "application/json")
			}
			rr := httptest.NewRecorder()

			d.Handler().ServeHTTP(rr, req)
			if rr.Code != http.StatusUnauthorized {
				t.Fatalf("status code: got %d want %d body=%s", rr.Code, http.StatusUnauthorized, rr.Body.String())
			}
			errResp := decodeErrorResponse(t, rr)
			if errResp.Code != "unauthorized" {
				t.Fatalf("unexpected error code: got %q", errResp.Code)
			}
		})
	}
}

func TestReadEndpointsAcceptValidTokenWhenConfigured(t *testing.T) {
	seedReadAuthTestData(t)

	d := New(config.DefaultConfig())
	d.SetIPCAuthToken("secret-token")

	tests := []struct {
		name       string
		method     string
		path       string
		body       []byte
		wantStatus int
	}{
		{name: "status", method: http.MethodGet, path: "/v1/status", wantStatus: http.StatusOK},
		{name: "snapshots", method: http.MethodGet, path: "/v1/snapshots", wantStatus: http.StatusOK},
		{name: "restore list", method: http.MethodGet, path: "/v1/restore/list?prefix=/Users/me", wantStatus: http.StatusOK},
		{name: "restore dry-run", method: http.MethodPost, path: "/v1/restore/dry-run", body: []byte(`{"path":"/Users/me/Documents/report.txt","to_dir":"/tmp/restore"}`), wantStatus: http.StatusOK},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var body *bytes.Buffer
			if len(tc.body) > 0 {
				body = bytes.NewBuffer(tc.body)
			} else {
				body = bytes.NewBuffer(nil)
			}
			req := httptest.NewRequest(tc.method, tc.path, body)
			req.Header.Set(ipcTokenHeader, "secret-token")
			if len(tc.body) > 0 {
				req.Header.Set("Content-Type", "application/json")
			}
			rr := httptest.NewRecorder()

			d.Handler().ServeHTTP(rr, req)
			if rr.Code != tc.wantStatus {
				t.Fatalf("status code: got %d want %d body=%s", rr.Code, tc.wantStatus, rr.Body.String())
			}
		})
	}
}

func seedReadAuthTestData(t *testing.T) {
	t.Helper()

	homeDir := t.TempDir()
	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)

	manifestPath := testManifestPath(t)
	if err := backup.SaveManifest(manifestPath, &backup.Manifest{
		CreatedAt: time.Now().UTC(),
		Entries: []backup.ManifestEntry{{
			Path: "/Users/me/Documents/report.txt",
			Mode: 0o600,
		}},
	}); err != nil {
		t.Fatalf("save manifest: %v", err)
	}
}
