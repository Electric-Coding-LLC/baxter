package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"baxter/internal/backup"
	"baxter/internal/config"
	"baxter/internal/crypto"
	"baxter/internal/state"
	"baxter/internal/storage"
)

func decodeErrorResponse(t *testing.T, rr *httptest.ResponseRecorder) errorResponse {
	t.Helper()
	var resp errorResponse
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode error response: %v body=%s", err, rr.Body.String())
	}
	return resp
}

func waitForNextScheduledAt(t *testing.T, d *Daemon, want string) {
	t.Helper()
	deadline := time.Now().Add(500 * time.Millisecond)
	for {
		got := d.snapshot().NextScheduledAt
		if got == want {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("next_scheduled_at mismatch: got %q want %q", got, want)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

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

	manifestPath := filepath.Join(homeDir, "Library", "Application Support", "baxter", "manifest.json")
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

func TestRestoreDryRunEndpoint(t *testing.T) {
	homeDir := t.TempDir()
	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)

	sourcePath := "/Users/me/Documents/report.txt"
	manifestPath := filepath.Join(homeDir, "Library", "Application Support", "baxter", "manifest.json")
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

func TestRestoreRunEndpoint(t *testing.T) {
	homeDir := t.TempDir()
	srcRoot := filepath.Join(t.TempDir(), "src")
	restoreRoot := filepath.Join(t.TempDir(), "restore")
	if err := os.MkdirAll(srcRoot, 0o755); err != nil {
		t.Fatalf("mkdir src root: %v", err)
	}
	sourcePath := filepath.Join(srcRoot, "doc.txt")
	sourceBody := []byte("daemon restore body")
	if err := os.WriteFile(sourcePath, sourceBody, 0o600); err != nil {
		t.Fatalf("write source file: %v", err)
	}

	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)
	t.Setenv(passphraseEnv, "daemon-restore-passphrase")

	cfg := config.DefaultConfig()
	cfg.BackupRoots = []string{srcRoot}
	cfg.Schedule = "manual"

	manifestPath, err := state.ManifestPath()
	if err != nil {
		t.Fatalf("manifest path: %v", err)
	}
	objectsDir, err := state.ObjectStoreDir()
	if err != nil {
		t.Fatalf("object store dir: %v", err)
	}
	store, err := storage.NewFromConfig(cfg.S3, objectsDir)
	if err != nil {
		t.Fatalf("new object store: %v", err)
	}
	_, err = backup.Run(cfg, backup.RunOptions{
		ManifestPath:  manifestPath,
		EncryptionKey: crypto.KeyFromPassphrase("daemon-restore-passphrase"),
		Store:         store,
	})
	if err != nil {
		t.Fatalf("run backup: %v", err)
	}

	d := New(cfg)
	restoreAt := time.Date(2026, time.February, 8, 12, 30, 0, 0, time.UTC)
	d.clockNow = func() time.Time { return restoreAt }

	body := bytes.NewBufferString(`{"path":"` + sourcePath + `","to_dir":"` + restoreRoot + `"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/restore/run", body)
	rr := httptest.NewRecorder()
	d.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("status code: got %d want %d body=%s", rr.Code, http.StatusOK, rr.Body.String())
	}

	var restoreResp restoreRunResponse
	if err := json.Unmarshal(rr.Body.Bytes(), &restoreResp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	trimmedSource := strings.TrimPrefix(filepath.Clean(sourcePath), string(filepath.Separator))
	expectedTarget := filepath.Join(restoreRoot, trimmedSource)
	if restoreResp.TargetPath != expectedTarget {
		t.Fatalf("unexpected target path: got %q want %q", restoreResp.TargetPath, expectedTarget)
	}

	restored, err := os.ReadFile(expectedTarget)
	if err != nil {
		t.Fatalf("read restored file: %v", err)
	}
	if !bytes.Equal(restored, sourceBody) {
		t.Fatalf("restored body mismatch: got %q want %q", string(restored), string(sourceBody))
	}

	status := d.snapshot()
	if status.LastRestoreAt != restoreAt.Format(time.RFC3339) {
		t.Fatalf("unexpected last_restore_at: got %q want %q", status.LastRestoreAt, restoreAt.Format(time.RFC3339))
	}
	if status.LastRestorePath != sourcePath {
		t.Fatalf("unexpected last_restore_path: got %q want %q", status.LastRestorePath, sourcePath)
	}
	if status.LastRestoreError != "" {
		t.Fatalf("unexpected last_restore_error: %q", status.LastRestoreError)
	}
}

func TestRestoreRunEndpointRejectsExistingTargetWithoutOverwrite(t *testing.T) {
	homeDir := t.TempDir()
	srcRoot := filepath.Join(t.TempDir(), "src")
	restoreRoot := filepath.Join(t.TempDir(), "restore")
	if err := os.MkdirAll(srcRoot, 0o755); err != nil {
		t.Fatalf("mkdir src root: %v", err)
	}
	sourcePath := filepath.Join(srcRoot, "doc.txt")
	if err := os.WriteFile(sourcePath, []byte("restore body"), 0o600); err != nil {
		t.Fatalf("write source file: %v", err)
	}

	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)
	t.Setenv(passphraseEnv, "daemon-restore-passphrase")

	cfg := config.DefaultConfig()
	cfg.BackupRoots = []string{srcRoot}
	cfg.Schedule = "manual"

	manifestPath, err := state.ManifestPath()
	if err != nil {
		t.Fatalf("manifest path: %v", err)
	}
	objectsDir, err := state.ObjectStoreDir()
	if err != nil {
		t.Fatalf("object store dir: %v", err)
	}
	store, err := storage.NewFromConfig(cfg.S3, objectsDir)
	if err != nil {
		t.Fatalf("new object store: %v", err)
	}
	_, err = backup.Run(cfg, backup.RunOptions{
		ManifestPath:  manifestPath,
		EncryptionKey: crypto.KeyFromPassphrase("daemon-restore-passphrase"),
		Store:         store,
	})
	if err != nil {
		t.Fatalf("run backup: %v", err)
	}

	trimmedSource := strings.TrimPrefix(filepath.Clean(sourcePath), string(filepath.Separator))
	target := filepath.Join(restoreRoot, trimmedSource)
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		t.Fatalf("mkdir target dir: %v", err)
	}
	if err := os.WriteFile(target, []byte("already there"), 0o600); err != nil {
		t.Fatalf("write existing target: %v", err)
	}

	d := New(cfg)
	body := bytes.NewBufferString(`{"path":"` + sourcePath + `","to_dir":"` + restoreRoot + `"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/restore/run", body)
	rr := httptest.NewRecorder()
	d.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("status code: got %d want %d", rr.Code, http.StatusBadRequest)
	}
	errResp := decodeErrorResponse(t, rr)
	if errResp.Code != "target_exists" {
		t.Fatalf("unexpected error code: got %q", errResp.Code)
	}
	if d.snapshot().LastRestoreError == "" {
		t.Fatal("expected last_restore_error to be set")
	}
}

func TestDaemonErrorContractRestoreDryRunDecodeFailure(t *testing.T) {
	d := New(config.DefaultConfig())
	req := httptest.NewRequest(http.MethodPost, "/v1/restore/dry-run", bytes.NewBufferString(`{"path":`))
	rr := httptest.NewRecorder()

	d.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("status code: got %d want %d", rr.Code, http.StatusBadRequest)
	}
	errResp := decodeErrorResponse(t, rr)
	if errResp.Code != "invalid_request" {
		t.Fatalf("unexpected error code: got %q", errResp.Code)
	}
}

func TestDaemonErrorContractRestoreListManifestLoadFailed(t *testing.T) {
	homeDir := t.TempDir()
	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)
	manifestPath := filepath.Join(homeDir, "Library", "Application Support", "baxter", "manifest.json")
	if err := os.MkdirAll(filepath.Dir(manifestPath), 0o755); err != nil {
		t.Fatalf("mkdir manifest dir: %v", err)
	}
	if err := os.WriteFile(manifestPath, []byte("{invalid"), 0o600); err != nil {
		t.Fatalf("write invalid manifest: %v", err)
	}

	d := New(config.DefaultConfig())
	req := httptest.NewRequest(http.MethodGet, "/v1/restore/list", nil)
	rr := httptest.NewRecorder()

	d.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("status code: got %d want %d", rr.Code, http.StatusBadRequest)
	}
	errResp := decodeErrorResponse(t, rr)
	if errResp.Code != "manifest_load_failed" {
		t.Fatalf("unexpected error code: got %q", errResp.Code)
	}
}

