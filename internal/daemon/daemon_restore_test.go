package daemon

import (
	"bytes"
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
	"baxter/internal/crypto"
	"baxter/internal/recovery"
	"baxter/internal/state"
	"baxter/internal/storage"
)

var daemonTestKDFSalt = []byte("0123456789abcdef")

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
		KDFSalt:           daemonTestKDFSalt,
		BackupSetID:       "local-test",
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
		KDFSalt:           daemonTestKDFSalt,
		BackupSetID:       "local-test",
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

func TestRestoreRunEndpointFallsBackToRemoteMetadataWhenLocalCacheMissing(t *testing.T) {
	homeDir := t.TempDir()
	srcRoot := filepath.Join(t.TempDir(), "src")
	restoreRoot := filepath.Join(t.TempDir(), "restore")
	if err := os.MkdirAll(srcRoot, 0o755); err != nil {
		t.Fatalf("mkdir src root: %v", err)
	}
	sourcePath := filepath.Join(srcRoot, "doc.txt")
	sourceBody := []byte("daemon remote fallback body")
	if err := os.WriteFile(sourcePath, sourceBody, 0o600); err != nil {
		t.Fatalf("write source file: %v", err)
	}

	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)
	t.Setenv(passphraseEnv, "daemon-restore-fallback-passphrase")

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
		EncryptionKey:     crypto.KeyFromPassphraseWithSalt("daemon-restore-fallback-passphrase", daemonTestKDFSalt),
		KDFSalt:           daemonTestKDFSalt,
		BackupSetID:       recovery.BackupSetID(cfg),
		Store:             store,
	})
	if err != nil {
		t.Fatalf("run backup: %v", err)
	}
	clearDaemonRestoreCache(t)

	d := New(cfg)
	body := bytes.NewBufferString(`{"path":"` + sourcePath + `","to_dir":"` + restoreRoot + `"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/restore/run", body)
	rr := httptest.NewRecorder()
	d.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("status code: got %d want %d body=%s", rr.Code, http.StatusOK, rr.Body.String())
	}

	trimmedSource := strings.TrimPrefix(filepath.Clean(sourcePath), string(filepath.Separator))
	expectedTarget := filepath.Join(restoreRoot, trimmedSource)
	restored, err := os.ReadFile(expectedTarget)
	if err != nil {
		t.Fatalf("read restored file: %v", err)
	}
	if !bytes.Equal(restored, sourceBody) {
		t.Fatalf("restored body mismatch: got %q want %q", string(restored), string(sourceBody))
	}

	if _, err := os.Stat(manifestPath); err != nil {
		t.Fatalf("stat rebuilt manifest cache: %v", err)
	}
}

func TestRestoreRunEndpointRestoresDirectorySubtree(t *testing.T) {
	homeDir := t.TempDir()
	srcRoot := filepath.Join(t.TempDir(), "src")
	restoreRoot := filepath.Join(t.TempDir(), "restore")
	docsRoot := filepath.Join(srcRoot, "docs")
	if err := os.MkdirAll(filepath.Join(docsRoot, "reports"), 0o755); err != nil {
		t.Fatalf("mkdir docs reports: %v", err)
	}
	if err := os.MkdirAll(filepath.Join(srcRoot, "photos"), 0o755); err != nil {
		t.Fatalf("mkdir photos: %v", err)
	}

	reportPath := filepath.Join(docsRoot, "reports", "q1.txt")
	notePath := filepath.Join(docsRoot, "notes.txt")
	otherPath := filepath.Join(srcRoot, "photos", "ignore.bin")
	if err := os.WriteFile(reportPath, []byte("quarterly report"), 0o600); err != nil {
		t.Fatalf("write report: %v", err)
	}
	if err := os.WriteFile(notePath, []byte("notes"), 0o600); err != nil {
		t.Fatalf("write note: %v", err)
	}
	if err := os.WriteFile(otherPath, []byte("photo-bytes"), 0o600); err != nil {
		t.Fatalf("write other file: %v", err)
	}

	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)
	t.Setenv(passphraseEnv, "daemon-directory-restore-passphrase")

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
		EncryptionKey:     crypto.KeyFromPassphrase("daemon-directory-restore-passphrase"),
		KDFSalt:           daemonTestKDFSalt,
		BackupSetID:       "local-test",
		Store:             store,
	})
	if err != nil {
		t.Fatalf("run backup: %v", err)
	}

	d := New(cfg)
	restoreAt := time.Date(2026, time.February, 8, 12, 37, 0, 0, time.UTC)
	d.clockNow = func() time.Time { return restoreAt }

	body := bytes.NewBufferString(`{"path":"` + docsRoot + `","to_dir":"` + restoreRoot + `"}`)
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
	if restoreResp.SourcePath != docsRoot {
		t.Fatalf("unexpected source path: got %q want %q", restoreResp.SourcePath, docsRoot)
	}

	trimmedDocsRoot := strings.TrimPrefix(filepath.Clean(docsRoot), string(filepath.Separator))
	expectedTarget := filepath.Join(restoreRoot, trimmedDocsRoot)
	if restoreResp.TargetPath != expectedTarget {
		t.Fatalf("unexpected target path: got %q want %q", restoreResp.TargetPath, expectedTarget)
	}

	trimmedReportPath := strings.TrimPrefix(filepath.Clean(reportPath), string(filepath.Separator))
	trimmedNotePath := strings.TrimPrefix(filepath.Clean(notePath), string(filepath.Separator))
	trimmedOtherPath := strings.TrimPrefix(filepath.Clean(otherPath), string(filepath.Separator))

	if got, err := os.ReadFile(filepath.Join(restoreRoot, trimmedReportPath)); err != nil {
		t.Fatalf("read restored report: %v", err)
	} else if string(got) != "quarterly report" {
		t.Fatalf("unexpected report content: %q", string(got))
	}
	if got, err := os.ReadFile(filepath.Join(restoreRoot, trimmedNotePath)); err != nil {
		t.Fatalf("read restored note: %v", err)
	} else if string(got) != "notes" {
		t.Fatalf("unexpected note content: %q", string(got))
	}
	if _, err := os.Stat(filepath.Join(restoreRoot, trimmedOtherPath)); !os.IsNotExist(err) {
		t.Fatalf("unexpected restore outside subtree, stat err=%v", err)
	}

	status := d.snapshot()
	if status.LastRestorePath != docsRoot {
		t.Fatalf("unexpected last_restore_path: got %q want %q", status.LastRestorePath, docsRoot)
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
		KDFSalt:           daemonTestKDFSalt,
		BackupSetID:       "local-test",
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
		KDFSalt:           daemonTestKDFSalt,
		BackupSetID:       "local-test",
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

func TestRestoreRunEndpointReturnsObjectMissingCode(t *testing.T) {
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
		KDFSalt:           daemonTestKDFSalt,
		BackupSetID:       "local-test",
		Store:             store,
	})
	if err != nil {
		t.Fatalf("run backup: %v", err)
	}

	manifest, err := backup.LoadManifest(manifestPath)
	if err != nil {
		t.Fatalf("load manifest: %v", err)
	}
	entry, err := backup.FindEntryByPath(manifest, sourcePath)
	if err != nil {
		t.Fatalf("find manifest entry: %v", err)
	}
	if err := store.DeleteObject(backup.ResolveObjectKey(entry)); err != nil {
		t.Fatalf("delete object: %v", err)
	}

	d := New(cfg)
	body := bytes.NewBufferString(`{"path":"` + sourcePath + `","to_dir":"` + restoreRoot + `"}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/restore/run", body)
	rr := httptest.NewRecorder()
	d.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusNotFound {
		t.Fatalf("status code: got %d want %d body=%s", rr.Code, http.StatusNotFound, rr.Body.String())
	}
	errResp := decodeErrorResponse(t, rr)
	if errResp.Code != "restore_object_missing" {
		t.Fatalf("unexpected error code: got %q", errResp.Code)
	}
}

