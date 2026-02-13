package backup

import (
	"fmt"
	"os"

	"baxter/internal/config"
	"baxter/internal/crypto"
	"baxter/internal/storage"
)

const defaultUploadMaxAttempts = 3

type RunOptions struct {
	ManifestPath      string
	SnapshotDir       string
	SnapshotRetention int
	UploadMaxAttempts int
	EncryptionKey     []byte
	Store             storage.ObjectStore
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

	plan := PlanChanges(previous, current)
	for _, entry := range plan.NewOrChanged {
		plain, err := os.ReadFile(entry.Path)
		if err != nil {
			return RunResult{}, fmt.Errorf("read file %s: %w", entry.Path, err)
		}
		encrypted, err := crypto.EncryptBytes(opts.EncryptionKey, plain)
		if err != nil {
			return RunResult{}, fmt.Errorf("encrypt file %s: %w", entry.Path, err)
		}
		objectKey := ObjectKeyForPath(entry.Path)
		if err := putObjectWithRetry(opts.Store, objectKey, encrypted, opts.effectiveUploadMaxAttempts()); err != nil {
			return RunResult{}, fmt.Errorf("store object %s: %w", entry.Path, err)
		}
	}

	if err := SaveManifest(opts.ManifestPath, current); err != nil {
		return RunResult{}, fmt.Errorf("save manifest: %w", err)
	}
	if _, err := SaveSnapshotManifest(opts.SnapshotDir, current); err != nil {
		return RunResult{}, fmt.Errorf("save snapshot manifest: %w", err)
	}
	if _, err := PruneSnapshotManifests(opts.SnapshotDir, opts.SnapshotRetention); err != nil {
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