func TestDaemonErrorContractRestoreDryRunPathLookupFailed(t *testing.T) {
	homeDir := t.TempDir()
	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)

	manifestPath := filepath.Join(homeDir, "Library", "Application Support", "baxter", "manifest.json")
	m := &backup.Manifest{
		CreatedAt: time.Now().UTC(),
		Entries: []backup.ManifestEntry{
			{Path: "/Users/me/exists.txt"},
		},
	}
	if err := backup.SaveManifest(manifestPath, m); err != nil {
		t.Fatalf("save manifest: %v", err)
	}

	body := bytes.NewBufferString(`{"path":"/Users/me/missing.txt"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/restore/dry-run", body)
	rr := httptest.NewRecorder()
	d := New(config.DefaultConfig())
	d.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("status code: got %d want %d", rr.Code, http.StatusBadRequest)
	}
	errResp := decodeErrorResponse(t, rr)
	if errResp.Code != "path_lookup_failed" {
		t.Fatalf("unexpected error code: got %q", errResp.Code)
	}
}

func TestDaemonErrorContractRestoreDryRunInvalidRestoreTarget(t *testing.T) {
	homeDir := t.TempDir()
	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)

	manifestPath := filepath.Join(homeDir, "Library", "Application Support", "baxter", "manifest.json")
	m := &backup.Manifest{
		CreatedAt: time.Now().UTC(),
		Entries: []backup.ManifestEntry{
			{Path: "../escape"},
		},
	}
	if err := backup.SaveManifest(manifestPath, m); err != nil {
		t.Fatalf("save manifest: %v", err)
	}

	body := bytes.NewBufferString(`{"path":"../escape","to_dir":"/tmp/out"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/restore/dry-run", body)
	rr := httptest.NewRecorder()
	d := New(config.DefaultConfig())
	d.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("status code: got %d want %d", rr.Code, http.StatusBadRequest)
	}
	errResp := decodeErrorResponse(t, rr)
	if errResp.Code != "invalid_restore_target" {
		t.Fatalf("unexpected error code: got %q", errResp.Code)
	}
}

