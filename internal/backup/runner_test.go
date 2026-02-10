package backup

import (
	"os"
	"path/filepath"
	"testing"

	"baxter/internal/config"
	"baxter/internal/storage"
)

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
