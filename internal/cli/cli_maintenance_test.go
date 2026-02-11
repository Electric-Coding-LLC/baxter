package cli

import (
	"os"
	"path/filepath"
	"testing"

	"baxter/internal/backup"
	"baxter/internal/config"
	"baxter/internal/state"
)

func TestRunGCDryRunAndDelete(t *testing.T) {
	homeDir := t.TempDir()
	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)

	cfg := config.DefaultConfig()
	cfg.S3.Bucket = ""

	referencedPath := "/Users/me/Documents/keep.txt"
	referencedKey := backup.ObjectKeyForPath(referencedPath)
	orphanPath := "/Users/me/Documents/orphan.txt"
	orphanKey := backup.ObjectKeyForPath(orphanPath)

	store, err := objectStoreFromConfig(cfg)
	if err != nil {
		t.Fatalf("object store: %v", err)
	}
	if err := store.PutObject(referencedKey, []byte("keep")); err != nil {
		t.Fatalf("put referenced object: %v", err)
	}
	if err := store.PutObject(orphanKey, []byte("orphan")); err != nil {
		t.Fatalf("put orphan object: %v", err)
	}

	manifestPath, err := state.ManifestPath()
	if err != nil {
		t.Fatalf("manifest path: %v", err)
	}
	if err := backup.SaveManifest(manifestPath, &backup.Manifest{
		Entries: []backup.ManifestEntry{{Path: referencedPath}},
	}); err != nil {
		t.Fatalf("save manifest: %v", err)
	}

	if err := runGC(cfg, gcOptions{DryRun: true}); err != nil {
		t.Fatalf("run gc dry-run: %v", err)
	}
	if _, err := store.GetObject(referencedKey); err != nil {
		t.Fatalf("referenced key should remain after dry-run: %v", err)
	}
	if _, err := store.GetObject(orphanKey); err != nil {
		t.Fatalf("orphan key should remain after dry-run: %v", err)
	}

	if err := runGC(cfg, gcOptions{}); err != nil {
		t.Fatalf("run gc delete: %v", err)
	}
	if _, err := store.GetObject(referencedKey); err != nil {
		t.Fatalf("referenced key should remain after gc: %v", err)
	}
	if _, err := store.GetObject(orphanKey); !os.IsNotExist(err) {
		t.Fatalf("orphan key should be deleted, err=%v", err)
	}
}

func TestRunVerifyDetectsMissingObjects(t *testing.T) {
	homeDir := t.TempDir()
	srcRoot := filepath.Join(t.TempDir(), "src")
	if err := os.MkdirAll(srcRoot, 0o755); err != nil {
		t.Fatalf("mkdir src root: %v", err)
	}

	sourcePath := filepath.Join(srcRoot, "doc.txt")
	if err := os.WriteFile(sourcePath, []byte("verify test payload"), 0o600); err != nil {
		t.Fatalf("write source file: %v", err)
	}

	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)
	t.Setenv(passphraseEnv, "verify-test-passphrase")

	cfg := config.DefaultConfig()
	cfg.BackupRoots = []string{srcRoot}
	cfg.Schedule = "manual"
	cfg.S3.Bucket = ""

	if err := runBackup(cfg); err != nil {
		t.Fatalf("run backup failed: %v", err)
	}

	store, err := objectStoreFromConfig(cfg)
	if err != nil {
		t.Fatalf("object store: %v", err)
	}
	if err := store.DeleteObject(backup.ObjectKeyForPath(sourcePath)); err != nil {
		t.Fatalf("delete object: %v", err)
	}

	if err := runVerify(cfg, verifyOptions{}); err == nil {
		t.Fatal("expected verify to fail for missing object")
	}
}
