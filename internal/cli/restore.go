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
)

func restorePath(cfg *config.Config, requestedPath string, opts restoreOptions) error {
	m, err := loadRestoreManifest(opts.Snapshot)
	if err != nil {
		return err
	}

	entry, err := backup.FindEntryByPath(m, requestedPath)
	if err != nil {
		absPath, absErr := filepath.Abs(requestedPath)
		if absErr != nil {
			return err
		}
		entry, err = backup.FindEntryByPath(m, absPath)
		if err != nil {
			return err
		}
	}

	store, err := objectStoreFromConfig(cfg)
	if err != nil {
		return err
	}

	targetPath, err := resolvedRestorePath(entry.Path, opts.ToDir)
	if err != nil {
		return err
	}

	if opts.DryRun {
		fmt.Printf("restore dry-run: source=%s target=%s overwrite=%t\n", entry.Path, targetPath, opts.Overwrite)
		return nil
	}

	keys, err := encryptionKeys(cfg)
	if err != nil {
		return err
	}

	payload, err := store.GetObject(backup.ObjectKeyForPath(entry.Path))
	if err != nil {
		return fmt.Errorf("read object: %w", err)
	}

	plain, err := crypto.DecryptBytesWithAnyKey(keys.candidates, payload)
	if err != nil {
		return fmt.Errorf("decrypt object: %w", err)
	}
	if err := backup.VerifyEntryContent(entry, plain); err != nil {
		return fmt.Errorf("verify restored content: %w", err)
	}

	if opts.VerifyOnly {
		fmt.Printf("restore verify-only complete: source=%s checksum=%s\n", entry.Path, entry.SHA256)
		return nil
	}

	if !opts.Overwrite {
		if _, err := os.Stat(targetPath); err == nil {
			return fmt.Errorf("target exists: %s (use --overwrite to replace)", targetPath)
		} else if !os.IsNotExist(err) {
			return err
		}
	}

	if err := os.MkdirAll(filepath.Dir(targetPath), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(targetPath, plain, entry.Mode.Perm()); err != nil {
		return err
	}

	fmt.Printf("restore complete: source=%s target=%s\n", entry.Path, targetPath)
	return nil
}

func restoreList(opts restoreListOptions) error {
	m, err := loadRestoreManifest(opts.Snapshot)
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
