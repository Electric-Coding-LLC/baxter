package cli

import "testing"

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
