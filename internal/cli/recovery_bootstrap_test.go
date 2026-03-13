package cli

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"baxter/internal/backup"
	"baxter/internal/config"
	"baxter/internal/crypto"
	"baxter/internal/recovery"
	"baxter/internal/state"
	"baxter/internal/storage"
)

func TestRunRecoveryBootstrapRebuildsLocalCacheAndEnablesRestore(t *testing.T) {
	setCLIHome(t)

	srcRoot := filepath.Join(t.TempDir(), "src")
	restoreRoot := filepath.Join(t.TempDir(), "restore")
	if err := os.MkdirAll(srcRoot, 0o755); err != nil {
		t.Fatalf("mkdir src root: %v", err)
	}

	sourcePath := filepath.Join(srcRoot, "doc.txt")
	sourceContent := []byte("bootstrap restore payload")
	if err := os.WriteFile(sourcePath, sourceContent, 0o600); err != nil {
		t.Fatalf("write source file: %v", err)
	}

	t.Setenv(passphraseEnv, "bootstrap-passphrase")

	cfg := config.DefaultConfig()
	cfg.BackupRoots = []string{srcRoot}
	cfg.Schedule = "manual"

	store := testRecoveryBootstrapStore(t)
	seedRemoteRecoveryState(t, cfg, store, "bootstrap-passphrase", sourcePath)

	manifestPath, err := state.ManifestPath()
	if err != nil {
		t.Fatalf("manifest path: %v", err)
	}
	if _, err := os.Stat(manifestPath); !os.IsNotExist(err) {
		t.Fatalf("expected manifest cache to be absent before bootstrap, stat err=%v", err)
	}

	out, err := captureStdout(t, func() error {
		return Run([]string{"recovery", "bootstrap"})
	})
	if err != nil {
		t.Fatalf("run recovery bootstrap: %v", err)
	}
	if !strings.Contains(out, "recovery bootstrap complete: snapshot=") {
		t.Fatalf("unexpected bootstrap output: %q", out)
	}

	manifest, err := backup.LoadManifest(manifestPath)
	if err != nil {
		t.Fatalf("load rebuilt manifest: %v", err)
	}
	entry, err := backup.FindEntryByPath(manifest, sourcePath)
	if err != nil {
		t.Fatalf("find rebuilt manifest entry: %v", err)
	}
	if entry.Path != sourcePath {
		t.Fatalf("unexpected rebuilt manifest entry path: got %q want %q", entry.Path, sourcePath)
	}

	snapshotDir, err := state.ManifestSnapshotsDir()
	if err != nil {
		t.Fatalf("snapshot dir: %v", err)
	}
	snapshots, err := backup.ListSnapshotManifests(snapshotDir)
	if err != nil {
		t.Fatalf("list rebuilt snapshots: %v", err)
	}
	if len(snapshots) != 1 {
		t.Fatalf("expected 1 rebuilt snapshot, got %d", len(snapshots))
	}

	salt, err := readKDFSalt()
	if err != nil {
		t.Fatalf("read rebuilt salt: %v", err)
	}
	if err := crypto.ValidateKDFSalt(salt); err != nil {
		t.Fatalf("rebuilt salt invalid: %v", err)
	}

	if err := restorePath(cfg, sourcePath, restoreOptions{ToDir: restoreRoot}); err != nil {
		t.Fatalf("restore after bootstrap failed: %v", err)
	}

	trimmed := strings.TrimPrefix(filepath.Clean(sourcePath), string(filepath.Separator))
	restoredPath := filepath.Join(restoreRoot, trimmed)
	restoredContent, err := os.ReadFile(restoredPath)
	if err != nil {
		t.Fatalf("read restored file: %v", err)
	}
	if !bytes.Equal(restoredContent, sourceContent) {
		t.Fatalf("restored content mismatch: got %q want %q", string(restoredContent), string(sourceContent))
	}
}

func TestBootstrapRecoveryCacheRejectsWrongPassphrase(t *testing.T) {
	setCLIHome(t)

	srcRoot := filepath.Join(t.TempDir(), "src")
	if err := os.MkdirAll(srcRoot, 0o755); err != nil {
		t.Fatalf("mkdir src root: %v", err)
	}
	sourcePath := filepath.Join(srcRoot, "doc.txt")
	if err := os.WriteFile(sourcePath, []byte("wrong passphrase payload"), 0o600); err != nil {
		t.Fatalf("write source file: %v", err)
	}

	cfg := config.DefaultConfig()
	cfg.BackupRoots = []string{srcRoot}
	cfg.Schedule = "manual"

	store := testRecoveryBootstrapStore(t)
	seedRemoteRecoveryState(t, cfg, store, "correct-passphrase", sourcePath)
	t.Setenv(passphraseEnv, "wrong-passphrase")

	_, err := bootstrapRecoveryCache(cfg, store)
	if err == nil {
		t.Fatal("expected bootstrap to fail with wrong passphrase")
	}
	if !strings.Contains(err.Error(), "decrypt remote snapshot manifest") {
		t.Fatalf("unexpected wrong passphrase error: %v", err)
	}
}

func TestBootstrapRecoveryCacheReportsMissingMetadata(t *testing.T) {
	setCLIHome(t)
	t.Setenv(passphraseEnv, "bootstrap-passphrase")

	cfg := config.DefaultConfig()
	_, err := bootstrapRecoveryCache(cfg, testRecoveryBootstrapStore(t))
	if err == nil {
		t.Fatal("expected bootstrap to fail without recovery metadata")
	}
	if !strings.Contains(err.Error(), "read recovery metadata") {
		t.Fatalf("unexpected missing metadata error: %v", err)
	}
}

func seedRemoteRecoveryState(t *testing.T, cfg *config.Config, store storage.ObjectStore, passphrase string, sourcePath string) {
	t.Helper()

	manifestPath := filepath.Join(t.TempDir(), "seed-manifest.json")
	snapshotDir := filepath.Join(t.TempDir(), "seed-manifests")
	salt, err := crypto.NewKDFSalt()
	if err != nil {
		t.Fatalf("generate salt: %v", err)
	}

	keys, err := deriveEncryptionKeysWithSalt(passphrase, salt)
	if err != nil {
		t.Fatalf("derive keys: %v", err)
	}

	if _, err := backup.Run(cfg, backup.RunOptions{
		ManifestPath:      manifestPath,
		SnapshotDir:       snapshotDir,
		SnapshotRetention: 30,
		EncryptionKey:     keys.primary,
		KDFSalt:           salt,
		BackupSetID:       recovery.BackupSetID(cfg),
		Store:             store,
	}); err != nil {
		t.Fatalf("seed backup run: %v", err)
	}

	localManifest, err := backup.LoadManifest(manifestPath)
	if err != nil {
		t.Fatalf("load seeded manifest: %v", err)
	}
	if _, err := backup.FindEntryByPath(localManifest, sourcePath); err != nil {
		t.Fatalf("seeded manifest missing source path: %v", err)
	}
}

func testRecoveryBootstrapStore(t *testing.T) storage.ObjectStore {
	t.Helper()

	objectsDir, err := state.ObjectStoreDir()
	if err != nil {
		t.Fatalf("object store dir: %v", err)
	}
	return storage.NewLocalClient(objectsDir)
}
