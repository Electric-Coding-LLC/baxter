package backup

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"baxter/internal/config"
	"baxter/internal/crypto"
	"baxter/internal/recovery"
	"baxter/internal/storage"
)

func TestRunWritesEncryptedRemoteSnapshotAndRecoveryMetadata(t *testing.T) {
	root := t.TempDir()
	manifestPath := filepath.Join(t.TempDir(), "manifest.json")
	snapshotDir := filepath.Join(t.TempDir(), "manifests")
	objectsDir := filepath.Join(t.TempDir(), "objects")
	keySet, err := recovery.NewWrappedKeySet("backup-recovery-passphrase", testKDFSalt)
	if err != nil {
		t.Fatalf("create wrapped key set: %v", err)
	}

	filePath := filepath.Join(root, "doc.txt")
	if err := os.WriteFile(filePath, []byte("hello"), 0o600); err != nil {
		t.Fatalf("write source file: %v", err)
	}

	cfg := &config.Config{
		BackupRoots: []string{root},
		S3: config.S3Config{
			Bucket: "example-bucket",
			Prefix: "dogfood/",
		},
	}
	store := storage.NewLocalClient(objectsDir)

	if _, err := Run(cfg, RunOptions{
		ManifestPath:      manifestPath,
		SnapshotDir:       snapshotDir,
		SnapshotRetention: 30,
		EncryptionKey:     keySet.Primary,
		KDFSalt:           testKDFSalt,
		WrappedMasterKey:  keySet.WrappedMasterKey,
		BackupSetID:       recovery.BackupSetID(cfg),
		Store:             store,
	}); err != nil {
		t.Fatalf("run backup: %v", err)
	}

	snapshots, err := ListSnapshotManifests(snapshotDir)
	if err != nil {
		t.Fatalf("list snapshots: %v", err)
	}
	if len(snapshots) != 1 {
		t.Fatalf("unexpected snapshot count: %d", len(snapshots))
	}

	remoteKey, err := RemoteSnapshotManifestObjectKey(snapshots[0].ID)
	if err != nil {
		t.Fatalf("remote snapshot key: %v", err)
	}
	encryptedManifest, err := store.GetObject(remoteKey)
	if err != nil {
		t.Fatalf("read remote snapshot: %v", err)
	}
	if bytes.Contains(encryptedManifest, []byte(filePath)) {
		t.Fatal("remote snapshot manifest should be encrypted")
	}

	plainManifest, err := crypto.DecryptBytes(keySet.Primary, encryptedManifest)
	if err != nil {
		t.Fatalf("decrypt remote snapshot: %v", err)
	}

	var manifest Manifest
	if err := json.Unmarshal(plainManifest, &manifest); err != nil {
		t.Fatalf("decode remote snapshot: %v", err)
	}
	entry, err := FindEntryByPath(&manifest, filePath)
	if err != nil {
		t.Fatalf("find remote snapshot entry: %v", err)
	}
	if entry.Path != filePath {
		t.Fatalf("unexpected remote snapshot entry path: got %q want %q", entry.Path, filePath)
	}

	metadata, err := recovery.ReadMetadata(store)
	if err != nil {
		t.Fatalf("read recovery metadata: %v", err)
	}
	if metadata.BackupSetID != recovery.BackupSetID(cfg) {
		t.Fatalf("unexpected backup set id: got %q want %q", metadata.BackupSetID, recovery.BackupSetID(cfg))
	}
	if metadata.LatestSnapshotID != snapshots[0].ID {
		t.Fatalf("unexpected latest snapshot id: got %q want %q", metadata.LatestSnapshotID, snapshots[0].ID)
	}
	if metadata.WrappedMasterKey == "" {
		t.Fatal("expected wrapped master key in recovery metadata")
	}
}

func TestRunUpdatesRecoveryMetadataLatestSnapshotID(t *testing.T) {
	root := t.TempDir()
	manifestPath := filepath.Join(t.TempDir(), "manifest.json")
	snapshotDir := filepath.Join(t.TempDir(), "manifests")
	objectsDir := filepath.Join(t.TempDir(), "objects")
	key := []byte("01234567890123456789012345678901")

	filePath := filepath.Join(root, "doc.txt")
	if err := os.WriteFile(filePath, []byte("v1"), 0o600); err != nil {
		t.Fatalf("write source file: %v", err)
	}

	cfg := &config.Config{BackupRoots: []string{root}}
	store := storage.NewLocalClient(objectsDir)
	run := func() string {
		t.Helper()
		if _, err := Run(cfg, RunOptions{
			ManifestPath:      manifestPath,
			SnapshotDir:       snapshotDir,
			SnapshotRetention: 30,
			EncryptionKey:     key,
			KDFSalt:           testKDFSalt,
			BackupSetID:       "local-test",
			Store:             store,
		}); err != nil {
			t.Fatalf("run backup: %v", err)
		}
		snapshots, err := ListSnapshotManifests(snapshotDir)
		if err != nil {
			t.Fatalf("list snapshots: %v", err)
		}
		return snapshots[0].ID
	}

	firstSnapshotID := run()
	firstMetadata, err := recovery.ReadMetadata(store)
	if err != nil {
		t.Fatalf("read first recovery metadata: %v", err)
	}

	if err := os.WriteFile(filePath, []byte("v2"), 0o600); err != nil {
		t.Fatalf("update source file: %v", err)
	}
	secondSnapshotID := run()

	metadata, err := recovery.ReadMetadata(store)
	if err != nil {
		t.Fatalf("read updated recovery metadata: %v", err)
	}
	if metadata.LatestSnapshotID != secondSnapshotID {
		t.Fatalf("unexpected latest snapshot id: got %q want %q", metadata.LatestSnapshotID, secondSnapshotID)
	}
	if metadata.CreatedAt != firstMetadata.CreatedAt {
		t.Fatalf("created_at changed: got %s want %s", metadata.CreatedAt, firstMetadata.CreatedAt)
	}
	if !metadata.UpdatedAt.After(firstMetadata.UpdatedAt) {
		t.Fatalf("expected updated_at to advance: before=%s after=%s", firstMetadata.UpdatedAt, metadata.UpdatedAt)
	}
	if metadata.LatestSnapshotID == firstSnapshotID {
		t.Fatalf("expected latest snapshot id to change from %q", firstSnapshotID)
	}
}
