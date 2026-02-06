package cli

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"baxter/internal/config"
)

func TestParseRestoreArgs(t *testing.T) {
	opts, path, err := parseRestoreArgs([]string{"--dry-run", "--to", "/tmp/out", "--overwrite", "/src/file.txt"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !opts.DryRun || !opts.Overwrite || opts.ToDir != "/tmp/out" {
		t.Fatalf("unexpected opts: %+v", opts)
	}
	if path != "/src/file.txt" {
		t.Fatalf("unexpected path: %s", path)
	}
}

func TestParseRestoreArgsRequiresPath(t *testing.T) {
	if _, _, err := parseRestoreArgs([]string{"--dry-run"}); err == nil {
		t.Fatal("expected usage error for missing path")
	}
}

func TestResolvedRestorePath(t *testing.T) {
	got, err := resolvedRestorePath("/Users/me/file.txt", "/restore")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != "/restore/Users/me/file.txt" {
		t.Fatalf("resolved path mismatch: got %s", got)
	}
}

func TestResolvedRestorePathNoDestination(t *testing.T) {
	got, err := resolvedRestorePath("/Users/me/file.txt", "")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != "/Users/me/file.txt" {
		t.Fatalf("unexpected path: %s", got)
	}
}

func TestRunBackupAndRestorePathWithPassphrase(t *testing.T) {
	homeDir := t.TempDir()
	srcRoot := filepath.Join(t.TempDir(), "src")
	restoreRoot := filepath.Join(t.TempDir(), "restore")

	if err := os.MkdirAll(srcRoot, 0o755); err != nil {
		t.Fatalf("mkdir src root: %v", err)
	}
	sourcePath := filepath.Join(srcRoot, "doc.txt")
	sourceContent := []byte("argon2 smoke test payload")
	if err := os.WriteFile(sourcePath, sourceContent, 0o600); err != nil {
		t.Fatalf("write source file: %v", err)
	}

	t.Setenv("HOME", homeDir)
	t.Setenv(passphraseEnv, "test-passphrase")

	cfg := config.DefaultConfig()
	cfg.BackupRoots = []string{srcRoot}
	cfg.Schedule = "manual"
	cfg.S3.Bucket = ""

	if err := runBackup(cfg); err != nil {
		t.Fatalf("run backup failed: %v", err)
	}

	if err := restorePath(cfg, sourcePath, restoreOptions{ToDir: restoreRoot}); err != nil {
		t.Fatalf("restore failed: %v", err)
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
