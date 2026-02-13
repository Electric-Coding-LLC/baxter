package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"baxter/internal/backup"
	"baxter/internal/config"
)

func TestStatusEndpointDefaultsToIdle(t *testing.T) {
	d := New(config.DefaultConfig())
	req := httptest.NewRequest(http.MethodGet, "/v1/status", nil)
	rr := httptest.NewRecorder()

	d.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status code: got %d want %d", rr.Code, http.StatusOK)
	}

	var resp statusResponse
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if resp.State != "idle" {
		t.Fatalf("state: got %q want idle", resp.State)
	}
}

func TestStatusEndpointRejectsNonGet(t *testing.T) {
	d := New(config.DefaultConfig())
	req := httptest.NewRequest(http.MethodPost, "/v1/status", nil)
	rr := httptest.NewRecorder()

	d.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status code: got %d want %d", rr.Code, http.StatusMethodNotAllowed)
	}
	errResp := decodeErrorResponse(t, rr)
	if errResp.Code != "method_not_allowed" {
		t.Fatalf("unexpected error code: got %q", errResp.Code)
	}
}

func TestRunBackupEndpointReturnsConflictWhenAlreadyRunning(t *testing.T) {
	d := New(config.DefaultConfig())
	d.mu.Lock()
	d.running = true
	d.status.State = "running"
	d.mu.Unlock()

	req := httptest.NewRequest(http.MethodPost, "/v1/backup/run", nil)
	rr := httptest.NewRecorder()

	d.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusConflict {
		t.Fatalf("status code: got %d want %d", rr.Code, http.StatusConflict)
	}
	errResp := decodeErrorResponse(t, rr)
	if errResp.Code != "backup_running" {
		t.Fatalf("unexpected error code: got %q", errResp.Code)
	}
}

func TestRunBackupEndpointRejectsNonPost(t *testing.T) {
	d := New(config.DefaultConfig())
	req := httptest.NewRequest(http.MethodGet, "/v1/backup/run", nil)
	rr := httptest.NewRecorder()

	d.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status code: got %d want %d", rr.Code, http.StatusMethodNotAllowed)
	}
	errResp := decodeErrorResponse(t, rr)
	if errResp.Code != "method_not_allowed" {
		t.Fatalf("unexpected error code: got %q", errResp.Code)
	}
}

func TestRunVerifyEndpointReturnsConflictWhenAlreadyRunning(t *testing.T) {
	d := New(config.DefaultConfig())
	d.mu.Lock()
	d.verifyRunning = true
	d.status.VerifyState = "running"
	d.mu.Unlock()

	req := httptest.NewRequest(http.MethodPost, "/v1/verify/run", nil)
	rr := httptest.NewRecorder()

	d.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusConflict {
		t.Fatalf("status code: got %d want %d", rr.Code, http.StatusConflict)
	}
	errResp := decodeErrorResponse(t, rr)
	if errResp.Code != "verify_running" {
		t.Fatalf("unexpected error code: got %q", errResp.Code)
	}
}

func TestRunVerifyEndpointRejectsNonPost(t *testing.T) {
	d := New(config.DefaultConfig())
	req := httptest.NewRequest(http.MethodGet, "/v1/verify/run", nil)
	rr := httptest.NewRecorder()

	d.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status code: got %d want %d", rr.Code, http.StatusMethodNotAllowed)
	}
	errResp := decodeErrorResponse(t, rr)
	if errResp.Code != "method_not_allowed" {
		t.Fatalf("unexpected error code: got %q", errResp.Code)
	}
}

func TestRunVerifyEndpointRejectsMissingTokenWhenConfigured(t *testing.T) {
	d := New(config.DefaultConfig())
	d.SetIPCAuthToken("secret-token")
	req := httptest.NewRequest(http.MethodPost, "/v1/verify/run", nil)
	rr := httptest.NewRecorder()

	d.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("status code: got %d want %d", rr.Code, http.StatusUnauthorized)
	}
	errResp := decodeErrorResponse(t, rr)
	if errResp.Code != "unauthorized" {
		t.Fatalf("unexpected error code: got %q", errResp.Code)
	}
}

func TestRunVerifyEndpointAcceptsValidTokenWhenConfigured(t *testing.T) {
	homeDir := t.TempDir()
	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)
	t.Setenv(passphraseEnv, "verify-test-passphrase")

	d := New(config.DefaultConfig())
	d.SetIPCAuthToken("secret-token")
	req := httptest.NewRequest(http.MethodPost, "/v1/verify/run", nil)
	req.Header.Set(ipcTokenHeader, "secret-token")
	rr := httptest.NewRecorder()

	d.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusAccepted {
		t.Fatalf("status code: got %d want %d", rr.Code, http.StatusAccepted)
	}
}

