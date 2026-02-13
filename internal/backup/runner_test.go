package backup

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"baxter/internal/config"
	"baxter/internal/storage"
)

type flakyStore struct {
	inner        storage.ObjectStore
	failPuts     int
	putCallCount int
}

func (s *flakyStore) PutObject(key string, data []byte) error {
	s.putCallCount++
	if s.failPuts > 0 {
		s.failPuts--
		return errors.New("transient upload error")
	}
	return s.inner.PutObject(key, data)
}

func (s *flakyStore) GetObject(key string) ([]byte, error) {
	return s.inner.GetObject(key)
}

func (s *flakyStore) DeleteObject(key string) error {
	return s.inner.DeleteObject(key)
}

func (s *flakyStore) ListKeys() ([]string, error) {
	return s.inner.ListKeys()
}

func TestRunUploadsAndSavesManifest(t *testing.T) {
	root := t.TempDir()
	manifestPath := filepath.Join(t.TempDir(), "manifest.json")
	snapshotDir := filepath.Join(t.TempDir(), "manifests")
	objectsDir := filepath.Join(t.TempDir(), "objects")

	filePath := filepath.Join(root, "doc.txt")
	if err := os.WriteFile(filePath, []byte("hello"), 0o600); err != nil {
		t.Fatalf("write source file: %v", err)
	}

	cfg := &config.Config{
		BackupRoots: []string{root},
		S3:          config.S3Config{},
		Encryption:  config.EncryptionConfig{},
	}
	store := storage.NewLocalClient(objectsDir)

	result, err := Run(cfg, RunOptions{
		ManifestPath:      manifestPath,
		SnapshotDir:       snapshotDir,
		SnapshotRetention: 30,
		EncryptionKey:     []byte("01234567890123456789012345678901"),
		Store:             store,
	})
	if err != nil {
		t.Fatalf("run backup: %v", err)
	}
	if result.Uploaded != 1 || result.Removed != 0 || result.Total != 1 {
		t.Fatalf("unexpected result: %+v", result)
	}

	if _, err := os.Stat(manifestPath); err != nil {
		t.Fatalf("manifest not written: %v", err)
	}

	keys, err := store.ListKeys()
	if err != nil {
		t.Fatalf("list keys: %v", err)
	}
	if len(keys) != 1 {
		t.Fatalf("unexpected key count: %d", len(keys))
	}

	snapshots, err := ListSnapshotManifests(snapshotDir)
	if err != nil {
		t.Fatalf("list snapshots: %v", err)
	}
	if len(snapshots) != 1 {
		t.Fatalf("unexpected snapshot count: %d", len(snapshots))
	}
}

func TestRunKeepsRemovedFileObjectsForSnapshotRestore(t *testing.T) {
	root := t.TempDir()
	manifestPath := filepath.Join(t.TempDir(), "manifest.json")
	snapshotDir := filepath.Join(t.TempDir(), "manifests")
	objectsDir := filepath.Join(t.TempDir(), "objects")
	key := []byte("01234567890123456789012345678901")

	filePath := filepath.Join(root, "doc.txt")
	if err := os.WriteFile(filePath, []byte("v1"), 0o600); err != nil {
		t.Fatalf("write source file: %v", err)
	}

	cfg := &config.Config{
		BackupRoots: []string{root},
		S3:          config.S3Config{},
		Encryption:  config.EncryptionConfig{},
	}
	store := storage.NewLocalClient(objectsDir)

	if _, err := Run(cfg, RunOptions{
		ManifestPath:      manifestPath,
		SnapshotDir:       snapshotDir,
		SnapshotRetention: 30,
		EncryptionKey:     key,
		Store:             store,
	}); err != nil {
		t.Fatalf("first run backup: %v", err)
	}

	if err := os.Remove(filePath); err != nil {
		t.Fatalf("remove source file: %v", err)
	}

	result, err := Run(cfg, RunOptions{
		ManifestPath:      manifestPath,
		SnapshotDir:       snapshotDir,
		SnapshotRetention: 30,
		EncryptionKey:     key,
		Store:             store,
	})
	if err != nil {
		t.Fatalf("second run backup: %v", err)
	}
	if result.Removed != 1 || result.Uploaded != 0 || result.Total != 0 {
		t.Fatalf("unexpected result: %+v", result)
	}

	keys, err := store.ListKeys()
	if err != nil {
		t.Fatalf("list keys: %v", err)
	}
	if len(keys) != 1 {
		t.Fatalf("expected object to be retained for snapshot restore, got %d keys", len(keys))
	}
}

