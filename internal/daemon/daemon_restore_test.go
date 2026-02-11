package daemon

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"baxter/internal/backup"
	"baxter/internal/config"
	"baxter/internal/crypto"
	"baxter/internal/state"
	"baxter/internal/storage"
)

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
	snapshotDir, err := state.ManifestSnapshotsDir()
	if err != nil {
		t.Fatalf("manifest snapshots dir: %v", err)
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
		ManifestPath:      manifestPath,
		SnapshotDir:       snapshotDir,
		SnapshotRetention: cfg.Retention.ManifestSnapshots,
		EncryptionKey:     crypto.KeyFromPassphrase("daemon-restore-passphrase"),
		Store:             store,
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
	if !restoreResp.Verified || !restoreResp.Wrote {
		t.Fatalf("unexpected restore flags: verified=%t wrote=%t", restoreResp.Verified, restoreResp.Wrote)
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

func TestRestoreRunEndpointVerifyOnlyDoesNotWrite(t *testing.T) {
	homeDir := t.TempDir()
	srcRoot := filepath.Join(t.TempDir(), "src")
	restoreRoot := filepath.Join(t.TempDir(), "restore")
	if err := os.MkdirAll(srcRoot, 0o755); err != nil {
		t.Fatalf("mkdir src root: %v", err)
	}
	sourcePath := filepath.Join(srcRoot, "doc.txt")
	sourceBody := []byte("daemon verify-only body")
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
	snapshotDir, err := state.ManifestSnapshotsDir()
	if err != nil {
		t.Fatalf("manifest snapshots dir: %v", err)
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
		ManifestPath:      manifestPath,
		SnapshotDir:       snapshotDir,
		SnapshotRetention: cfg.Retention.ManifestSnapshots,
		EncryptionKey:     crypto.KeyFromPassphrase("daemon-restore-passphrase"),
		Store:             store,
	})
	if err != nil {
		t.Fatalf("run backup: %v", err)
	}

	d := New(cfg)
	restoreAt := time.Date(2026, time.February, 8, 12, 35, 0, 0, time.UTC)
	d.clockNow = func() time.Time { return restoreAt }

	body := bytes.NewBufferString(`{"path":"` + sourcePath + `","to_dir":"` + restoreRoot + `","verify_only":true}`)
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
	if !restoreResp.Verified || restoreResp.Wrote {
		t.Fatalf("unexpected restore flags: verified=%t wrote=%t", restoreResp.Verified, restoreResp.Wrote)
	}

	trimmedSource := strings.TrimPrefix(filepath.Clean(sourcePath), string(filepath.Separator))
	target := filepath.Join(restoreRoot, trimmedSource)
	if _, err := os.Stat(target); !os.IsNotExist(err) {
		t.Fatalf("verify-only should not write target, stat err=%v", err)
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
	snapshotDir, err := state.ManifestSnapshotsDir()
	if err != nil {
		t.Fatalf("manifest snapshots dir: %v", err)
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
		ManifestPath:      manifestPath,
		SnapshotDir:       snapshotDir,
		SnapshotRetention: cfg.Retention.ManifestSnapshots,
		EncryptionKey:     crypto.KeyFromPassphrase("daemon-restore-passphrase"),
		Store:             store,
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

func TestRestoreRunEndpointChecksumMismatchDoesNotOverwrite(t *testing.T) {
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
	snapshotDir, err := state.ManifestSnapshotsDir()
	if err != nil {
		t.Fatalf("manifest snapshots dir: %v", err)
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
		ManifestPath:      manifestPath,
		SnapshotDir:       snapshotDir,
		SnapshotRetention: cfg.Retention.ManifestSnapshots,
		EncryptionKey:     crypto.KeyFromPassphrase("daemon-restore-passphrase"),
		Store:             store,
	})
	if err != nil {
		t.Fatalf("run backup: %v", err)
	}

	manifest, err := backup.LoadManifest(manifestPath)
	if err != nil {
		t.Fatalf("load manifest: %v", err)
	}
	for i := range manifest.Entries {
		if manifest.Entries[i].Path == sourcePath {
			manifest.Entries[i].SHA256 = strings.Repeat("0", 64)
		}
	}
	if err := backup.SaveManifest(manifestPath, manifest); err != nil {
		t.Fatalf("save manifest: %v", err)
	}

	trimmedSource := strings.TrimPrefix(filepath.Clean(sourcePath), string(filepath.Separator))
	target := filepath.Join(restoreRoot, trimmedSource)
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		t.Fatalf("mkdir target dir: %v", err)
	}
	initial := []byte("already there")
	if err := os.WriteFile(target, initial, 0o600); err != nil {
		t.Fatalf("write existing target: %v", err)
	}

	d := New(cfg)
	body := bytes.NewBufferString(`{"path":"` + sourcePath + `","to_dir":"` + restoreRoot + `","overwrite":true}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/restore/run", body)
	rr := httptest.NewRecorder()
	d.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("status code: got %d want %d", rr.Code, http.StatusBadRequest)
	}
	errResp := decodeErrorResponse(t, rr)
	if errResp.Code != "integrity_check_failed" {
		t.Fatalf("unexpected error code: got %q", errResp.Code)
	}

	got, err := os.ReadFile(target)
	if err != nil {
		t.Fatalf("read target: %v", err)
	}
	if !bytes.Equal(got, initial) {
		t.Fatalf("target changed on checksum failure: got %q want %q", string(got), string(initial))
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
	manifestPath := testManifestPath(t)
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

	manifestPath := testManifestPath(t)
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

	manifestPath := testManifestPath(t)
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
