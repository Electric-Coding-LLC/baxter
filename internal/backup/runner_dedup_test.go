package backup

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"baxter/internal/config"
	"baxter/internal/storage"
)

type countingStore struct {
	storage.ObjectStore
	mu   sync.Mutex
	puts map[string]int
}

func (s *countingStore) PutObject(key string, data []byte) error {
	s.mu.Lock()
	s.puts[key]++
	s.mu.Unlock()
	return s.ObjectStore.PutObject(key, data)
}

func (s *countingStore) contentPuts() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	count := 0
	for key, n := range s.puts {
		if strings.HasPrefix(key, contentObjectKeyPrefix) {
			count += n
		}
	}
	return count
}

func (s *countingStore) reset() {
	s.mu.Lock()
	s.puts = map[string]int{}
	s.mu.Unlock()
}

func newDedupRun(t *testing.T) (string, *config.Config, RunOptions, *countingStore) {
	t.Helper()
	root := t.TempDir()
	stateDir := t.TempDir()
	store := &countingStore{
		ObjectStore: storage.NewLocalClient(filepath.Join(stateDir, "objects")),
		puts:        map[string]int{},
	}
	opts := RunOptions{
		ManifestPath:  filepath.Join(stateDir, "manifest.json"),
		SnapshotDir:   filepath.Join(stateDir, "manifests"),
		EncryptionKey: []byte("01234567890123456789012345678901"),
		KDFSalt:       testKDFSalt,
		BackupSetID:   "local-test",
		Store:         store,
	}
	return root, &config.Config{BackupRoots: []string{root}}, opts, store
}

func writeDedupFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

func assertLatestManifestVerifies(t *testing.T, opts RunOptions, wantEntries int) {
	t.Helper()
	manifest, err := LoadManifest(opts.ManifestPath)
	if err != nil {
		t.Fatal(err)
	}
	if len(manifest.Entries) != wantEntries {
		t.Fatalf("manifest entries = %d, want %d", len(manifest.Entries), wantEntries)
	}
	verified, err := VerifyManifestEntries(manifest.Entries, opts.EncryptionKey, opts.Store)
	if err != nil || verified.HasFailures() || verified.OK != wantEntries {
		t.Fatalf("manifest must remain restorable: %+v, %v", verified, err)
	}
}

func TestRunDoesNotReuploadRenamedDirectory(t *testing.T) {
	root, cfg, opts, store := newDedupRun(t)
	writeDedupFile(t, filepath.Join(root, "old", "a.txt"), "alpha")
	writeDedupFile(t, filepath.Join(root, "old", "nested", "b.txt"), "bravo")
	if _, err := Run(cfg, opts); err != nil {
		t.Fatal(err)
	}
	store.reset()

	if err := os.Rename(filepath.Join(root, "old"), filepath.Join(root, "new")); err != nil {
		t.Fatal(err)
	}
	result, err := Run(cfg, opts)
	if err != nil {
		t.Fatal(err)
	}
	if result.Uploaded != 0 || result.Removed != 2 || result.Total != 2 {
		t.Fatalf("unexpected result: %+v", result)
	}
	if got := store.contentPuts(); got != 0 {
		t.Fatalf("renamed files stored %d objects, want 0", got)
	}
	assertLatestManifestVerifies(t, opts, 2)
}

func TestRunUploadsIdenticalNewFilesOnce(t *testing.T) {
	root, cfg, opts, store := newDedupRun(t)
	writeDedupFile(t, filepath.Join(root, "one.txt"), "same content")
	writeDedupFile(t, filepath.Join(root, "two.txt"), "same content")
	writeDedupFile(t, filepath.Join(root, "three.txt"), "other content")

	result, err := Run(cfg, opts)
	if err != nil {
		t.Fatal(err)
	}
	if result.Uploaded != 2 || result.Total != 3 {
		t.Fatalf("unexpected result: %+v", result)
	}
	if got := store.contentPuts(); got != 2 {
		t.Fatalf("stored %d objects, want 2", got)
	}
	assertLatestManifestVerifies(t, opts, 3)
}

func TestRunStillUploadsChangedContent(t *testing.T) {
	root, cfg, opts, store := newDedupRun(t)
	path := filepath.Join(root, "document.txt")
	writeDedupFile(t, path, "first")
	if _, err := Run(cfg, opts); err != nil {
		t.Fatal(err)
	}
	store.reset()

	writeDedupFile(t, path, "second version")
	result, err := Run(cfg, opts)
	if err != nil {
		t.Fatal(err)
	}
	if result.Uploaded != 1 || store.contentPuts() != 1 {
		t.Fatalf("unexpected result: %+v, puts=%d", result, store.contentPuts())
	}
	assertLatestManifestVerifies(t, opts, 1)
}

func TestRunUploadsDuplicateContentWhenFirstCopyVanishes(t *testing.T) {
	root, cfg, opts, store := newDedupRun(t)
	first := filepath.Join(root, "a.txt")
	writeDedupFile(t, first, "same content")
	writeDedupFile(t, filepath.Join(root, "b.txt"), "same content")

	var once sync.Once
	opts.Progress = func(ProgressUpdate) {
		once.Do(func() {
			if err := os.Remove(first); err != nil {
				t.Error(err)
			}
		})
	}
	result, err := Run(cfg, opts)
	if err != nil {
		t.Fatal(err)
	}
	if result.Uploaded != 1 || result.Total != 1 || store.contentPuts() != 1 {
		t.Fatalf("unexpected result: %+v, puts=%d", result, store.contentPuts())
	}
	assertLatestManifestVerifies(t, opts, 1)
}