func TestRunBackupEndpointRejectsMissingTokenWhenConfigured(t *testing.T) {
	d := New(config.DefaultConfig())
	d.SetIPCAuthToken("secret-token")
	req := httptest.NewRequest(http.MethodPost, "/v1/backup/run", nil)
	rr := httptest.NewRecorder()

	d.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("status code: got %d want %d", rr.Code, http.StatusUnauthorized)
	}
	errResp := decodeErrorResponse(t, rr)
	if errResp.Code != "unauthorized" {
		t.Fatalf("unexpected error code: got %q", errResp.Code)
	}
}

func TestRunBackupEndpointAcceptsValidTokenWhenConfigured(t *testing.T) {
	d := New(config.DefaultConfig())
	d.SetIPCAuthToken("secret-token")
	d.backupRunner = func(context.Context, *config.Config) error { return nil }
	req := httptest.NewRequest(http.MethodPost, "/v1/backup/run", nil)
	req.Header.Set(ipcTokenHeader, "secret-token")
	rr := httptest.NewRecorder()

	d.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusAccepted {
		t.Fatalf("status code: got %d want %d", rr.Code, http.StatusAccepted)
	}
}

func TestReloadConfigEndpointRejectsNonPost(t *testing.T) {
	d := New(config.DefaultConfig())
	req := httptest.NewRequest(http.MethodGet, "/v1/config/reload", nil)
	rr := httptest.NewRecorder()

	d.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status code: got %d want %d", rr.Code, http.StatusMethodNotAllowed)
	}
	errResp := decodeErrorResponse(t, rr)
	if errResp.Code != "method_not_allowed" {
		t.Fatalf("unexpected error code: got %q", errResp.Code)
	}
}

func TestReloadConfigEndpointRejectsMissingTokenWhenConfigured(t *testing.T) {
	d := New(config.DefaultConfig())
	d.SetIPCAuthToken("secret-token")
	req := httptest.NewRequest(http.MethodPost, "/v1/config/reload", nil)
	rr := httptest.NewRecorder()

	d.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("status code: got %d want %d", rr.Code, http.StatusUnauthorized)
	}
	errResp := decodeErrorResponse(t, rr)
	if errResp.Code != "unauthorized" {
		t.Fatalf("unexpected error code: got %q", errResp.Code)
	}
}

func TestReloadConfigEndpointFailureIsExposedInStatus(t *testing.T) {
	d := New(config.DefaultConfig())
	d.SetConfigPath("/tmp/config.toml")
	d.configLoader = func(string) (*config.Config, error) {
		return nil, errors.New("bad config")
	}

	req := httptest.NewRequest(http.MethodPost, "/v1/config/reload", nil)
	rr := httptest.NewRecorder()
	d.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusBadRequest {
		t.Fatalf("reload status code: got %d want %d", rr.Code, http.StatusBadRequest)
	}
	errResp := decodeErrorResponse(t, rr)
	if errResp.Code != "config_reload_failed" {
		t.Fatalf("unexpected error code: got %q", errResp.Code)
	}

	statusReq := httptest.NewRequest(http.MethodGet, "/v1/status", nil)
	statusRR := httptest.NewRecorder()
	d.Handler().ServeHTTP(statusRR, statusReq)
	if statusRR.Code != http.StatusOK {
		t.Fatalf("status code: got %d want %d", statusRR.Code, http.StatusOK)
	}

	var resp statusResponse
	if err := json.Unmarshal(statusRR.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode status response: %v", err)
	}
	if !strings.Contains(resp.LastError, "config reload failed") {
		t.Fatalf("unexpected last_error: %q", resp.LastError)
	}
}