func TestNextScheduledRun(t *testing.T) {
	loc := time.FixedZone("UTC-0800", -8*60*60)

	tests := []struct {
		name    string
		cfg     scheduleConfig
		now     time.Time
		want    time.Time
		enabled bool
	}{
		{
			name: "manual disabled",
			cfg: scheduleConfig{
				Schedule: "manual",
			},
			now:     time.Date(2026, time.February, 8, 8, 0, 0, 0, loc),
			want:    time.Time{},
			enabled: false,
		},
		{
			name: "daily before configured time uses same day",
			cfg: scheduleConfig{
				Schedule:  "daily",
				DailyTime: "09:30",
			},
			now:     time.Date(2026, time.February, 8, 8, 0, 0, 0, loc),
			want:    time.Date(2026, time.February, 8, 9, 30, 0, 0, loc),
			enabled: true,
		},
		{
			name: "daily after configured time uses next day",
			cfg: scheduleConfig{
				Schedule:  "daily",
				DailyTime: "09:30",
			},
			now:     time.Date(2026, time.February, 8, 10, 0, 0, 0, loc),
			want:    time.Date(2026, time.February, 9, 9, 30, 0, 0, loc),
			enabled: true,
		},
		{
			name: "weekly before configured weekday/time uses same week",
			cfg: scheduleConfig{
				Schedule:   "weekly",
				WeeklyDay:  "sunday",
				WeeklyTime: "09:30",
			},
			now:     time.Date(2026, time.February, 6, 8, 0, 0, 0, loc),  // Friday
			want:    time.Date(2026, time.February, 8, 9, 30, 0, 0, loc), // Sunday
			enabled: true,
		},
		{
			name: "weekly after configured weekday/time uses next week",
			cfg: scheduleConfig{
				Schedule:   "weekly",
				WeeklyDay:  "sunday",
				WeeklyTime: "09:30",
			},
			now:     time.Date(2026, time.February, 8, 12, 0, 0, 0, loc),  // Sunday
			want:    time.Date(2026, time.February, 15, 9, 30, 0, 0, loc), // next Sunday
			enabled: true,
		},
		{
			name: "invalid daily time disabled",
			cfg: scheduleConfig{
				Schedule:  "daily",
				DailyTime: "oops",
			},
			now:     time.Date(2026, time.February, 8, 8, 0, 0, 0, loc),
			want:    time.Time{},
			enabled: false,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, enabled := nextScheduledRun(tc.cfg, tc.now)
			if enabled != tc.enabled {
				t.Fatalf("nextScheduledRun(%+v) enabled=%v want %v", tc.cfg, enabled, tc.enabled)
			}
			if !got.Equal(tc.want) {
				t.Fatalf("nextScheduledRun(%+v) = %v, want %v", tc.cfg, got, tc.want)
			}
		})
	}
}

