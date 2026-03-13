package backup

import (
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	"baxter/internal/config"
	"baxter/internal/crypto"
	"baxter/internal/recovery"
	"baxter/internal/storage"
)

const defaultUploadMaxAttempts = 3

type RunOptions struct {
	ManifestPath       string
	SnapshotDir        string
	SnapshotRetention  int
	SnapshotMaxAgeDays int
	SnapshotPruneNow   time.Time
	UploadMaxAttempts  int
	EncryptionKey      []byte
	KDFSalt            []byte
	BackupSetID        string
	Store              storage.ObjectStore
}

type RunResult struct {
	Uploaded int
	Removed  int
	Total    int
}

func Run(cfg *config.Config, opts RunOptions) (RunResult, error) {
	if cfg == nil {
		return RunResult{}, fmt.Errorf("config is required")
	}
	if len(cfg.BackupRoots) == 0 {
		return RunResult{}, fmt.Errorf("no backup_roots configured")
	}
	if opts.ManifestPath == "" {
		return RunResult{}, fmt.Errorf("manifest path is required")
	}
	if opts.Store == nil {
		return RunResult{}, fmt.Errorf("object store is required")
	}
	if opts.SnapshotDir == "" {
		return RunResult{}, fmt.Errorf("snapshot directory is required")
	}
	if len(opts.EncryptionKey) == 0 {
		return RunResult{}, fmt.Errorf("encryption key is required")
	}
	if len(opts.KDFSalt) == 0 {
		return RunResult{}, fmt.Errorf("kdf salt is required")
	}
	if opts.BackupSetID == "" {
		return RunResult{}, fmt.Errorf("backup set id is required")
	}

	previous, err := LoadManifest(opts.ManifestPath)
	if err != nil {
		return RunResult{}, fmt.Errorf("load manifest: %w", err)
	}

	current, err := BuildManifestWithOptions(cfg.BackupRoots, BuildOptions{
		ExcludePaths: cfg.ExcludePaths,
		ExcludeGlobs: cfg.ExcludeGlobs,
	})
	if err != nil {
		return RunResult{}, fmt.Errorf("build manifest: %w", err)
	}
	AssignObjectKeys(previous, current)

	plan := PlanChanges(previous, current)
	for _, entry := range plan.NewOrChanged {
		plain, err := readEntryContent(entry)
		if err != nil {
			return RunResult{}, err
		}
		encrypted, err := crypto.EncryptBytes(opts.EncryptionKey, plain)
		if err != nil {
			return RunResult{}, fmt.Errorf("encrypt file %s: %w", entry.Path, err)
		}
		if err := putObjectWithRetry(opts.Store, entry.ObjectKey, encrypted, opts.effectiveUploadMaxAttempts()); err != nil {
			return RunResult{}, fmt.Errorf("store object %s: %w", entry.Path, err)
		}
	}

	if err := SaveManifest(opts.ManifestPath, current); err != nil {
		return RunResult{}, fmt.Errorf("save manifest: %w", err)
	}
	snapshot, err := SaveSnapshotManifest(opts.SnapshotDir, current)
	if err != nil {
		return RunResult{}, fmt.Errorf("save snapshot manifest: %w", err)
	}
	if err := WriteEncryptedSnapshotManifest(opts.Store, snapshot.ID, current, opts.EncryptionKey); err != nil {
		return RunResult{}, err
	}
	if err := writeRecoveryMetadata(opts, snapshot.ID, current.CreatedAt); err != nil {
		return RunResult{}, err
	}
	if _, err := PruneSnapshotManifestsWithPolicy(opts.SnapshotDir, SnapshotPrunePolicy{
		Retain:     opts.SnapshotRetention,
		MaxAgeDays: opts.SnapshotMaxAgeDays,
		Now:        opts.SnapshotPruneNow,
	}); err != nil {
		return RunResult{}, fmt.Errorf("prune snapshot manifests: %w", err)
	}

	return RunResult{
		Uploaded: len(plan.NewOrChanged),
		Removed:  len(plan.RemovedPaths),
		Total:    len(current.Entries),
	}, nil
}

func (o RunOptions) effectiveUploadMaxAttempts() int {
	if o.UploadMaxAttempts <= 0 {
		return defaultUploadMaxAttempts
	}
	return o.UploadMaxAttempts
}

func putObjectWithRetry(store storage.ObjectStore, key string, data []byte, maxAttempts int) error {
	if maxAttempts <= 0 {
		maxAttempts = 1
	}

	var lastErr error
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		if err := store.PutObject(key, data); err == nil {
			return nil
		} else {
			lastErr = err
		}
	}
	return lastErr
}

func readEntryContent(entry ManifestEntry) ([]byte, error) {
	plain, err := os.ReadFile(entry.Path)
	if err != nil {
		return nil, fmt.Errorf("read file %s: %w", entry.Path, err)
	}
	if int64(len(plain)) != entry.Size {
		return nil, fmt.Errorf("source file changed during backup: %s size mismatch", entry.Path)
	}
	if err := VerifyEntryContent(entry, plain); err != nil {
		return nil, fmt.Errorf("source file changed during backup: %w", err)
	}
	return plain, nil
}

func writeRecoveryMetadata(opts RunOptions, latestSnapshotID string, now time.Time) error {
	metadata, err := recovery.ReadMetadata(opts.Store)
	switch {
	case err == nil:
		if strings.TrimSpace(metadata.BackupSetID) != strings.TrimSpace(opts.BackupSetID) {
			return fmt.Errorf("recovery metadata backup set mismatch: got %q want %q", metadata.BackupSetID, opts.BackupSetID)
		}
		if metadata.KDF.SaltHex != hex.EncodeToString(opts.KDFSalt) {
			return fmt.Errorf("recovery metadata kdf salt mismatch")
		}
		metadata.LatestSnapshotID = latestSnapshotID
		metadata.UpdatedAt = now.UTC()
	case errors.Is(err, recovery.ErrMetadataNotFound):
		metadata, err = recovery.NewMetadata(opts.BackupSetID, opts.KDFSalt, latestSnapshotID, now)
		if err != nil {
			return fmt.Errorf("build recovery metadata: %w", err)
		}
	default:
		return fmt.Errorf("read recovery metadata: %w", err)
	}

	if err := recovery.WriteMetadata(opts.Store, metadata); err != nil {
		return fmt.Errorf("write recovery metadata: %w", err)
	}
	return nil
}
