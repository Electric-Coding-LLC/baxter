package recoverycache

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"baxter/internal/backup"
	"baxter/internal/config"
	"baxter/internal/crypto"
	"baxter/internal/recovery"
	"baxter/internal/state"
	"baxter/internal/storage"
)

type PassphraseResolver func() (string, error)

type HydrateResult struct {
	Manifest   *backup.Manifest
	SnapshotID string
}

func HydrateLatest(cfg *config.Config, store storage.ObjectStore, resolvePassphrase PassphraseResolver) (HydrateResult, error) {
	metadata, err := readVerifiedMetadata(cfg, store)
	if err != nil {
		return HydrateResult{}, err
	}
	return hydrateRemoteCacheWithFullHistory(store, metadata, resolvePassphrase)
}

func LoadManifest(cfg *config.Config, store storage.ObjectStore, selector string, resolvePassphrase PassphraseResolver) (*backup.Manifest, error) {
	manifestPath, snapshotDir, err := cachePaths()
	if err != nil {
		return nil, err
	}
	latestManifestPresent := fileExists(manifestPath)

	localManifest, localErr := backup.LoadManifestForRestore(manifestPath, snapshotDir, selector)
	if localErr == nil && !isLatestSelector(selector) {
		return localManifest, nil
	}

	if localErr == nil {
		remoteManifest, err := refreshLatestIfStale(cfg, store, snapshotDir, latestManifestPresent, resolvePassphrase)
		if err == nil && remoteManifest != nil {
			return remoteManifest, nil
		}
		if !latestManifestPresent {
			return nil, err
		}
		return localManifest, nil
	}

	result, err := hydrateSelector(cfg, store, selector, resolvePassphrase)
	if err == nil {
		return result.Manifest, nil
	}
	return nil, err
}

func hydrateSelector(cfg *config.Config, store storage.ObjectStore, selector string, resolvePassphrase PassphraseResolver) (HydrateResult, error) {
	metadata, err := readVerifiedMetadata(cfg, store)
	if err != nil {
		return HydrateResult{}, err
	}

	trimmed := strings.TrimSpace(selector)
	if isLatestSelector(trimmed) {
		return hydrateRemoteCacheWithMetadata(store, metadata, nil, resolvePassphrase)
	}

	if _, err := time.Parse(time.RFC3339, trimmed); err == nil {
		return hydrateRemoteCacheForAsOf(store, metadata, trimmed, resolvePassphrase)
	}

	manifests, salt, err := remoteSnapshotManifestSet(store, metadata, resolvePassphrase, []string{trimmed})
	if err != nil {
		return HydrateResult{}, err
	}
	if err := writeRecoveryCache(manifests, metadata.LatestSnapshotID, salt); err != nil {
		return HydrateResult{}, err
	}

	selected, ok := manifests[trimmed]
	if !ok || selected == nil {
		return HydrateResult{}, fmt.Errorf("remote snapshot manifest %q not found", trimmed)
	}
	return HydrateResult{
		Manifest:   selected,
		SnapshotID: strings.TrimSpace(metadata.LatestSnapshotID),
	}, nil
}

func refreshLatestIfStale(cfg *config.Config, store storage.ObjectStore, snapshotDir string, latestManifestPresent bool, resolvePassphrase PassphraseResolver) (*backup.Manifest, error) {
	metadata, err := readVerifiedMetadata(cfg, store)
	if err != nil {
		return nil, err
	}
	latestSnapshotID := strings.TrimSpace(metadata.LatestSnapshotID)
	if latestSnapshotID == "" {
		return nil, fmt.Errorf("recovery metadata latest snapshot id is required")
	}

	localLatestSnapshotID, err := latestLocalSnapshotID(snapshotDir)
	if latestManifestPresent && err == nil && localLatestSnapshotID == latestSnapshotID {
		return nil, nil
	}

	result, err := hydrateRemoteCacheWithMetadata(store, metadata, nil, resolvePassphrase)
	if err != nil {
		return nil, err
	}
	return result.Manifest, nil
}