func TestNextScheduledRunDailyPreservesWallClockAcrossDST(t *testing.T) {
	loc, err := time.LoadLocation("America/Los_Angeles")
	if err != nil {
		t.Skipf("timezone data unavailable: %v", err)
	}

	tests := []struct {
		name      string
		now       time.Time
		want      time.Time
		wantDelta time.Duration
	}{
		{
			name:      "spring forward keeps same local clock time",
			now:       time.Date(2026, time.March, 8, 10, 0, 0, 0, loc), // PDT
			want:      time.Date(2026, time.March, 9, 9, 30, 0, 0, loc), // PDT
			wantDelta: 23*time.Hour + 30*time.Minute,
		},
		{
			name:      "fall back keeps same local clock time",
			now:       time.Date(2026, time.October, 31, 10, 0, 0, 0, loc), // PDT
			want:      time.Date(2026, time.November, 1, 9, 30, 0, 0, loc), // PST
			wantDelta: 24*time.Hour + 30*time.Minute,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			cfg := scheduleConfig{Schedule: "daily", DailyTime: "09:30"}
			got, enabled := nextScheduledRun(cfg, tc.now)
			if !enabled {
				t.Fatal("expected daily schedule to be enabled")
			}
			if !got.Equal(tc.want) {
				t.Fatalf("nextScheduledRun(daily) = %v, want %v", got, tc.want)
			}
			if delta := got.Sub(tc.now); delta != tc.wantDelta {
				t.Fatalf("unexpected next-run delta: got %v want %v", delta, tc.wantDelta)
			}
		})
	}
}

func TestSetIdleSuccessUsesInjectedClock(t *testing.T) {
	d := New(config.DefaultConfig())
	fixed := time.Date(2026, time.February, 8, 11, 15, 0, 0, time.UTC)
	d.clockNow = func() time.Time { return fixed }

	d.mu.Lock()
	d.running = true
	d.mu.Unlock()
	d.setIdleSuccess()

	resp := d.snapshot()
	if resp.LastBackupAt != fixed.Format(time.RFC3339) {
		t.Fatalf("unexpected last_backup_at: got %q want %q", resp.LastBackupAt, fixed.Format(time.RFC3339))
	}
}

func TestStatusIncludesNextScheduledAt(t *testing.T) {
	d := New(config.DefaultConfig())
	next := time.Date(2026, time.February, 6, 10, 30, 0, 0, time.UTC)
	d.setNextScheduledAt(next)

	resp := d.snapshot()
	if resp.NextScheduledAt == "" {
		t.Fatalf("expected next_scheduled_at in response")
	}
	if resp.NextScheduledAt != next.Format(time.RFC3339) {
		t.Fatalf("unexpected next_scheduled_at: got %q want %q", resp.NextScheduledAt, next.Format(time.RFC3339))
	}
}

