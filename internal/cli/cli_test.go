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
	"baxter/internal/state"
)

func TestParseRestoreArgs(t *testing.T) {
	opts, path, err := parseRestoreArgs([]string{"--dry-run", "--to", "/tmp/out", "--overwrite", "--snapshot", "latest", "/src/file.txt"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !opts.DryRun || !opts.Overwrite || opts.ToDir != "/tmp/out" || opts.Snapshot != "latest" {
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

func TestParseRestoreArgsRejectsDryRunAndVerifyOnly(t *testing.T) {
	if _, _, err := parseRestoreArgs([]string{"--dry-run", "--verify-only", "/src/file.txt"}); err == nil {
		t.Fatal("expected error for mutually exclusive flags")
	}
}

func TestParseRestoreListArgs(t *testing.T) {
	opts, err := parseRestoreListArgs([]string{"--snapshot", "2026-01-01T00:00:00Z", "--prefix", "/Users/me", "--contains", "report"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if opts.Prefix != "/Users/me" || opts.Contains != "report" || opts.Snapshot != "2026-01-01T00:00:00Z" {
		t.Fatalf("unexpected opts: %+v", opts)
	}
}

func TestParseRestoreListArgsRejectsPositionalArgs(t *testing.T) {
	if _, err := parseRestoreListArgs([]string{"extra"}); err == nil {
		t.Fatal("expected usage error for extra args")
	}
}

func TestParseSnapshotListArgs(t *testing.T) {
	opts, err := parseSnapshotListArgs([]string{"--limit", "5"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if opts.Limit != 5 {
		t.Fatalf("unexpected limit: %d", opts.Limit)
	}
}

func TestParseSnapshotListArgsRejectsNegativeLimit(t *testing.T) {
	if _, err := parseSnapshotListArgs([]string{"--limit", "-1"}); err == nil {
		t.Fatal("expected negative limit to be rejected")
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

func TestRunBackupAndRestoreNestedPaths(t *testing.T) {
	homeDir := t.TempDir()
	srcRoot := filepath.Join(t.TempDir(), "src")
	restoreRoot := filepath.Join(t.TempDir(), "restore")

	if err := os.MkdirAll(filepath.Join(srcRoot, "docs", "reports"), 0o755); err != nil {
		t.Fatalf("mkdir nested docs: %v", err)
	}
	if err := os.MkdirAll(filepath.Join(srcRoot, "photos", "raw"), 0o755); err != nil {
		t.Fatalf("mkdir nested photos: %v", err)
	}

	textPath := filepath.Join(srcRoot, "docs", "reports", "q1.txt")
	textBody := []byte("quarterly report")
	if err := os.WriteFile(textPath, textBody, 0o600); err != nil {
		t.Fatalf("write text source file: %v", err)
	}

	binPath := filepath.Join(srcRoot, "photos", "raw", "image.bin")
	binBody := []byte{0x00, 0x01, 0x02, 0x03, 0xFE, 0xFF}
	if err := os.WriteFile(binPath, binBody, 0o600); err != nil {
		t.Fatalf("write binary source file: %v", err)
	}

	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)
	t.Setenv(passphraseEnv, "nested-test-passphrase")

	cfg := config.DefaultConfig()
	cfg.BackupRoots = []string{srcRoot}
	cfg.Schedule = "manual"

	if err := runBackup(cfg); err != nil {
		t.Fatalf("run backup failed: %v", err)
	}

	if err := restorePath(cfg, textPath, restoreOptions{ToDir: restoreRoot, DryRun: true}); err != nil {
		t.Fatalf("restore dry-run failed: %v", err)
	}
	trimmedTextPath := strings.TrimPrefix(filepath.Clean(textPath), string(filepath.Separator))
	dryRunTarget := filepath.Join(restoreRoot, trimmedTextPath)
	if _, err := os.Stat(dryRunTarget); !os.IsNotExist(err) {
		t.Fatalf("dry-run should not create files, stat err=%v", err)
	}

	if err := restorePath(cfg, textPath, restoreOptions{ToDir: restoreRoot}); err != nil {
		t.Fatalf("restore nested text failed: %v", err)
	}
	if err := restorePath(cfg, binPath, restoreOptions{ToDir: restoreRoot}); err != nil {
		t.Fatalf("restore nested binary failed: %v", err)
	}

	trimmedBinPath := strings.TrimPrefix(filepath.Clean(binPath), string(filepath.Separator))
	restoredTextPath := filepath.Join(restoreRoot, trimmedTextPath)
	restoredBinPath := filepath.Join(restoreRoot, trimmedBinPath)

	restoredText, err := os.ReadFile(restoredTextPath)
	if err != nil {
		t.Fatalf("read restored text file: %v", err)
	}
	if !bytes.Equal(restoredText, textBody) {
		t.Fatalf("restored text mismatch: got %q want %q", string(restoredText), string(textBody))
	}

	restoredBin, err := os.ReadFile(restoredBinPath)
	if err != nil {
		t.Fatalf("read restored binary file: %v", err)
	}
	if !bytes.Equal(restoredBin, binBody) {
		t.Fatalf("restored binary mismatch: got %v want %v", restoredBin, binBody)
	}

	updated := []byte("quarterly report v2")
	if err := os.WriteFile(textPath, updated, 0o600); err != nil {
		t.Fatalf("update nested text source: %v", err)
	}
	if err := runBackup(cfg); err != nil {
		t.Fatalf("second run backup failed: %v", err)
	}

	if err := restorePath(cfg, textPath, restoreOptions{ToDir: restoreRoot}); err == nil {
		t.Fatal("expected restore to fail when target exists without --overwrite")
	}
	if err := restorePath(cfg, textPath, restoreOptions{ToDir: restoreRoot, Overwrite: true}); err != nil {
		t.Fatalf("restore overwrite failed: %v", err)
	}

	restoredUpdated, err := os.ReadFile(restoredTextPath)
	if err != nil {
		t.Fatalf("read overwritten nested text: %v", err)
	}
	if !bytes.Equal(restoredUpdated, updated) {
		t.Fatalf("overwritten nested text mismatch: got %q want %q", string(restoredUpdated), string(updated))
	}
}

func TestRestorePathFromOlderSnapshotAfterDeletion(t *testing.T) {
	homeDir := t.TempDir()
	srcRoot := filepath.Join(t.TempDir(), "src")
	restoreRoot := filepath.Join(t.TempDir(), "restore")

	if err := os.MkdirAll(srcRoot, 0o755); err != nil {
		t.Fatalf("mkdir src root: %v", err)
	}
	sourcePath := filepath.Join(srcRoot, "doc.txt")
	sourceContent := []byte("snapshot restore payload")
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
		t.Fatalf("initial run backup failed: %v", err)
	}

	snapshotDir, err := state.ManifestSnapshotsDir()
	if err != nil {
		t.Fatalf("resolve snapshot dir: %v", err)
	}
	snapshots, err := backup.ListSnapshotManifests(snapshotDir)
	if err != nil {
		t.Fatalf("list snapshots: %v", err)
	}
	if len(snapshots) == 0 {
		t.Fatal("expected at least one snapshot")
	}
	oldestSnapshotID := snapshots[len(snapshots)-1].ID

	if err := os.Remove(sourcePath); err != nil {
		t.Fatalf("remove source file: %v", err)
	}
	if err := runBackup(cfg); err != nil {
		t.Fatalf("second run backup failed: %v", err)
	}

	if err := restorePath(cfg, sourcePath, restoreOptions{ToDir: restoreRoot}); err == nil {
		t.Fatal("expected latest restore to fail for deleted file")
	}

	if err := restorePath(cfg, sourcePath, restoreOptions{ToDir: restoreRoot, Snapshot: oldestSnapshotID}); err != nil {
		t.Fatalf("restore from old snapshot failed: %v", err)
	}

	trimmed := strings.TrimPrefix(filepath.Clean(sourcePath), string(filepath.Separator))
	restoredPath := filepath.Join(restoreRoot, trimmed)
	restoredContent, err := os.ReadFile(restoredPath)
	if err != nil {
		t.Fatalf("read restored content: %v", err)
	}
	if !bytes.Equal(restoredContent, sourceContent) {
		t.Fatalf("restored content mismatch: got %q want %q", string(restoredContent), string(sourceContent))
	}
}

func TestRestorePathVerifyOnlyDoesNotWrite(t *testing.T) {
	homeDir := t.TempDir()
	srcRoot := filepath.Join(t.TempDir(), "src")
	restoreRoot := filepath.Join(t.TempDir(), "restore")

	if err := os.MkdirAll(srcRoot, 0o755); err != nil {
		t.Fatalf("mkdir src root: %v", err)
	}
	sourcePath := filepath.Join(srcRoot, "doc.txt")
	sourceContent := []byte("verify-only payload")
	if err := os.WriteFile(sourcePath, sourceContent, 0o600); err != nil {
		t.Fatalf("write source file: %v", err)
	}

	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)
	t.Setenv(passphraseEnv, "verify-only-passphrase")

	cfg := config.DefaultConfig()
	cfg.BackupRoots = []string{srcRoot}
	cfg.Schedule = "manual"

	if err := runBackup(cfg); err != nil {
		t.Fatalf("run backup failed: %v", err)
	}
	if err := restorePath(cfg, sourcePath, restoreOptions{ToDir: restoreRoot, VerifyOnly: true}); err != nil {
		t.Fatalf("verify-only restore failed: %v", err)
	}

	trimmed := strings.TrimPrefix(filepath.Clean(sourcePath), string(filepath.Separator))
	target := filepath.Join(restoreRoot, trimmed)
	if _, err := os.Stat(target); !os.IsNotExist(err) {
		t.Fatalf("verify-only should not write target, stat err=%v", err)
	}
}

func TestRestorePathChecksumMismatchDoesNotOverwriteTarget(t *testing.T) {
	homeDir := t.TempDir()
	srcRoot := filepath.Join(t.TempDir(), "src")
	restoreRoot := filepath.Join(t.TempDir(), "restore")

	if err := os.MkdirAll(srcRoot, 0o755); err != nil {
		t.Fatalf("mkdir src root: %v", err)
	}
	sourcePath := filepath.Join(srcRoot, "doc.txt")
	sourceContent := []byte("checksum payload")
	if err := os.WriteFile(sourcePath, sourceContent, 0o600); err != nil {
		t.Fatalf("write source file: %v", err)
	}

	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)
	t.Setenv(passphraseEnv, "checksum-passphrase")

	cfg := config.DefaultConfig()
	cfg.BackupRoots = []string{srcRoot}
	cfg.Schedule = "manual"

	if err := runBackup(cfg); err != nil {
		t.Fatalf("run backup failed: %v", err)
	}

	manifestPath, err := state.ManifestPath()
	if err != nil {
		t.Fatalf("manifest path: %v", err)
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

	trimmed := strings.TrimPrefix(filepath.Clean(sourcePath), string(filepath.Separator))
	target := filepath.Join(restoreRoot, trimmed)
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		t.Fatalf("mkdir target dir: %v", err)
	}
	initial := []byte("existing")
	if err := os.WriteFile(target, initial, 0o600); err != nil {
		t.Fatalf("write existing target: %v", err)
	}

	if err := restorePath(cfg, sourcePath, restoreOptions{ToDir: restoreRoot, Overwrite: true}); err == nil {
		t.Fatal("expected checksum mismatch restore to fail")
	}

	got, err := os.ReadFile(target)
	if err != nil {
		t.Fatalf("read target: %v", err)
	}
	if !bytes.Equal(got, initial) {
		t.Fatalf("target changed on checksum failure: got %q want %q", string(got), string(initial))
	}
}

func TestRunBackupAndRestoreEdgeFilenames(t *testing.T) {
	homeDir := t.TempDir()
	srcRoot := filepath.Join(t.TempDir(), "source with spaces")
	restoreRoot := filepath.Join(t.TempDir(), "restore")

	deepDir := filepath.Join(srcRoot, "level1", "level2", "level3", "level4", "level5")
	if err := os.MkdirAll(deepDir, 0o755); err != nil {
		t.Fatalf("mkdir deep dir: %v", err)
	}

	unicodeName := "r\u00E9sum\u00E9 final.txt"
	spaceName := "report final 2026.txt"
	unicodePath := filepath.Join(deepDir, unicodeName)
	spacePath := filepath.Join(srcRoot, "level1", "notes", spaceName)
	if err := os.MkdirAll(filepath.Dir(spacePath), 0o755); err != nil {
		t.Fatalf("mkdir notes dir: %v", err)
	}

	unicodeBody := []byte("unicode filename payload")
	spaceBody := []byte("space filename payload")
	if err := os.WriteFile(unicodePath, unicodeBody, 0o600); err != nil {
		t.Fatalf("write unicode source file: %v", err)
	}
	if err := os.WriteFile(spacePath, spaceBody, 0o600); err != nil {
		t.Fatalf("write spaced source file: %v", err)
	}

	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)
	t.Setenv(passphraseEnv, "edge-path-passphrase")

	cfg := config.DefaultConfig()
	cfg.BackupRoots = []string{srcRoot}
	cfg.Schedule = "manual"

	if err := runBackup(cfg); err != nil {
		t.Fatalf("run backup failed: %v", err)
	}

	if err := restorePath(cfg, unicodePath, restoreOptions{ToDir: restoreRoot, DryRun: true}); err != nil {
		t.Fatalf("restore dry-run failed: %v", err)
	}
	trimmedUnicode := strings.TrimPrefix(filepath.Clean(unicodePath), string(filepath.Separator))
	dryRunTarget := filepath.Join(restoreRoot, trimmedUnicode)
	if _, err := os.Stat(dryRunTarget); !os.IsNotExist(err) {
		t.Fatalf("dry-run should not write target, stat err=%v", err)
	}

	if err := restorePath(cfg, unicodePath, restoreOptions{ToDir: restoreRoot}); err != nil {
		t.Fatalf("restore unicode file failed: %v", err)
	}
	if err := restorePath(cfg, spacePath, restoreOptions{ToDir: restoreRoot}); err != nil {
		t.Fatalf("restore spaced file failed: %v", err)
	}

	trimmedSpace := strings.TrimPrefix(filepath.Clean(spacePath), string(filepath.Separator))
	restoredUnicode := filepath.Join(restoreRoot, trimmedUnicode)
	restoredSpace := filepath.Join(restoreRoot, trimmedSpace)

	gotUnicode, err := os.ReadFile(restoredUnicode)
	if err != nil {
		t.Fatalf("read restored unicode file: %v", err)
	}
	if !bytes.Equal(gotUnicode, unicodeBody) {
		t.Fatalf("unicode restore mismatch: got %q want %q", string(gotUnicode), string(unicodeBody))
	}
	gotSpace, err := os.ReadFile(restoredSpace)
	if err != nil {
		t.Fatalf("read restored spaced file: %v", err)
	}
	if !bytes.Equal(gotSpace, spaceBody) {
		t.Fatalf("space restore mismatch: got %q want %q", string(gotSpace), string(spaceBody))
	}

	updated := []byte("space filename payload v2")
	if err := os.WriteFile(spacePath, updated, 0o600); err != nil {
		t.Fatalf("update spaced source file: %v", err)
	}
	if err := runBackup(cfg); err != nil {
		t.Fatalf("second run backup failed: %v", err)
	}

	if err := restorePath(cfg, spacePath, restoreOptions{ToDir: restoreRoot}); err == nil {
		t.Fatal("expected restore to require --overwrite for existing target")
	}
	if err := restorePath(cfg, spacePath, restoreOptions{ToDir: restoreRoot, Overwrite: true}); err != nil {
		t.Fatalf("restore overwrite failed: %v", err)
	}
	gotUpdated, err := os.ReadFile(restoredSpace)
	if err != nil {
		t.Fatalf("read overwritten spaced file: %v", err)
	}
	if !bytes.Equal(gotUpdated, updated) {
		t.Fatalf("overwrite mismatch: got %q want %q", string(gotUpdated), string(updated))
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