func hydrateRemoteCacheWithMetadata(
	store storage.ObjectStore,
	metadata recovery.Metadata,
	requestedSnapshotIDs []string,
	resolvePassphrase PassphraseResolver,
) (HydrateResult, error) {
	manifests, salt, err := remoteSnapshotManifestSet(store, metadata, resolvePassphrase, requestedSnapshotIDs)
	if err != nil {
		return HydrateResult{}, err
	}

	snapshotID := strings.TrimSpace(metadata.LatestSnapshotID)
	if snapshotID == "" {
		return HydrateResult{}, fmt.Errorf("recovery metadata latest snapshot id is required")
	}

	manifest, ok := manifests[snapshotID]
	if !ok || manifest == nil {
		return HydrateResult{}, fmt.Errorf("remote latest snapshot manifest %q not found", snapshotID)
	}
	if err := writeRecoveryCache(manifests, snapshotID, salt); err != nil {
		return HydrateResult{}, err
	}

	return HydrateResult{
		Manifest:   manifest,
		SnapshotID: snapshotID,
	}, nil
}

func hydrateRemoteCacheForAsOf(
	store storage.ObjectStore,
	metadata recovery.Metadata,
	selector string,
	resolvePassphrase PassphraseResolver,
) (HydrateResult, error) {
	manifests, salt, err := remoteSnapshotManifestHistory(store, metadata, resolvePassphrase)
	if err != nil {
		return HydrateResult{}, err
	}
	if err := writeRecoveryCache(manifests, metadata.LatestSnapshotID, salt); err != nil {
		return HydrateResult{}, err
	}

	manifestPath, snapshotDir, err := cachePaths()
	if err != nil {
		return HydrateResult{}, err
	}
	selected, err := backup.LoadManifestForRestore(manifestPath, snapshotDir, selector)
	if err != nil {
		return HydrateResult{}, err
	}
	return HydrateResult{
		Manifest:   selected,
		SnapshotID: strings.TrimSpace(metadata.LatestSnapshotID),
	}, nil
}

func hydrateRemoteCacheWithFullHistory(
	store storage.ObjectStore,
	metadata recovery.Metadata,
	resolvePassphrase PassphraseResolver,
) (HydrateResult, error) {
	manifests, salt, err := remoteSnapshotManifestHistory(store, metadata, resolvePassphrase)
	if err != nil {
		return HydrateResult{}, err
	}

	snapshotID := strings.TrimSpace(metadata.LatestSnapshotID)
	manifest, ok := manifests[snapshotID]
	if !ok || manifest == nil {
		return HydrateResult{}, fmt.Errorf("remote latest snapshot manifest %q not found", snapshotID)
	}
	if err := writeRecoveryCache(manifests, snapshotID, salt); err != nil {
		return HydrateResult{}, err
	}
	return HydrateResult{
		Manifest:   manifest,
		SnapshotID: snapshotID,
	}, nil
}

func readVerifiedMetadata(cfg *config.Config, store storage.ObjectStore) (recovery.Metadata, error) {
	if cfg == nil {
		return recovery.Metadata{}, fmt.Errorf("config is required")
	}
	if store == nil {
		return recovery.Metadata{}, fmt.Errorf("object store is required")
	}

	metadata, err := recovery.ReadMetadata(store)
	if err != nil {
		return recovery.Metadata{}, fmt.Errorf("read recovery metadata: %w", err)
	}

	expectedBackupSetID := recovery.BackupSetID(cfg)
	if strings.TrimSpace(metadata.BackupSetID) != expectedBackupSetID {
		return recovery.Metadata{}, fmt.Errorf(
			"recovery metadata backup set mismatch: got %q want %q",
			metadata.BackupSetID,
			expectedBackupSetID,
		)
	}
	return metadata, nil
}

