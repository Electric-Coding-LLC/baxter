package cli

import (
	"fmt"
	"os"
	"path/filepath"
	"time"

	"baxter/internal/backup"
	"baxter/internal/config"
	"baxter/internal/crypto"
	"baxter/internal/state"
	"baxter/internal/storage"
)

func restorePath(cfg *config.Config, requestedPath string, opts restoreOptions) error {
	m, err := loadRestoreManifest(cfg, opts.Snapshot)
	if err != nil {
		return err
	}

	selection, err := backup.ResolveRestoreSelection(m, requestedPath)
	if err != nil {
		return err
	}

	store, err := objectStoreFromConfig(cfg)
	if err != nil {
		return err
	}
	keys, err := accessEncryptionKeys(cfg, store)
	if err != nil {
		return err
	}

	targetPath, err := resolvedRestorePath(selection.SourcePath, opts.ToDir)
	if err != nil {
		return err
	}

	if opts.DryRun {
		fmt.Printf("restore dry-run: source=%s target=%s overwrite=%t\n", selection.SourcePath, targetPath, opts.Overwrite)
		return nil
	}

	type restoreTarget struct {
		entry      backup.ManifestEntry
		targetPath string
	}

	targets := make([]restoreTarget, 0, len(selection.Entries))
	for _, entry := range selection.Entries {
		entryTargetPath, err := resolvedRestorePath(entry.Path, opts.ToDir)
		if err != nil {
			return err
		}
		targets = append(targets, restoreTarget{
			entry:      entry,
			targetPath: entryTargetPath,
		})
	}

	if !opts.Overwrite && !opts.VerifyOnly {
		for _, target := range targets {
			if _, err := os.Stat(target.targetPath); err == nil {
				return fmt.Errorf("target exists: %s (use --overwrite to replace)", target.targetPath)
			} else if !os.IsNotExist(err) {
				return err
			}
		}
	}

	for _, target := range targets {
		payload, err := store.GetObject(backup.ResolveObjectKey(target.entry))
		if err != nil {
			switch {
			case storage.IsNotFound(err):
				return fmt.Errorf("restore object missing for path %s", target.entry.Path)
			case storage.IsTransient(err):
				return fmt.Errorf("restore storage transient failure for %s: %w", target.entry.Path, err)
			default:
				return fmt.Errorf("read object: %w", err)
			}
		}

		plain, err := crypto.DecryptBytesWithAnyKey(keys.candidates, payload)
		if err != nil {
			return fmt.Errorf("decrypt object: %w", err)
		}
		if err := backup.VerifyEntryContent(target.entry, plain); err != nil {
			return fmt.Errorf("verify restored content: %w", err)
		}

		if opts.VerifyOnly {
			continue
		}

		if err := os.MkdirAll(filepath.Dir(target.targetPath), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(target.targetPath, plain, target.entry.Mode.Perm()); err != nil {
			return err
		}
	}

	if opts.VerifyOnly {
		fmt.Printf("restore verify-only complete: source=%s files=%d\n", selection.SourcePath, len(targets))
		return nil
	}

	fmt.Printf("restore complete: source=%s target=%s files=%d\n", selection.SourcePath, targetPath, len(targets))
	return nil
}

func restoreList(cfg *config.Config, opts restoreListOptions) error {
	m, err := loadRestoreManifest(cfg, opts.Snapshot)
	if err != nil {
		return err
	}

	for _, path := range filterRestorePaths(m.Entries, opts) {
		fmt.Println(path)
	}
	return nil
}

func snapshotList(opts snapshotListOptions) error {
	snapshotDir, err := state.ManifestSnapshotsDir()
	if err != nil {
		return err
	}
	snapshots, err := backup.ListSnapshotManifests(snapshotDir)
	if err != nil {
		return fmt.Errorf("list snapshots: %w", err)
	}

	limit := len(snapshots)
	if opts.Limit > 0 && opts.Limit < limit {
		limit = opts.Limit
	}
	for i := 0; i < limit; i++ {
		s := snapshots[i]
		fmt.Printf("%s %s entries=%d\n", s.ID, s.CreatedAt.Format(time.RFC3339), s.Entries)
	}
	return nil
}