func TestReloadConfigEndpointUpdatesSchedule(t *testing.T) {
	cfg := config.DefaultConfig()
	cfg.Schedule = "daily"
	d := New(cfg)
	d.SetConfigPath("/tmp/config.toml")
	d.configLoader = func(path string) (*config.Config, error) {
		updated := config.DefaultConfig()
		updated.Schedule = "manual"
		return updated, nil
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	go func() {
		d.runScheduler(ctx)
		close(done)
	}()

	deadline := time.Now().Add(500 * time.Millisecond)
	for {
		if d.snapshot().NextScheduledAt != "" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("expected next_scheduled_at before reload")
		}
		time.Sleep(5 * time.Millisecond)
	}

	req := httptest.NewRequest(http.MethodPost, "/v1/config/reload", nil)
	rr := httptest.NewRecorder()
	d.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("reload status code: got %d want %d", rr.Code, http.StatusOK)
	}

	deadline = time.Now().Add(500 * time.Millisecond)
	for {
		if d.snapshot().NextScheduledAt == "" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("expected next_scheduled_at to clear after reload to manual")
		}
		time.Sleep(5 * time.Millisecond)
	}

	cancel()
	select {
	case <-done:
	case <-time.After(500 * time.Millisecond):
		t.Fatal("scheduler goroutine did not stop in time")
	}
}

func TestRestoreListEndpoint(t *testing.T) {
	homeDir := t.TempDir()
	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)

	manifestPath := testManifestPath(t)
	m := &backup.Manifest{
		CreatedAt: time.Now().UTC(),
		Entries: []backup.ManifestEntry{
			{Path: "/Users/me/Documents/report.txt"},
			{Path: "/Users/me/Pictures/photo.jpg"},
			{Path: "/tmp/notes.txt"},
		},
	}
	if err := backup.SaveManifest(manifestPath, m); err != nil {
		t.Fatalf("save manifest: %v", err)
	}

	d := New(config.DefaultConfig())
	req := httptest.NewRequest(http.MethodGet, "/v1/restore/list?prefix=/Users/me&contains=report", nil)
	rr := httptest.NewRecorder()

	d.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("status code: got %d want %d", rr.Code, http.StatusOK)
	}

	var resp restoreListResponse
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(resp.Paths) != 1 || resp.Paths[0] != "/Users/me/Documents/report.txt" {
		t.Fatalf("unexpected paths: %#v", resp.Paths)
	}
}

func TestRestoreListEndpointWithSnapshotSelector(t *testing.T) {
	homeDir := t.TempDir()
	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)

	manifestPath := testManifestPath(t)
	if err := backup.SaveManifest(manifestPath, &backup.Manifest{
		CreatedAt: time.Now().UTC(),
		Entries:   []backup.ManifestEntry{},
	}); err != nil {
		t.Fatalf("save latest manifest: %v", err)
	}

	snapshotDir := testManifestSnapshotsDir(t)
	snapshot, err := backup.SaveSnapshotManifest(snapshotDir, &backup.Manifest{
		CreatedAt: time.Date(2026, time.January, 1, 0, 0, 0, 0, time.UTC),
		Entries:   []backup.ManifestEntry{{Path: "/Users/me/Documents/report.txt"}},
	})
	if err != nil {
		t.Fatalf("save snapshot manifest: %v", err)
	}

	d := New(config.DefaultConfig())
	req := httptest.NewRequest(http.MethodGet, "/v1/restore/list?snapshot="+snapshot.ID+"&contains=report", nil)
	rr := httptest.NewRecorder()

	d.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("status code: got %d want %d body=%s", rr.Code, http.StatusOK, rr.Body.String())
	}

	var resp restoreListResponse
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(resp.Paths) != 1 || resp.Paths[0] != "/Users/me/Documents/report.txt" {
		t.Fatalf("unexpected paths: %#v", resp.Paths)
	}
}