func TestRunPrunesSnapshotsByRetention(t *testing.T) {
	root := t.TempDir()
	manifestPath := filepath.Join(t.TempDir(), "manifest.json")
	snapshotDir := filepath.Join(t.TempDir(), "manifests")
	objectsDir := filepath.Join(t.TempDir(), "objects")
	key := []byte("01234567890123456789012345678901")

	filePath := filepath.Join(root, "doc.txt")
	if err := os.WriteFile(filePath, []byte("v1"), 0o600); err != nil {
		t.Fatalf("write source file: %v", err)
	}

	cfg := &config.Config{
		BackupRoots: []string{root},
		S3:          config.S3Config{},
		Encryption:  config.EncryptionConfig{},
	}
	store := storage.NewLocalClient(objectsDir)

	for i := 1; i <= 3; i++ {
		payload := []byte("v" + string(rune('0'+i)))
		if err := os.WriteFile(filePath, payload, 0o600); err != nil {
			t.Fatalf("update source file: %v", err)
		}
		if _, err := Run(cfg, RunOptions{
			ManifestPath:      manifestPath,
			SnapshotDir:       snapshotDir,
			SnapshotRetention: 2,
			EncryptionKey:     key,
			Store:             store,
		}); err != nil {
			t.Fatalf("run backup %d: %v", i, err)
		}
	}

	snapshots, err := ListSnapshotManifests(snapshotDir)
	if err != nil {
		t.Fatalf("list snapshots: %v", err)
	}
	if len(snapshots) != 2 {
		t.Fatalf("expected 2 snapshots after retention prune, got %d", len(snapshots))
	}
}

func TestRunRetriesTransientPutFailures(t *testing.T) {
	root := t.TempDir()
	manifestPath := filepath.Join(t.TempDir(), "manifest.json")
	snapshotDir := filepath.Join(t.TempDir(), "manifests")
	objectsDir := filepath.Join(t.TempDir(), "objects")
	key := []byte("01234567890123456789012345678901")

	filePath := filepath.Join(root, "doc.txt")
	if err := os.WriteFile(filePath, []byte("retry-me"), 0o600); err != nil {
		t.Fatalf("write source file: %v", err)
	}

	cfg := &config.Config{
		BackupRoots: []string{root},
		S3:          config.S3Config{},
		Encryption:  config.EncryptionConfig{},
	}

	store := &flakyStore{
		inner:    storage.NewLocalClient(objectsDir),
		failPuts: 2,
	}

	if _, err := Run(cfg, RunOptions{
		ManifestPath:      manifestPath,
		SnapshotDir:       snapshotDir,
		SnapshotRetention: 30,
		EncryptionKey:     key,
		Store:             store,
	}); err != nil {
		t.Fatalf("run backup with retries: %v", err)
	}

	if store.putCallCount != 3 {
		t.Fatalf("unexpected put call count: got %d want 3", store.putCallCount)
	}
}

func TestRunFailsWhenPutRetriesExhausted(t *testing.T) {
	root := t.TempDir()
	manifestPath := filepath.Join(t.TempDir(), "manifest.json")
	snapshotDir := filepath.Join(t.TempDir(), "manifests")
	objectsDir := filepath.Join(t.TempDir(), "objects")
	key := []byte("01234567890123456789012345678901")

	filePath := filepath.Join(root, "doc.txt")
	if err := os.WriteFile(filePath, []byte("retry-me"), 0o600); err != nil {
		t.Fatalf("write source file: %v", err)
	}

	cfg := &config.Config{
		BackupRoots: []string{root},
		S3:          config.S3Config{},
		Encryption:  config.EncryptionConfig{},
	}

	store := &flakyStore{
		inner:    storage.NewLocalClient(objectsDir),
		failPuts: 3,
	}

	_, err := Run(cfg, RunOptions{
		ManifestPath:      manifestPath,
		SnapshotDir:       snapshotDir,
		SnapshotRetention: 30,
		UploadMaxAttempts: 2,
		EncryptionKey:     key,
		Store:             store,
	})
	if err == nil {
		t.Fatal("expected backup run to fail when retries are exhausted")
	}
}

func TestRunStoresVersionedCompressedPayload(t *testing.T) {
	root := t.TempDir()
	manifestPath := filepath.Join(t.TempDir(), "manifest.json")
	snapshotDir := filepath.Join(t.TempDir(), "manifests")
	objectsDir := filepath.Join(t.TempDir(), "objects")
	key := []byte("01234567890123456789012345678901")

	filePath := filepath.Join(root, "compressible.txt")
	content := []byte("baxter-compressible-content-baxter-compressible-content-baxter-compressible-content")
	repeated := make([]byte, 0, len(content)*256)
	for i := 0; i < 256; i++ {
		repeated = append(repeated, content...)
	}
	if err := os.WriteFile(filePath, repeated, 0o600); err != nil {
		t.Fatalf("write source file: %v", err)
	}

	cfg := &config.Config{
		BackupRoots: []string{root},
		S3:          config.S3Config{},
		Encryption:  config.EncryptionConfig{},
	}
	store := storage.NewLocalClient(objectsDir)

	if _, err := Run(cfg, RunOptions{
		ManifestPath:      manifestPath,
		SnapshotDir:       snapshotDir,
		SnapshotRetention: 30,
		EncryptionKey:     key,
		Store:             store,
	}); err != nil {
		t.Fatalf("run backup: %v", err)
	}

	payload, err := store.GetObject(ObjectKeyForPath(filePath))
	if err != nil {
		t.Fatalf("read stored object: %v", err)
	}
	if len(payload) < 2 {
		t.Fatalf("payload too short: %d", len(payload))
	}
	if payload[0] != 3 {
		t.Fatalf("unexpected payload version: got %d want 3", payload[0])
	}
	if payload[1] != 1 {
		t.Fatalf("unexpected compression marker: got %d want 1", payload[1])
	}
}
