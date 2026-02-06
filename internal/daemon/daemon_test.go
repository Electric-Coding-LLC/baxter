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
}

func TestRunBackupEndpointRejectsNonPost(t *testing.T) {
	d := New(config.DefaultConfig())
	req := httptest.NewRequest(http.MethodGet, "/v1/backup/run", nil)
	rr := httptest.NewRecorder()

	d.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status code: got %d want %d", rr.Code, http.StatusMethodNotAllowed)
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

func TestScheduleInterval(t *testing.T) {
	tests := []struct {
		name     string
		schedule string
		want     time.Duration
		enabled  bool
	}{
		{name: "manual", schedule: "manual", want: 0, enabled: false},
		{name: "daily", schedule: "daily", want: 24 * time.Hour, enabled: true},
		{name: "weekly", schedule: "weekly", want: 7 * 24 * time.Hour, enabled: true},
		{name: "unknown", schedule: "monthly", want: 0, enabled: false},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, enabled := scheduleInterval(tc.schedule)
			if got != tc.want || enabled != tc.enabled {
				t.Fatalf("scheduleInterval(%q) = (%v, %v), want (%v, %v)", tc.schedule, got, enabled, tc.want, tc.enabled)
			}
		})
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