func TestStatusEndpointScheduleVisibility(t *testing.T) {
	tests := []struct {
		name        string
		schedule    string
		shouldExist bool
	}{
		{name: "daily includes next_scheduled_at", schedule: "daily", shouldExist: true},
		{name: "weekly includes next_scheduled_at", schedule: "weekly", shouldExist: true},
		{name: "manual omits next_scheduled_at", schedule: "manual", shouldExist: false},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			cfg := config.DefaultConfig()
			cfg.Schedule = tc.schedule
			d := New(cfg)

			ctx, cancel := context.WithCancel(context.Background())
			done := make(chan struct{})
			go func() {
				d.runScheduler(ctx)
				close(done)
			}()

			if tc.shouldExist {
				deadline := time.Now().Add(500 * time.Millisecond)
				for {
					resp := d.snapshot()
					if resp.NextScheduledAt != "" {
						break
					}
					if time.Now().After(deadline) {
						t.Fatal("next_scheduled_at was not set in time")
					}
					time.Sleep(5 * time.Millisecond)
				}
			} else {
				deadline := time.Now().Add(500 * time.Millisecond)
				for {
					resp := d.snapshot()
					if resp.NextScheduledAt == "" {
						break
					}
					if time.Now().After(deadline) {
						t.Fatal("expected empty next_scheduled_at for manual schedule")
					}
					time.Sleep(5 * time.Millisecond)
				}
			}

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

			if tc.shouldExist && resp.NextScheduledAt == "" {
				t.Fatalf("expected next_scheduled_at for schedule %q", tc.schedule)
			}
			if !tc.shouldExist && resp.NextScheduledAt != "" {
				t.Fatalf("expected empty next_scheduled_at for schedule %q, got %q", tc.schedule, resp.NextScheduledAt)
			}

			cancel()
			select {
			case <-done:
			case <-time.After(500 * time.Millisecond):
				t.Fatal("scheduler goroutine did not stop in time")
			}
		})
	}
}

func TestReloadConfigEndpointUpdatesNextScheduledAtWithFixedClock(t *testing.T) {
	now := time.Date(2026, time.February, 8, 8, 0, 0, 0, time.UTC)
	cfg := config.DefaultConfig()
	cfg.Schedule = "daily"
	cfg.DailyTime = "09:30"
	d := New(cfg)
	d.clockNow = func() time.Time { return now }
	d.timerAfter = func(time.Duration) <-chan time.Time {
		return make(chan time.Time)
	}

	var step int
	d.SetConfigPath("/tmp/config.toml")
	d.configLoader = func(path string) (*config.Config, error) {
		updated := config.DefaultConfig()
		switch step {
		case 0:
			updated.Schedule = "weekly"
			updated.WeeklyDay = "friday"
			updated.WeeklyTime = "18:15"
		default:
			updated.Schedule = "manual"
		}
		step++
		return updated, nil
	}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		d.runScheduler(ctx)
		close(done)
	}()
	defer func() {
		cancel()
		select {
		case <-done:
		case <-time.After(500 * time.Millisecond):
			t.Fatal("scheduler goroutine did not stop in time")
		}
	}()

	waitForNextScheduledAt(t, d, time.Date(2026, time.February, 8, 9, 30, 0, 0, time.UTC).Format(time.RFC3339))

	req := httptest.NewRequest(http.MethodPost, "/v1/config/reload", nil)
	rr := httptest.NewRecorder()
	d.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("reload status code: got %d want %d", rr.Code, http.StatusOK)
	}
	waitForNextScheduledAt(t, d, time.Date(2026, time.February, 13, 18, 15, 0, 0, time.UTC).Format(time.RFC3339))

	req = httptest.NewRequest(http.MethodPost, "/v1/config/reload", nil)
	rr = httptest.NewRecorder()
	d.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("reload status code: got %d want %d", rr.Code, http.StatusOK)
	}
	waitForNextScheduledAt(t, d, "")
}