func TestRestoreDryRunEndpoint(t *testing.T) {
	homeDir := t.TempDir()
	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)

	sourcePath := "/Users/me/Documents/report.txt"
	manifestPath := testManifestPath(t)
	m := &backup.Manifest{
		CreatedAt: time.Now().UTC(),
		Entries: []backup.ManifestEntry{
			{Path: sourcePath, Mode: 0o600},
		},
	}
	if err := backup.SaveManifest(manifestPath, m); err != nil {
		t.Fatalf("save manifest: %v", err)
	}

	body := bytes.NewBufferString(`{"path":"/Users/me/Documents/report.txt","to_dir":"/tmp/restore","overwrite":true}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/restore/dry-run", body)
	rr := httptest.NewRecorder()

	d := New(config.DefaultConfig())
	d.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("status code: got %d want %d body=%s", rr.Code, http.StatusOK, rr.Body.String())
	}

	var resp restoreDryRunResponse
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if resp.SourcePath != sourcePath {
		t.Fatalf("unexpected source_path: got %q want %q", resp.SourcePath, sourcePath)
	}
	if resp.TargetPath != "/tmp/restore/Users/me/Documents/report.txt" {
		t.Fatalf("unexpected target_path: got %q", resp.TargetPath)
	}
	if !resp.Overwrite {
		t.Fatal("expected overwrite=true")
	}
}

func TestRestoreDryRunEndpointRequiresPath(t *testing.T) {
	req := httptest.NewRequest(http.MethodPost, "/v1/restore/dry-run", bytes.NewBufferString(`{"path":"   "}`))
	rr := httptest.NewRecorder()

	d := New(config.DefaultConfig())
	d.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("status code: got %d want %d", rr.Code, http.StatusBadRequest)
	}
	errResp := decodeErrorResponse(t, rr)
	if errResp.Code != "invalid_request" {
		t.Fatalf("unexpected error code: got %q", errResp.Code)
	}
}

func TestRestoreDryRunEndpointRejectsOversizedJSONBody(t *testing.T) {
	homeDir := t.TempDir()
	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)

	tooLargePath := strings.Repeat("a", maxJSONRequestBodyBytes+1)
	body := bytes.NewBufferString(`{"path":"` + tooLargePath + `"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/restore/dry-run", body)
	rr := httptest.NewRecorder()

	d := New(config.DefaultConfig())
	d.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("status code: got %d want %d", rr.Code, http.StatusBadRequest)
	}
	errResp := decodeErrorResponse(t, rr)
	if errResp.Code != "invalid_request" {
		t.Fatalf("unexpected error code: got %q", errResp.Code)
	}
	if !strings.Contains(errResp.Message, "request body too large") {
		t.Fatalf("unexpected error message: %q", errResp.Message)
	}
}

func TestSnapshotsEndpoint(t *testing.T) {
	homeDir := t.TempDir()
	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)

	snapshotDir := testManifestSnapshotsDir(t)
	if _, err := backup.SaveSnapshotManifest(snapshotDir, &backup.Manifest{
		CreatedAt: time.Date(2026, time.January, 1, 0, 0, 0, 0, time.UTC),
		Entries:   []backup.ManifestEntry{{Path: "/a.txt"}},
	}); err != nil {
		t.Fatalf("save first snapshot: %v", err)
	}
	if _, err := backup.SaveSnapshotManifest(snapshotDir, &backup.Manifest{
		CreatedAt: time.Date(2026, time.January, 2, 0, 0, 0, 0, time.UTC),
		Entries:   []backup.ManifestEntry{{Path: "/a.txt"}, {Path: "/b.txt"}},
	}); err != nil {
		t.Fatalf("save second snapshot: %v", err)
	}

	d := New(config.DefaultConfig())
	req := httptest.NewRequest(http.MethodGet, "/v1/snapshots?limit=1", nil)
	rr := httptest.NewRecorder()
	d.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("status code: got %d want %d body=%s", rr.Code, http.StatusOK, rr.Body.String())
	}

	var resp snapshotsResponse
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(resp.Snapshots) != 1 {
		t.Fatalf("expected one snapshot due to limit, got %d", len(resp.Snapshots))
	}
	if resp.Snapshots[0].Entries != 2 {
		t.Fatalf("expected latest snapshot with 2 entries, got %d", resp.Snapshots[0].Entries)
	}
}

func TestDaemonErrorContractMethodNotAllowedAcrossEndpoints(t *testing.T) {
	d := New(config.DefaultConfig())

	tests := []struct {
		name   string
		method string
		path   string
	}{
		{name: "status", method: http.MethodPost, path: "/v1/status"},
		{name: "backup run", method: http.MethodGet, path: "/v1/backup/run"},
		{name: "config reload", method: http.MethodGet, path: "/v1/config/reload"},
		{name: "snapshots", method: http.MethodPost, path: "/v1/snapshots"},
		{name: "restore list", method: http.MethodPost, path: "/v1/restore/list"},
		{name: "restore dry-run", method: http.MethodGet, path: "/v1/restore/dry-run"},
		{name: "restore run", method: http.MethodGet, path: "/v1/restore/run"},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(tc.method, tc.path, nil)
			rr := httptest.NewRecorder()
			d.Handler().ServeHTTP(rr, req)
			if rr.Code != http.StatusMethodNotAllowed {
				t.Fatalf("status code: got %d want %d", rr.Code, http.StatusMethodNotAllowed)
			}
			errResp := decodeErrorResponse(t, rr)
			if errResp.Code != "method_not_allowed" {
				t.Fatalf("unexpected error code: got %q", errResp.Code)
			}
			if errResp.Message == "" {
				t.Fatal("expected non-empty error message")
			}
		})
	}
}