func TestRestoreRunEndpointReturnsStorageTransientCode(t *testing.T) {
	homeDir := t.TempDir()
	srcRoot := filepath.Join(t.TempDir(), "src")
	sourcePath := filepath.Join(srcRoot, "doc.txt")
	if err := os.MkdirAll(srcRoot, 0o755); err != nil {
		t.Fatalf("mkdir src root: %v", err)
	}

	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)
	t.Setenv(passphraseEnv, "daemon-restore-passphrase")

	manifestPath, err := state.ManifestPath()
	if err != nil {
		t.Fatalf("manifest path: %v", err)
	}
	manifest := &backup.Manifest{
		CreatedAt: time.Now().UTC(),
		Entries: []backup.ManifestEntry{
			{
				Path:   sourcePath,
				SHA256: strings.Repeat("0", 64),
			},
		},
	}
	if err := backup.SaveManifest(manifestPath, manifest); err != nil {
		t.Fatalf("save manifest: %v", err)
	}

	originalFactory := objectStoreFromConfig
	t.Cleanup(func() {
		objectStoreFromConfig = originalFactory
	})
	objectStoreFromConfig = func(_ config.S3Config, _ string) (storage.ObjectStore, error) {
		return transientReadStore{}, nil
	}

	d := New(config.DefaultConfig())
	req := httptest.NewRequest(http.MethodPost, "/v1/restore/run", bytes.NewBufferString(`{"path":"`+sourcePath+`"}`))
	rr := httptest.NewRecorder()
	d.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusServiceUnavailable {
		t.Fatalf("status code: got %d want %d body=%s", rr.Code, http.StatusServiceUnavailable, rr.Body.String())
	}
	errResp := decodeErrorResponse(t, rr)
	if errResp.Code != "restore_storage_transient" {
		t.Fatalf("unexpected error code: got %q", errResp.Code)
	}
}

