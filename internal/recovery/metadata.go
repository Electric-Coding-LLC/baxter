package recovery

import (
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"baxter/internal/crypto"
	"baxter/internal/storage"
)

const (
	metadataObjectKey    = "system/recovery.json"
	currentSchemaVersion = 1
)

var (
	ErrMetadataNotFound = errors.New("recovery metadata not found")
	ErrInvalidMetadata  = errors.New("invalid recovery metadata")
)

type KDFMetadata struct {
	Algorithm  string `json:"algorithm"`
	SaltHex    string `json:"salt_hex"`
	Iterations uint32 `json:"iterations"`
	MemoryKiB  uint32 `json:"memory_kib"`
	Threads    uint8  `json:"threads"`
}

type Metadata struct {
	SchemaVersion    int         `json:"schema_version"`
	BackupSetID      string      `json:"backup_set_id"`
	CreatedAt        time.Time   `json:"created_at"`
	UpdatedAt        time.Time   `json:"updated_at"`
	LatestSnapshotID string      `json:"latest_snapshot_id,omitempty"`
	WrappedMasterKey string      `json:"wrapped_master_key,omitempty"`
	KDF              KDFMetadata `json:"kdf"`
}

func (metadata Metadata) KDFSalt() ([]byte, error) {
	salt, err := hex.DecodeString(strings.TrimSpace(metadata.KDF.SaltHex))
	if err != nil {
		return nil, fmt.Errorf("%w: invalid salt_hex: %v", ErrInvalidMetadata, err)
	}
	if err := crypto.ValidateKDFSalt(salt); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalidMetadata, err)
	}
	return salt, nil
}

func MetadataObjectKey() string {
	return metadataObjectKey
}

func (metadata Metadata) HasWrappedMasterKey() bool {
	return strings.TrimSpace(metadata.WrappedMasterKey) != ""
}

func (metadata Metadata) WrappedMasterKeyBytes() ([]byte, error) {
	if !metadata.HasWrappedMasterKey() {
		return nil, nil
	}
	wrapped, err := hex.DecodeString(strings.TrimSpace(metadata.WrappedMasterKey))
	if err != nil {
		return nil, fmt.Errorf("%w: invalid wrapped_master_key: %v", ErrInvalidMetadata, err)
	}
	if len(wrapped) == 0 {
		return nil, fmt.Errorf("%w: wrapped_master_key is required", ErrInvalidMetadata)
	}
	return wrapped, nil
}

func NewMetadata(backupSetID string, salt []byte, latestSnapshotID string, wrappedMasterKey []byte, now time.Time) (Metadata, error) {
	trimmedBackupSetID := strings.TrimSpace(backupSetID)
	if trimmedBackupSetID == "" {
		return Metadata{}, fmt.Errorf("%w: backup_set_id is required", ErrInvalidMetadata)
	}
	if len(salt) == 0 {
		return Metadata{}, fmt.Errorf("%w: kdf salt is required", ErrInvalidMetadata)
	}
	if now.IsZero() {
		now = time.Now().UTC()
	}

	params := crypto.CurrentKDFParams()
	return Metadata{
		SchemaVersion:    currentSchemaVersion,
		BackupSetID:      trimmedBackupSetID,
		CreatedAt:        now.UTC(),
		UpdatedAt:        now.UTC(),
		LatestSnapshotID: strings.TrimSpace(latestSnapshotID),
		WrappedMasterKey: hex.EncodeToString(wrappedMasterKey),
		KDF: KDFMetadata{
			Algorithm:  params.Algorithm,
			SaltHex:    hex.EncodeToString(salt),
			Iterations: params.Iterations,
			MemoryKiB:  params.MemoryKiB,
			Threads:    params.Threads,
		},
	}, nil
}

func ReadMetadata(store storage.ObjectStore) (Metadata, error) {
	if store == nil {
		return Metadata{}, errors.New("object store is required")
	}

	payload, err := store.GetObject(metadataObjectKey)
	if err != nil {
		if storage.IsNotFound(err) {
			return Metadata{}, ErrMetadataNotFound
		}
		return Metadata{}, fmt.Errorf("get recovery metadata: %w", err)
	}

	var metadata Metadata
	if err := json.Unmarshal(payload, &metadata); err != nil {
		return Metadata{}, fmt.Errorf("%w: decode recovery metadata: %v", ErrInvalidMetadata, err)
	}
	if err := ValidateMetadata(metadata); err != nil {
		return Metadata{}, err
	}
	return metadata, nil
}

func WriteMetadata(store storage.ObjectStore, metadata Metadata) error {
	if store == nil {
		return errors.New("object store is required")
	}
	if err := ValidateMetadata(metadata); err != nil {
		return err
	}

	payload, err := json.MarshalIndent(metadata, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal recovery metadata: %w", err)
	}
	if err := store.PutObject(metadataObjectKey, payload); err != nil {
		return fmt.Errorf("put recovery metadata: %w", err)
	}
	return nil
}

func ValidateMetadata(metadata Metadata) error {
	if metadata.SchemaVersion != currentSchemaVersion {
		return fmt.Errorf("%w: unsupported schema version %d", ErrInvalidMetadata, metadata.SchemaVersion)
	}
	if strings.TrimSpace(metadata.BackupSetID) == "" {
		return fmt.Errorf("%w: backup_set_id is required", ErrInvalidMetadata)
	}
	if metadata.CreatedAt.IsZero() {
		return fmt.Errorf("%w: created_at is required", ErrInvalidMetadata)
	}
	if metadata.UpdatedAt.IsZero() {
		return fmt.Errorf("%w: updated_at is required", ErrInvalidMetadata)
	}
	if metadata.KDF.Algorithm != crypto.CurrentKDFParams().Algorithm {
		return fmt.Errorf("%w: unsupported kdf algorithm %q", ErrInvalidMetadata, metadata.KDF.Algorithm)
	}
	if _, err := metadata.KDFSalt(); err != nil {
		return err
	}
	if _, err := metadata.WrappedMasterKeyBytes(); err != nil {
		return err
	}
	if metadata.KDF.Iterations == 0 {
		return fmt.Errorf("%w: kdf iterations must be > 0", ErrInvalidMetadata)
	}
	if metadata.KDF.MemoryKiB == 0 {
		return fmt.Errorf("%w: kdf memory_kib must be > 0", ErrInvalidMetadata)
	}
	if metadata.KDF.Threads == 0 {
		return fmt.Errorf("%w: kdf threads must be > 0", ErrInvalidMetadata)
	}
	return nil
}
