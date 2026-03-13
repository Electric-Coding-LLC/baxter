package recoverycache

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"baxter/internal/backup"
	"baxter/internal/config"
	"baxter/internal/crypto"
	"baxter/internal/recovery"
	"baxter/internal/state"
	"baxter/internal/storage"
)

var errRemoteSelectorUnavailable = errors.New("remote selector unavailable")

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
	return hydrateLatestWithMetadata(store, metadata, resolvePassphrase)
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
	if errors.Is(err, errRemoteSelectorUnavailable) {
		return nil, localErr
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
		return hydrateLatestWithMetadata(store, metadata, resolvePassphrase)
	}
	if _, parseErr := time.Parse(time.RFC3339, trimmed); parseErr != nil && trimmed != strings.TrimSpace(metadata.LatestSnapshotID) {
		return HydrateResult{}, errRemoteSelectorUnavailable
	}

	result, err := hydrateLatestWithMetadata(store, metadata, resolvePassphrase)
	if err != nil {
		return HydrateResult{}, err
	}
	if trimmed == result.SnapshotID {
		return result, nil
	}

	asOf, err := time.Parse(time.RFC3339, trimmed)
	if err != nil {
		return HydrateResult{}, errRemoteSelectorUnavailable
	}
	if result.Manifest.CreatedAt.After(asOf.UTC()) {
		return HydrateResult{}, errRemoteSelectorUnavailable
	}
	return result, nil
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

	result, err := hydrateLatestWithMetadata(store, metadata, resolvePassphrase)
	if err != nil {
		return nil, err
	}
	return result.Manifest, nil
}

func hydrateLatestWithMetadata(store storage.ObjectStore, metadata recovery.Metadata, resolvePassphrase PassphraseResolver) (HydrateResult, error) {
	snapshotID := strings.TrimSpace(metadata.LatestSnapshotID)
	if snapshotID == "" {
		return HydrateResult{}, fmt.Errorf("recovery metadata latest snapshot id is required")
	}

	salt, err := metadata.KDFSalt()
	if err != nil {
		return HydrateResult{}, err
	}
	key, err := remoteManifestKey(resolvePassphrase, salt)
	if err != nil {
		return HydrateResult{}, err
	}

	manifest, err := readRemoteSnapshotManifest(store, snapshotID, key)
	if err != nil {
		return HydrateResult{}, err
	}
	if err := writeRecoveryCache(manifest, snapshotID, salt); err != nil {
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

func remoteManifestKey(resolvePassphrase PassphraseResolver, salt []byte) ([]byte, error) {
	if resolvePassphrase == nil {
		return nil, fmt.Errorf("passphrase resolver is required")
	}
	passphrase, err := resolvePassphrase()
	if err != nil {
		return nil, err
	}
	return crypto.KeyFromPassphraseWithSalt(passphrase, salt), nil
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

	manifestPath, snapshotDir, err := cachePaths()
	if err != nil {
		return err
	}
	if err := backup.SaveManifest(manifestPath, manifest); err != nil {
		return fmt.Errorf("write local manifest cache: %w", err)
	}

	snapshotPath := filepath.Join(snapshotDir, snapshotID+".json")
	if err := backup.SaveManifest(snapshotPath, manifest); err != nil {
		return fmt.Errorf("write local snapshot cache: %w", err)
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