func TestClassifyRestoreReadObjectError(t *testing.T) {
	statusCode, code, _ := classifyRestoreReadObjectError("/Users/me/doc.txt", os.ErrNotExist)
	if statusCode != http.StatusNotFound || code != "restore_object_missing" {
		t.Fatalf("unexpected not found classification: status=%d code=%s", statusCode, code)
	}

	statusCode, code, _ = classifyRestoreReadObjectError("/Users/me/doc.txt", storage.ErrTransient)
	if statusCode != http.StatusServiceUnavailable || code != "restore_storage_transient" {
		t.Fatalf("unexpected transient classification: status=%d code=%s", statusCode, code)
	}

	statusCode, code, _ = classifyRestoreReadObjectError("/Users/me/doc.txt", errors.New("boom"))
	if statusCode != http.StatusBadRequest || code != "read_object_failed" {
		t.Fatalf("unexpected fallback classification: status=%d code=%s", statusCode, code)
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

func clearDaemonRestoreCache(t *testing.T) {
	t.Helper()

	manifestPath, err := state.ManifestPath()
	if err != nil {
		t.Fatalf("manifest path: %v", err)
	}
	if err := os.Remove(manifestPath); err != nil && !os.IsNotExist(err) {
		t.Fatalf("remove manifest cache: %v", err)
	}

	snapshotDir, err := state.ManifestSnapshotsDir()
	if err != nil {
		t.Fatalf("snapshot dir: %v", err)
	}
	if err := os.RemoveAll(snapshotDir); err != nil {
		t.Fatalf("remove snapshot cache: %v", err)
	}

	saltPath, err := state.KDFSaltPath()
	if err != nil {
		t.Fatalf("kdf salt path: %v", err)
	}
	if err := os.Remove(saltPath); err != nil && !os.IsNotExist(err) {
		t.Fatalf("remove kdf salt: %v", err)
	}
}

type transientReadStore struct{}

func (transientReadStore) PutObject(string, []byte) error {
	return nil
}

func (transientReadStore) GetObject(string) ([]byte, error) {
	return nil, storage.ErrTransient
}

func (transientReadStore) DeleteObject(string) error {
	return nil
}

func (transientReadStore) ListKeys() ([]string, error) {
	return nil, nil
}
