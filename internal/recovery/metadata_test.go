package recovery

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"baxter/internal/crypto"
	"baxter/internal/storage"
)

func TestWriteReadMetadataRoundTrip(t *testing.T) {
	store := storage.NewLocalClient(t.TempDir())
	salt, err := crypto.NewKDFSalt()
	if err != nil {
		t.Fatalf("generate salt: %v", err)
	}

	now := time.Date(2026, time.March, 12, 17, 0, 0, 0, time.UTC)
	metadata, err := NewMetadata("primary-backup", salt, "20260312T170000.000000000Z", now)
	if err != nil {
		t.Fatalf("new metadata: %v", err)
	}

	if err := WriteMetadata(store, metadata); err != nil {
		t.Fatalf("write metadata: %v", err)
	}

	got, err := ReadMetadata(store)
	if err != nil {
		t.Fatalf("read metadata: %v", err)
	}
	if got.SchemaVersion != metadata.SchemaVersion {
		t.Fatalf("schema version mismatch: got %d want %d", got.SchemaVersion, metadata.SchemaVersion)
	}
	if got.BackupSetID != metadata.BackupSetID {
		t.Fatalf("backup_set_id mismatch: got %q want %q", got.BackupSetID, metadata.BackupSetID)
	}
	if got.LatestSnapshotID != metadata.LatestSnapshotID {
		t.Fatalf("latest_snapshot_id mismatch: got %q want %q", got.LatestSnapshotID, metadata.LatestSnapshotID)
	}
	if got.KDF != metadata.KDF {
		t.Fatalf("kdf mismatch: got %#v want %#v", got.KDF, metadata.KDF)
	}
}

func TestReadMetadataNotFound(t *testing.T) {
	store := storage.NewLocalClient(t.TempDir())

	_, err := ReadMetadata(store)
	if !errors.Is(err, ErrMetadataNotFound) {
		t.Fatalf("expected ErrMetadataNotFound, got %v", err)
	}
}

func TestReadMetadataRejectsInvalidJSON(t *testing.T) {
	store := storage.NewLocalClient(t.TempDir())
	if err := store.PutObject(MetadataObjectKey(), []byte("{not-json")); err != nil {
		t.Fatalf("seed invalid metadata: %v", err)
	}

	_, err := ReadMetadata(store)
	if !errors.Is(err, ErrInvalidMetadata) {
		t.Fatalf("expected ErrInvalidMetadata, got %v", err)
	}
}

func TestWriteMetadataRejectsInvalidMetadata(t *testing.T) {
	store := storage.NewLocalClient(t.TempDir())
	err := WriteMetadata(store, Metadata{})
	if !errors.Is(err, ErrInvalidMetadata) {
		t.Fatalf("expected ErrInvalidMetadata, got %v", err)
	}
}

func TestMetadataObjectKeyIsStable(t *testing.T) {
	if got, want := MetadataObjectKey(), "system/recovery.json"; got != want {
		t.Fatalf("metadata key mismatch: got %q want %q", got, want)
	}
}

func TestNewMetadataUsesCurrentKDFSettings(t *testing.T) {
	salt, err := crypto.NewKDFSalt()
	if err != nil {
		t.Fatalf("generate salt: %v", err)
	}

	now := time.Date(2026, time.March, 12, 18, 30, 0, 0, time.UTC)
	metadata, err := NewMetadata("dogfood", salt, "", now)
	if err != nil {
		t.Fatalf("new metadata: %v", err)
	}

	params := crypto.CurrentKDFParams()
	if metadata.KDF.Algorithm != params.Algorithm {
		t.Fatalf("algorithm mismatch: got %q want %q", metadata.KDF.Algorithm, params.Algorithm)
	}
	if metadata.KDF.Iterations != params.Iterations {
		t.Fatalf("iterations mismatch: got %d want %d", metadata.KDF.Iterations, params.Iterations)
	}
	if metadata.KDF.MemoryKiB != params.MemoryKiB {
		t.Fatalf("memory mismatch: got %d want %d", metadata.KDF.MemoryKiB, params.MemoryKiB)
	}
	if metadata.KDF.Threads != params.Threads {
		t.Fatalf("threads mismatch: got %d want %d", metadata.KDF.Threads, params.Threads)
	}
}

func TestValidateMetadataRejectsBadSalt(t *testing.T) {
	metadata := Metadata{
		SchemaVersion: 1,
		BackupSetID:   "primary",
		CreatedAt:     time.Date(2026, time.March, 12, 18, 30, 0, 0, time.UTC),
		UpdatedAt:     time.Date(2026, time.March, 12, 18, 30, 0, 0, time.UTC),
		KDF: KDFMetadata{
			Algorithm:  "argon2id",
			SaltHex:    "1234",
			Iterations: 3,
			MemoryKiB:  64 * 1024,
			Threads:    4,
		},
	}

	err := ValidateMetadata(metadata)
	if !errors.Is(err, ErrInvalidMetadata) {
		t.Fatalf("expected ErrInvalidMetadata, got %v", err)
	}
	if !strings.Contains(err.Error(), "invalid KDF salt length") {
		t.Fatalf("expected invalid salt length error, got %v", err)
	}
}

func TestReadMetadataRejectsUnknownSchemaVersion(t *testing.T) {
	store := storage.NewLocalClient(t.TempDir())
	payload, err := json.Marshal(Metadata{
		SchemaVersion: 99,
		BackupSetID:   "primary",
		CreatedAt:     time.Date(2026, time.March, 12, 18, 30, 0, 0, time.UTC),
		UpdatedAt:     time.Date(2026, time.March, 12, 18, 30, 0, 0, time.UTC),
		KDF: KDFMetadata{
			Algorithm:  "argon2id",
			SaltHex:    "00112233445566778899aabbccddeeff",
			Iterations: 3,
			MemoryKiB:  64 * 1024,
			Threads:    4,
		},
	})
	if err != nil {
		t.Fatalf("marshal metadata: %v", err)
	}
	if err := store.PutObject(MetadataObjectKey(), payload); err != nil {
		t.Fatalf("seed metadata: %v", err)
	}

	_, err = ReadMetadata(store)
	if !errors.Is(err, ErrInvalidMetadata) {
		t.Fatalf("expected ErrInvalidMetadata, got %v", err)
	}
}
