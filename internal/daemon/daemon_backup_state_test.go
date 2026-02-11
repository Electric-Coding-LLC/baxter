package daemon

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"baxter/internal/config"
)

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
