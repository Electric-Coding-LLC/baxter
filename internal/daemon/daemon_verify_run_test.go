package daemon

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"baxter/internal/backup"
	"baxter/internal/config"
	"baxter/internal/crypto"
	"baxter/internal/state"
	"baxter/internal/storage"
)

func TestRunVerifyEndpointSuccessUpdatesStatus(t *testing.T) {
	homeDir := t.TempDir()
	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)
	t.Setenv(passphraseEnv, "verify-success-passphrase")

	cfg := config.DefaultConfig()
	cfg.Verify.Schedule = "manual"

	sourcePath := "/Users/me/Documents/report.txt"
	plain := []byte("verify me")
	manifest := &backup.Manifest{
		CreatedAt: time.Now().UTC(),
		Entries: []backup.ManifestEntry{{
			Path:    sourcePath,
			Mode:    0o600,
			ModTime: time.Now().UTC(),
			Size:    int64(len(plain)),
			SHA256:  checksumHex(plain),
		}},
	}

	manifestPath, err := state.ManifestPath()
	if err != nil {
		t.Fatalf("manifest path: %v", err)
	}
	if err := backup.SaveManifest(manifestPath, manifest); err != nil {
		t.Fatalf("save manifest: %v", err)
	}

	key, err := encryptionKey(cfg)
	if err != nil {
		t.Fatalf("encryption key: %v", err)
	}
	payload, err := crypto.EncryptBytes(key, plain)
	if err != nil {
		t.Fatalf("encrypt payload: %v", err)
	}

	objectsDir, err := state.ObjectStoreDir()
	if err != nil {
		t.Fatalf("object store dir: %v", err)
	}
	store, err := storage.NewFromConfig(cfg.S3, objectsDir)
	if err != nil {
		t.Fatalf("create object store: %v", err)
	}
	if err := store.PutObject(backup.ObjectKeyForPath(sourcePath), payload); err != nil {
		t.Fatalf("put object: %v", err)
	}

	d := New(cfg)
	req := httptest.NewRequest(http.MethodPost, "/v1/verify/run", nil)
	rr := httptest.NewRecorder()
	d.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusAccepted {
		t.Fatalf("verify run status code: got %d want %d body=%s", rr.Code, http.StatusAccepted, rr.Body.String())
	}

	status := waitForVerifyCompletion(t, d)
	if status.VerifyState != "idle" {
		t.Fatalf("unexpected verify_state: got %q want idle", status.VerifyState)
	}
	if status.LastVerifyAt == "" {
		t.Fatal("expected last_verify_at after successful verify")
	}
	if status.LastVerifyError != "" {
		t.Fatalf("unexpected last_verify_error: %q", status.LastVerifyError)
	}
	if status.LastVerifyChecked != 1 || status.LastVerifyOK != 1 {
		t.Fatalf("unexpected verify counts: checked=%d ok=%d", status.LastVerifyChecked, status.LastVerifyOK)
	}
}

func TestRunVerifyEndpointFailureUpdatesStatus(t *testing.T) {
	homeDir := t.TempDir()
	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)
	t.Setenv(passphraseEnv, "verify-failure-passphrase")

	cfg := config.DefaultConfig()
	cfg.Verify.Schedule = "manual"

	sourcePath := "/Users/me/Documents/missing.txt"
	manifest := &backup.Manifest{
		CreatedAt: time.Now().UTC(),
		Entries: []backup.ManifestEntry{{
			Path:    sourcePath,
			Mode:    0o600,
			ModTime: time.Now().UTC(),
			Size:    int64(len("missing")),
			SHA256:  checksumHex([]byte("missing")),
		}},
	}

	manifestPath, err := state.ManifestPath()
	if err != nil {
		t.Fatalf("manifest path: %v", err)
	}
	if err := backup.SaveManifest(manifestPath, manifest); err != nil {
		t.Fatalf("save manifest: %v", err)
	}

	d := New(cfg)
	req := httptest.NewRequest(http.MethodPost, "/v1/verify/run", nil)
	rr := httptest.NewRecorder()
	d.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusAccepted {
		t.Fatalf("verify run status code: got %d want %d body=%s", rr.Code, http.StatusAccepted, rr.Body.String())
	}

	status := waitForVerifyCompletion(t, d)
	if status.VerifyState != "failed" {
		t.Fatalf("unexpected verify_state: got %q want failed", status.VerifyState)
	}
	if status.LastVerifyAt == "" {
		t.Fatal("expected last_verify_at after failed verify")
	}
	if !strings.Contains(status.LastVerifyError, "verify failed") {
		t.Fatalf("expected verify failure message, got %q", status.LastVerifyError)
	}
	if status.LastVerifyMissing != 1 {
		t.Fatalf("expected missing count to be 1, got %d", status.LastVerifyMissing)
	}
}

func waitForVerifyCompletion(t *testing.T, d *Daemon) statusResponse {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		req := httptest.NewRequest(http.MethodGet, "/v1/status", nil)
		rr := httptest.NewRecorder()
		d.Handler().ServeHTTP(rr, req)
		if rr.Code != http.StatusOK {
			t.Fatalf("status code: got %d want %d", rr.Code, http.StatusOK)
		}

		var status statusResponse
		if err := json.Unmarshal(rr.Body.Bytes(), &status); err != nil {
			t.Fatalf("decode status response: %v", err)
		}
		if status.VerifyState != "running" {
			return status
		}
		if time.Now().After(deadline) {
			t.Fatalf("verify did not exit running state in time; status=%+v", status)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func checksumHex(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}