func TestDaemonEndToEndReloadScheduledTriggerAndStatus(t *testing.T) {
	initialNow := time.Date(2026, time.February, 8, 9, 0, 0, 0, time.UTC)
	currentNow := initialNow
	var nowMu sync.Mutex

	cfg := config.DefaultConfig()
	cfg.Schedule = "daily"
	cfg.DailyTime = "09:30"
	d := New(cfg)
	d.clockNow = func() time.Time {
		nowMu.Lock()
		defer nowMu.Unlock()
		return currentNow
	}

	timerCh := make(chan time.Time, 1)
	d.timerAfter = func(time.Duration) <-chan time.Time {
		return timerCh
	}

	backupDone := make(chan struct{}, 1)
	d.backupRunner = func(ctx context.Context, cfg *config.Config) error {
		nowMu.Lock()
		currentNow = time.Date(2026, time.February, 8, 9, 30, 0, 0, time.UTC)
		nowMu.Unlock()
		backupDone <- struct{}{}
		return nil
	}

	d.SetConfigPath("/tmp/config.toml")
	d.configLoader = func(path string) (*config.Config, error) {
		updated := config.DefaultConfig()
		updated.Schedule = "manual"
		return updated, nil
	}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		d.runScheduler(ctx)
		close(done)
	}()
	defer func() {
		cancel()
		select {
		case <-done:
		case <-time.After(500 * time.Millisecond):
			t.Fatal("scheduler goroutine did not stop in time")
		}
	}()

	waitForNextScheduledAt(t, d, time.Date(2026, time.February, 8, 9, 30, 0, 0, time.UTC).Format(time.RFC3339))

	timerCh <- time.Now()
	select {
	case <-backupDone:
	case <-time.After(500 * time.Millisecond):
		t.Fatal("scheduled backup did not trigger")
	}

	deadline := time.Now().Add(500 * time.Millisecond)
	for {
		snap := d.snapshot()
		if snap.State == "idle" && snap.LastBackupAt == time.Date(2026, time.February, 8, 9, 30, 0, 0, time.UTC).Format(time.RFC3339) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("unexpected status after scheduled run: %+v", snap)
		}
		time.Sleep(5 * time.Millisecond)
	}

	req := httptest.NewRequest(http.MethodPost, "/v1/config/reload", nil)
	rr := httptest.NewRecorder()
	d.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("reload status code: got %d want %d", rr.Code, http.StatusOK)
	}
	waitForNextScheduledAt(t, d, "")
}

func TestRunBackupEndpointStateTransition(t *testing.T) {
	homeDir := t.TempDir()
	sourceRoot := filepath.Join(t.TempDir(), "source")
	if err := os.MkdirAll(sourceRoot, 0o755); err != nil {
		t.Fatalf("mkdir source root: %v", err)
	}

	large := bytes.Repeat([]byte("baxter"), 10*1024*1024) // ~60MB to keep run in-flight briefly
	if err := os.WriteFile(filepath.Join(sourceRoot, "large.bin"), large, 0o600); err != nil {
		t.Fatalf("write source file: %v", err)
	}

	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)
	t.Setenv(passphraseEnv, "daemon-test-passphrase")

	cfg := config.DefaultConfig()
	cfg.Schedule = "manual"
	cfg.BackupRoots = []string{sourceRoot}

	d := New(cfg)

	req := httptest.NewRequest(http.MethodPost, "/v1/backup/run", nil)
	rr := httptest.NewRecorder()
	d.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusAccepted {
		t.Fatalf("first run status code: got %d want %d", rr.Code, http.StatusAccepted)
	}

	if state := d.snapshot().State; state != "running" {
		t.Fatalf("expected running state immediately after trigger, got %q", state)
	}

	conflictReq := httptest.NewRequest(http.MethodPost, "/v1/backup/run", nil)
	conflictRR := httptest.NewRecorder()
	d.Handler().ServeHTTP(conflictRR, conflictReq)
	if conflictRR.Code != http.StatusConflict {
		t.Fatalf("second run status code: got %d want %d", conflictRR.Code, http.StatusConflict)
	}

	deadline := time.Now().Add(30 * time.Second)
	var final statusResponse
	for {
		statusReq := httptest.NewRequest(http.MethodGet, "/v1/status", nil)
		statusRR := httptest.NewRecorder()
		d.Handler().ServeHTTP(statusRR, statusReq)
		if statusRR.Code != http.StatusOK {
			t.Fatalf("status endpoint code: got %d want %d", statusRR.Code, http.StatusOK)
		}
		if err := json.Unmarshal(statusRR.Body.Bytes(), &final); err != nil {
			t.Fatalf("decode status response: %v", err)
		}

		if final.State != "running" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("backup did not exit running state in time")
		}
		time.Sleep(10 * time.Millisecond)
	}

	if final.State != "idle" && final.State != "failed" {
		t.Fatalf("unexpected final state: %q", final.State)
	}
	if final.State == "idle" && final.LastBackupAt == "" {
		t.Fatal("expected last_backup_at after successful run")
	}
	if final.State == "failed" && final.LastError == "" {
		t.Fatal("expected last_error after failed run")
	}
}
