package cli

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"baxter/internal/backup"
	"baxter/internal/config"
	"baxter/internal/crypto"
	"baxter/internal/state"
	"baxter/internal/storage"
)

func filterManifestEntriesByPrefix(entries []backup.ManifestEntry, prefix string) []backup.ManifestEntry {
	cleanPrefix := filepath.Clean(strings.TrimSpace(prefix))
	if cleanPrefix == "." {
		cleanPrefix = ""
	}
	if cleanPrefix == "" {
		return append([]backup.ManifestEntry(nil), entries...)
	}

	filtered := make([]backup.ManifestEntry, 0, len(entries))
	for _, entry := range entries {
		if strings.HasPrefix(filepath.Clean(entry.Path), cleanPrefix) {
			filtered = append(filtered, entry)
		}
	}
	return filtered
}

func sampleManifestEntries(entries []backup.ManifestEntry, sample int) []backup.ManifestEntry {
	if sample <= 0 || sample >= len(entries) {
		return entries
	}
	if sample == 1 {
		return []backup.ManifestEntry{entries[0]}
	}

	out := make([]backup.ManifestEntry, 0, sample)
	last := -1
	step := float64(len(entries)-1) / float64(sample-1)
	for i := 0; i < sample; i++ {
		idx := int(float64(i) * step)
		if idx <= last {
			idx = last + 1
		}
		if idx >= len(entries) {
			idx = len(entries) - 1
		}
		out = append(out, entries[idx])
		last = idx
	}
	return out
}

func filterRestorePaths(entries []backup.ManifestEntry, opts restoreListOptions) []string {
	prefix := filepath.Clean(strings.TrimSpace(opts.Prefix))
	if prefix == "." {
		prefix = ""
	}
	contains := strings.TrimSpace(opts.Contains)

	paths := make([]string, 0, len(entries))
	for _, entry := range entries {
		path := entry.Path
		if prefix != "" && !strings.HasPrefix(filepath.Clean(path), prefix) {
			continue
		}
		if contains != "" && !strings.Contains(path, contains) {
			continue
		}
		paths = append(paths, path)
	}
	return paths
}

func resolvedRestorePath(sourcePath string, toDir string) (string, error) {
	if strings.TrimSpace(toDir) == "" {
		return sourcePath, nil
	}

	cleanToDir := filepath.Clean(toDir)
	cleanSource := filepath.Clean(sourcePath)
	if cleanSource == "." || cleanSource == "" {
		return "", errors.New("invalid restore source path")
	}

	relSource := cleanSource
	if filepath.IsAbs(cleanSource) {
		relSource = strings.TrimPrefix(cleanSource, string(filepath.Separator))
	}
	if relSource == "" || relSource == "." {
		return "", errors.New("invalid restore source path")
	}
	if relSource == ".." || strings.HasPrefix(relSource, ".."+string(filepath.Separator)) {
		return "", errors.New("restore path escapes destination root")
	}

	targetPath := filepath.Join(cleanToDir, relSource)
	targetPath = filepath.Clean(targetPath)

	relToRoot, err := filepath.Rel(cleanToDir, targetPath)
	if err != nil {
		return "", err
	}
	if relToRoot == ".." || strings.HasPrefix(relToRoot, ".."+string(filepath.Separator)) {
		return "", errors.New("restore path escapes destination root")
	}

	return targetPath, nil
}

func encryptionKey(cfg *config.Config) ([]byte, error) {
	keys, err := encryptionKeys(cfg)
	if err != nil {
		return nil, err
	}
	return keys.primary, nil
}

type encryptionKeySet struct {
	primary    []byte
	candidates [][]byte
}

func encryptionKeys(cfg *config.Config) (encryptionKeySet, error) {
	passphrase := os.Getenv(passphraseEnv)
	if passphrase != "" {
		return deriveEncryptionKeys(passphrase)
	}

	passphrase, err := crypto.PassphraseFromKeychain(cfg.Encryption.KeychainService, cfg.Encryption.KeychainAccount)
	if err != nil {
		return encryptionKeySet{}, fmt.Errorf("no %s set and keychain lookup failed: %w", passphraseEnv, err)
	}
	return deriveEncryptionKeys(passphrase)
}

func deriveEncryptionKeys(passphrase string) (encryptionKeySet, error) {
	salt, err := readOrCreateKDFSalt()
	if err != nil {
		return encryptionKeySet{}, err
	}

	primary := crypto.KeyFromPassphraseWithSalt(passphrase, salt)
	legacy := crypto.KeyFromPassphrase(passphrase)
	candidates := [][]byte{primary}
	if !bytes.Equal(primary, legacy) {
		candidates = append(candidates, legacy)
	}

	return encryptionKeySet{
		primary:    primary,
		candidates: candidates,
	}, nil
}

func readOrCreateKDFSalt() ([]byte, error) {
	saltPath, err := state.KDFSaltPath()
	if err != nil {
		return nil, err
	}

	if salt, err := os.ReadFile(saltPath); err == nil {
		if err := crypto.ValidateKDFSalt(salt); err != nil {
			return nil, fmt.Errorf("invalid KDF salt at %s: %w", saltPath, err)
		}
		return salt, nil
	} else if !os.IsNotExist(err) {
		return nil, fmt.Errorf("read KDF salt: %w", err)
	}

	salt, err := crypto.NewKDFSalt()
	if err != nil {
		return nil, fmt.Errorf("generate KDF salt: %w", err)
	}

	if err := os.MkdirAll(filepath.Dir(saltPath), 0o755); err != nil {
		return nil, fmt.Errorf("create state dir: %w", err)
	}
	tmpPath := saltPath + ".tmp"
	if err := os.WriteFile(tmpPath, salt, 0o600); err != nil {
		return nil, fmt.Errorf("write KDF salt: %w", err)
	}
	if err := os.Rename(tmpPath, saltPath); err != nil {
		return nil, fmt.Errorf("persist KDF salt: %w", err)
	}
	return salt, nil
}

func objectStoreFromConfig(cfg *config.Config) (storage.ObjectStore, error) {
	objectsDir, err := state.ObjectStoreDir()
	if err != nil {
		return nil, err
	}
	store, err := storage.NewFromConfig(cfg.S3, objectsDir)
	if err != nil {
		return nil, fmt.Errorf("create object store: %w", err)
	}
	return store, nil
}

func loadRestoreManifest(snapshotSelector string) (*backup.Manifest, error) {
	manifestPath, err := state.ManifestPath()
	if err != nil {
		return nil, err
	}
	snapshotDir, err := state.ManifestSnapshotsDir()
	if err != nil {
		return nil, err
	}

	manifest, err := backup.LoadManifestForRestore(manifestPath, snapshotDir, snapshotSelector)
	if err != nil {
		return nil, fmt.Errorf("load manifest: %w", err)
	}
	return manifest, nil
}