func remoteManifestKey(resolvePassphrase PassphraseResolver, metadata recovery.Metadata) ([]byte, error) {
	if resolvePassphrase == nil {
		return nil, fmt.Errorf("passphrase resolver is required")
	}
	passphrase, err := resolvePassphrase()
	if err != nil {
		return nil, err
	}
	keySet, err := recovery.KeySetFromMetadata(metadata, passphrase)
	if err != nil {
		return nil, err
	}
	return keySet.Primary, nil
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

func remoteSnapshotManifestSet(
	store storage.ObjectStore,
	metadata recovery.Metadata,
	resolvePassphrase PassphraseResolver,
	requestedSnapshotIDs []string,
) (map[string]*backup.Manifest, []byte, error) {
	latestSnapshotID := strings.TrimSpace(metadata.LatestSnapshotID)
	if latestSnapshotID == "" {
		return nil, nil, fmt.Errorf("recovery metadata latest snapshot id is required")
	}

	salt, err := metadata.KDFSalt()
	if err != nil {
		return nil, nil, err
	}
	key, err := remoteManifestKey(resolvePassphrase, metadata)
	if err != nil {
		return nil, nil, err
	}

	snapshotIDs := normalizeRequestedSnapshotIDs(latestSnapshotID, requestedSnapshotIDs)
	manifests := make(map[string]*backup.Manifest, len(snapshotIDs))
	for _, id := range snapshotIDs {
		manifest, err := readRemoteSnapshotManifest(store, id, key)
		if err != nil {
			return nil, nil, err
		}
		manifests[id] = manifest
	}
	return manifests, salt, nil
}

func remoteSnapshotManifestHistory(
	store storage.ObjectStore,
	metadata recovery.Metadata,
	resolvePassphrase PassphraseResolver,
) (map[string]*backup.Manifest, []byte, error) {
	snapshotIDs, err := listRemoteSnapshotIDs(store, strings.TrimSpace(metadata.LatestSnapshotID))
	if err != nil {
		return nil, nil, err
	}
	return remoteSnapshotManifestSet(store, metadata, resolvePassphrase, snapshotIDs)
}

func listRemoteSnapshotIDs(store storage.ObjectStore, latestSnapshotID string) ([]string, error) {
	if store == nil {
		return nil, fmt.Errorf("object store is required")
	}

	keys, err := listStoreKeysWithPrefix(store, backup.RemoteSnapshotManifestKeyPrefix())
	if err != nil {
		return nil, fmt.Errorf("list remote snapshot manifests: %w", err)
	}

	ids := make(map[string]struct{})
	for _, key := range keys {
		snapshotID, ok := backup.RemoteSnapshotManifestIDFromObjectKey(key)
		if !ok {
			continue
		}
		ids[snapshotID] = struct{}{}
	}
	if trimmedLatest := strings.TrimSpace(latestSnapshotID); trimmedLatest != "" {
		ids[trimmedLatest] = struct{}{}
	}
	if len(ids) == 0 {
		return nil, fmt.Errorf("remote snapshot manifests not found")
	}

	out := make([]string, 0, len(ids))
	for snapshotID := range ids {
		out = append(out, snapshotID)
	}
	sort.Strings(out)
	return out, nil
}

func normalizeRequestedSnapshotIDs(latestSnapshotID string, requestedSnapshotIDs []string) []string {
	ids := make(map[string]struct{}, len(requestedSnapshotIDs)+1)
	if latestSnapshotID != "" {
		ids[latestSnapshotID] = struct{}{}
	}
	for _, snapshotID := range requestedSnapshotIDs {
		trimmed := strings.TrimSpace(snapshotID)
		if trimmed == "" {
			continue
		}
		ids[trimmed] = struct{}{}
	}

	out := make([]string, 0, len(ids))
	for snapshotID := range ids {
		out = append(out, snapshotID)
	}
	sort.Strings(out)
	return out
}

func listStoreKeysWithPrefix(store storage.ObjectStore, prefix string) ([]string, error) {
	if lister, ok := store.(storage.PrefixKeyLister); ok {
		return lister.ListKeysWithPrefix(prefix)
	}
	keys, err := store.ListKeys()
	if err != nil {
		return nil, err
	}

	normalizedPrefix := strings.TrimSpace(strings.ReplaceAll(prefix, "\\", "/"))
	if normalizedPrefix == "" {
		return keys, nil
	}

	filtered := make([]string, 0, len(keys))
	for _, key := range keys {
		if strings.HasPrefix(key, normalizedPrefix) {
			filtered = append(filtered, key)
		}
	}
	return filtered, nil
}

func writeRecoveryCache(manifests map[string]*backup.Manifest, latestSnapshotID string, salt []byte) error {
	if len(manifests) == 0 {
		return fmt.Errorf("snapshot manifests are required")
	}
	if err := persistKDFSalt(salt); err != nil {
		return err
	}

	manifestPath, snapshotDir, err := cachePaths()
	if err != nil {
		return err
	}

	latestSnapshotID = strings.TrimSpace(latestSnapshotID)
	latestManifest, ok := manifests[latestSnapshotID]
	if !ok || latestManifest == nil {
		return fmt.Errorf("latest snapshot manifest %q is required", latestSnapshotID)
	}

	manifestTmpPath := manifestPath + ".tmp"
	if err := backup.SaveManifest(manifestTmpPath, latestManifest); err != nil {
		return fmt.Errorf("write local manifest cache: %w", err)
	}

	snapshotTmpDir := snapshotDir + ".tmp"
	if err := os.RemoveAll(snapshotTmpDir); err != nil {
		return fmt.Errorf("reset local snapshot cache temp dir: %w", err)
	}

	snapshotIDs := make([]string, 0, len(manifests))
	for snapshotID := range manifests {
		snapshotIDs = append(snapshotIDs, snapshotID)
	}
	sort.Strings(snapshotIDs)
	for _, snapshotID := range snapshotIDs {
		snapshotPath := filepath.Join(snapshotTmpDir, snapshotID+".json")
		if err := backup.SaveManifest(snapshotPath, manifests[snapshotID]); err != nil {
			return fmt.Errorf("write local snapshot cache: %w", err)
		}
	}

	if err := os.RemoveAll(snapshotDir); err != nil {
		return fmt.Errorf("reset local snapshot cache: %w", err)
	}
	if err := os.Rename(snapshotTmpDir, snapshotDir); err != nil {
		return fmt.Errorf("replace local snapshot cache: %w", err)
	}
	if err := os.Rename(manifestTmpPath, manifestPath); err != nil {
		return fmt.Errorf("replace local manifest cache: %w", err)
	}
	return nil
}

func persistKDFSalt(salt []byte) error {
	if err := crypto.ValidateKDFSalt(salt); err != nil {
		return fmt.Errorf("invalid KDF salt: %w", err)
	}

	saltPath, err := state.KDFSaltPath()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(saltPath), 0o755); err != nil {
		return fmt.Errorf("create state dir: %w", err)
	}
	tmpPath := saltPath + ".tmp"
	if err := os.WriteFile(tmpPath, salt, 0o600); err != nil {
		return fmt.Errorf("write KDF salt: %w", err)
	}
	if err := os.Rename(tmpPath, saltPath); err != nil {
		return fmt.Errorf("persist KDF salt: %w", err)
	}
	return nil
}

func cachePaths() (string, string, error) {
	manifestPath, err := state.ManifestPath()
	if err != nil {
		return "", "", err
	}
	snapshotDir, err := state.ManifestSnapshotsDir()
	if err != nil {
		return "", "", err
	}
	return manifestPath, snapshotDir, nil
}

func latestLocalSnapshotID(snapshotDir string) (string, error) {
	snapshots, err := backup.ListSnapshotManifests(snapshotDir)
	if err != nil {
		return "", err
	}
	if len(snapshots) == 0 {
		return "", backup.ErrSnapshotNotFound
	}
	return snapshots[0].ID, nil
}

func isLatestSelector(selector string) bool {
	trimmed := strings.TrimSpace(selector)
	return trimmed == "" || strings.EqualFold(trimmed, "latest")
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
