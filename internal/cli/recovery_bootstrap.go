package cli

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"

	"baxter/internal/backup"
	"baxter/internal/config"
	"baxter/internal/crypto"
	"baxter/internal/recovery"
	"baxter/internal/state"
	"baxter/internal/storage"
)

type recoveryBootstrapResult struct {
	SnapshotID string
	Entries    int
}

func runRecoveryBootstrap(cfg *config.Config) error {
	store, err := objectStoreFromConfig(cfg)
	if err != nil {
		return err
	}

	result, err := bootstrapRecoveryCache(cfg, store)
	if err != nil {
		return err
	}

	fmt.Printf(
		"recovery bootstrap complete: snapshot=%s entries=%d\n",
		result.SnapshotID,
		result.Entries,
	)
	return nil
}

func bootstrapRecoveryCache(cfg *config.Config, store storage.ObjectStore) (recoveryBootstrapResult, error) {
	if store == nil {
		return recoveryBootstrapResult{}, fmt.Errorf("object store is required")
	}

	passphrase, err := encryptionPassphrase(cfg)
	if err != nil {
		return recoveryBootstrapResult{}, err
	}

	metadata, err := recovery.ReadMetadata(store)
	if err != nil {
		return recoveryBootstrapResult{}, fmt.Errorf("read recovery metadata: %w", err)
	}

	expectedBackupSetID := recovery.BackupSetID(cfg)
	if strings.TrimSpace(metadata.BackupSetID) != expectedBackupSetID {
		return recoveryBootstrapResult{}, fmt.Errorf(
			"recovery metadata backup set mismatch: got %q want %q",
			metadata.BackupSetID,
			expectedBackupSetID,
		)
	}

	salt, err := metadata.KDFSalt()
	if err != nil {
		return recoveryBootstrapResult{}, err
	}
	keys, err := deriveEncryptionKeysWithSalt(passphrase, salt)
	if err != nil {
		return recoveryBootstrapResult{}, err
	}

	snapshotID := strings.TrimSpace(metadata.LatestSnapshotID)
	if snapshotID == "" {
		return recoveryBootstrapResult{}, fmt.Errorf("recovery metadata latest snapshot id is required")
	}

	manifest, err := readRemoteSnapshotManifest(store, snapshotID, keys.primary)
	if err != nil {
		return recoveryBootstrapResult{}, err
	}
	if err := writeRecoveryCache(manifest, snapshotID, salt); err != nil {
		return recoveryBootstrapResult{}, err
	}

	return recoveryBootstrapResult{
		SnapshotID: snapshotID,
		Entries:    len(manifest.Entries),
	}, nil
}

func readRemoteSnapshotManifest(store storage.ObjectStore, snapshotID string, key []byte) (*backup.Manifest, error) {
	objectKey, err := backup.RemoteSnapshotManifestObjectKey(snapshotID)
	if err != nil {
		return nil, err
	}

	payload, err := store.GetObject(objectKey)
	if err != nil {
		return nil, fmt.Errorf("get remote snapshot manifest: %w", err)
	}

	plain, err := crypto.DecryptBytes(key, payload)
	if err != nil {
		return nil, fmt.Errorf("decrypt remote snapshot manifest: %w", err)
	}

	var manifest backup.Manifest
	if err := json.Unmarshal(plain, &manifest); err != nil {
		return nil, fmt.Errorf("decode remote snapshot manifest: %w", err)
	}
	if manifest.Entries == nil {
		manifest.Entries = []backup.ManifestEntry{}
	}
	return &manifest, nil
}

func writeRecoveryCache(manifest *backup.Manifest, snapshotID string, salt []byte) error {
	if manifest == nil {
		return fmt.Errorf("manifest is required")
	}
	if err := persistKDFSalt(salt); err != nil {
		return err
	}

	manifestPath, err := state.ManifestPath()
	if err != nil {
		return err
	}
	if err := backup.SaveManifest(manifestPath, manifest); err != nil {
		return fmt.Errorf("write local manifest cache: %w", err)
	}

	snapshotDir, err := state.ManifestSnapshotsDir()
	if err != nil {
		return err
	}
	snapshotPath := filepath.Join(snapshotDir, snapshotID+".json")
	if err := backup.SaveManifest(snapshotPath, manifest); err != nil {
		return fmt.Errorf("write local snapshot cache: %w", err)
	}

	return nil
}
