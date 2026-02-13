package backup

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestBuildManifestWithOptionsExcludesPathsAndGlobs(t *testing.T) {
	root := t.TempDir()

	included := filepath.Join(root, "keep.txt")
	excludedDir := filepath.Join(root, "cache")
	excludedByGlob := filepath.Join(root, "debug.log")
	excludedByDirGlob := filepath.Join(root, "deps", "node_modules", "pkg.json")

	mustWriteTestFile(t, included, []byte("keep"))
	mustWriteTestFile(t, filepath.Join(excludedDir, "ignored.txt"), []byte("ignore"))
	mustWriteTestFile(t, excludedByGlob, []byte("ignore"))
	mustWriteTestFile(t, excludedByDirGlob, []byte("ignore"))

	manifest, err := BuildManifestWithOptions([]string{root}, BuildOptions{
		ExcludePaths: []string{excludedDir},
		ExcludeGlobs: []string{"*.log", "node_modules"},
	})
	if err != nil {
		t.Fatalf("build manifest with exclusions: %v", err)
	}

	got := make([]string, 0, len(manifest.Entries))
	for _, entry := range manifest.Entries {
		got = append(got, entry.Path)
	}
	want := []string{included}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("unexpected manifest paths: got %#v want %#v", got, want)
	}
}

func TestBuildManifestWithOptionsExcludesRootPath(t *testing.T) {
	root := t.TempDir()
	mustWriteTestFile(t, filepath.Join(root, "keep.txt"), []byte("keep"))

	manifest, err := BuildManifestWithOptions([]string{root}, BuildOptions{
		ExcludePaths: []string{root},
	})
	if err != nil {
		t.Fatalf("build manifest with excluded root: %v", err)
	}
	if len(manifest.Entries) != 0 {
		t.Fatalf("expected empty manifest when root is excluded, got %d entries", len(manifest.Entries))
	}
}

func mustWriteTestFile(t *testing.T, path string, data []byte) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir parent for %s: %v", path, err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatalf("write file %s: %v", path, err)
	}
}
