package cli

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"baxter/internal/backup"
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

func TestParseRestoreListArgs(t *testing.T) {
	opts, err := parseRestoreListArgs([]string{"--prefix", "/Users/me", "--contains", "report"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if opts.Prefix != "/Users/me" || opts.Contains != "report" {
		t.Fatalf("unexpected opts: %+v", opts)
	}
}

func TestParseRestoreListArgsRejectsPositionalArgs(t *testing.T) {
	if _, err := parseRestoreListArgs([]string{"extra"}); err == nil {
		t.Fatal("expected usage error for extra args")
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

func TestResolvedRestorePathRejectsTraversal(t *testing.T) {
	if _, err := resolvedRestorePath("../etc/passwd", "/restore"); err == nil {
		t.Fatal("expected traversal path to be rejected")
	}
}

func TestFilterRestorePaths(t *testing.T) {
	entries := []backup.ManifestEntry{
		{Path: "/Users/me/Documents/report.txt"},
		{Path: "/Users/me/Pictures/photo.jpg"},
		{Path: "/Users/me/Documents/notes.md"},
	}

	got := filterRestorePaths(entries, restoreListOptions{
		Prefix:   "/Users/me/Documents",
		Contains: "report",
	})
	if len(got) != 1 || got[0] != "/Users/me/Documents/report.txt" {
		t.Fatalf("unexpected filter result: %+v", got)
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
	t.Setenv("XDG_CONFIG_HOME", homeDir)
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

	updatedContent := []byte("argon2 smoke test payload v2")
	if err := os.WriteFile(sourcePath, updatedContent, 0o600); err != nil {
		t.Fatalf("update source file: %v", err)
	}
	if err := runBackup(cfg); err != nil {
		t.Fatalf("second run backup failed: %v", err)
	}

	if err := restorePath(cfg, sourcePath, restoreOptions{ToDir: restoreRoot}); err == nil {
		t.Fatal("expected restore to fail when target exists without --overwrite")
	}
	if err := restorePath(cfg, sourcePath, restoreOptions{ToDir: restoreRoot, Overwrite: true}); err != nil {
		t.Fatalf("restore with overwrite failed: %v", err)
	}

	overwrittenContent, err := os.ReadFile(restoredPath)
	if err != nil {
		t.Fatalf("read overwritten file: %v", err)
	}
	if !bytes.Equal(overwrittenContent, updatedContent) {
		t.Fatalf("overwritten content mismatch: got %q want %q", string(overwrittenContent), string(updatedContent))
	}

	listOutput, err := captureStdout(t, func() error {
		return restoreList(restoreListOptions{
			Prefix:   srcRoot,
			Contains: "doc",
		})
	})
	if err != nil {
		t.Fatalf("restore list failed: %v", err)
	}

	lines := strings.Fields(strings.TrimSpace(listOutput))
	sort.Strings(lines)
	if len(lines) != 1 || lines[0] != sourcePath {
		t.Fatalf("unexpected restore list output: %q", listOutput)
	}
}

func captureStdout(t *testing.T, fn func() error) (string, error) {
	t.Helper()

	original := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	os.Stdout = w

	runErr := fn()
	_ = w.Close()
	os.Stdout = original

	out, readErr := io.ReadAll(r)
	_ = r.Close()
	if readErr != nil {
		t.Fatalf("read stdout: %v", readErr)
	}
	return string(out), runErr
}
