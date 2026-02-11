package cli

import (
	"testing"

	"baxter/internal/backup"
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

func TestParseGCArgs(t *testing.T) {
	opts, err := parseGCArgs([]string{"--dry-run"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !opts.DryRun {
		t.Fatal("expected dry-run=true")
	}
}

func TestParseGCArgsRejectsPositionalArgs(t *testing.T) {
	if _, err := parseGCArgs([]string{"extra"}); err == nil {
		t.Fatal("expected usage error for extra args")
	}
}

func TestParseVerifyArgs(t *testing.T) {
	opts, err := parseVerifyArgs([]string{"--snapshot", "latest", "--prefix", "/Users/me", "--limit", "10", "--sample", "5"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if opts.Snapshot != "latest" || opts.Prefix != "/Users/me" || opts.Limit != 10 || opts.Sample != 5 {
		t.Fatalf("unexpected opts: %+v", opts)
	}
}

func TestParseVerifyArgsRejectsInvalidValues(t *testing.T) {
	if _, err := parseVerifyArgs([]string{"--limit", "-1"}); err == nil {
		t.Fatal("expected negative limit to be rejected")
	}
	if _, err := parseVerifyArgs([]string{"--sample", "-1"}); err == nil {
		t.Fatal("expected negative sample to be rejected")
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

func TestSampleManifestEntries(t *testing.T) {
	entries := []backup.ManifestEntry{
		{Path: "/a"},
		{Path: "/b"},
		{Path: "/c"},
		{Path: "/d"},
		{Path: "/e"},
	}

	got := sampleManifestEntries(entries, 3)
	if len(got) != 3 {
		t.Fatalf("unexpected sample size: %d", len(got))
	}
	if got[0].Path != "/a" || got[1].Path != "/c" || got[2].Path != "/e" {
		t.Fatalf("unexpected sample entries: %+v", got)
	}
}
