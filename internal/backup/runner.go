package backup

import (
	"fmt"
	"os"

	"baxter/internal/config"
	"baxter/internal/crypto"
	"baxter/internal/storage"
)

type RunOptions struct {
	ManifestPath      string
	SnapshotDir       string
	SnapshotRetention int
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

	current, err := BuildManifest(cfg.BackupRoots)
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
		if err := opts.Store.PutObject(ObjectKeyForPath(entry.Path), encrypted); err != nil {
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
