package backup

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"baxter/internal/crypto"
	"baxter/internal/storage"
)

const remoteSnapshotManifestPrefix = "system/manifests/"

func IsSystemObjectKey(key string) bool {
	return strings.HasPrefix(strings.TrimSpace(key), "system/")
}

func FilterDataObjectKeys(keys []string) []string {
	filtered := make([]string, 0, len(keys))
	for _, key := range keys {
		if IsSystemObjectKey(key) {
			continue
		}
		filtered = append(filtered, key)
	}
	return filtered
}

func RemoteSnapshotManifestObjectKey(snapshotID string) (string, error) {
	trimmedSnapshotID := strings.TrimSpace(snapshotID)
	if trimmedSnapshotID == "" {
		return "", errors.New("snapshot id is required")
	}
	return remoteSnapshotManifestPrefix + trimmedSnapshotID + ".json.enc", nil
}

func WriteEncryptedSnapshotManifest(store storage.ObjectStore, snapshotID string, manifest *Manifest, key []byte) error {
	if store == nil {
		return errors.New("object store is required")
	}
	if manifest == nil {
		return errors.New("manifest is required")
	}
	if len(key) == 0 {
		return errors.New("encryption key is required")
	}

	objectKey, err := RemoteSnapshotManifestObjectKey(snapshotID)
	if err != nil {
		return err
	}

	payload, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal manifest: %w", err)
	}

	encrypted, err := crypto.EncryptBytes(key, payload)
	if err != nil {
		return fmt.Errorf("encrypt manifest: %w", err)
	}
	if err := store.PutObject(objectKey, encrypted); err != nil {
		return fmt.Errorf("put remote snapshot manifest: %w", err)
	}
	return nil
}
