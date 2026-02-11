package cli

import (
	"fmt"

	"baxter/internal/backup"
	"baxter/internal/config"
	"baxter/internal/state"
)

func runBackup(cfg *config.Config) error {
	key, err := encryptionKey(cfg)
	if err != nil {
		return err
	}

	manifestPath, err := state.ManifestPath()
	if err != nil {
		return err
	}
	snapshotDir, err := state.ManifestSnapshotsDir()
	if err != nil {
		return err
	}

	store, err := objectStoreFromConfig(cfg)
	if err != nil {
		return err
	}

	result, err := backup.Run(cfg, backup.RunOptions{
		ManifestPath:      manifestPath,
		SnapshotDir:       snapshotDir,
		SnapshotRetention: cfg.Retention.ManifestSnapshots,
		EncryptionKey:     key,
		Store:             store,
	})
	if err != nil {
		return err
	}

	fmt.Printf("backup complete: uploaded=%d removed=%d total=%d\n", result.Uploaded, result.Removed, result.Total)
	return nil
}

func backupStatus(cfg *config.Config) error {
	manifestPath, err := state.ManifestPath()
	if err != nil {
		return err
	}

	m, err := backup.LoadManifest(manifestPath)
	if err != nil {
		return fmt.Errorf("load manifest: %w", err)
	}
	snapshotDir, err := state.ManifestSnapshotsDir()
	if err != nil {
		return err
	}
	snapshots, err := backup.ListSnapshotManifests(snapshotDir)
	if err != nil {
		return fmt.Errorf("list snapshots: %w", err)
	}

	store, err := objectStoreFromConfig(cfg)
	if err != nil {
		return err
	}
	keys, err := store.ListKeys()
	if err != nil {
		return fmt.Errorf("list objects: %w", err)
	}

	latestSnapshot := ""
	if len(snapshots) > 0 {
		latestSnapshot = snapshots[0].ID
	}
	fmt.Printf(
		"manifest entries=%d objects=%d snapshots=%d latest_snapshot=%s created_at=%s\n",
		len(m.Entries),
		len(keys),
		len(snapshots),
		latestSnapshot,
		m.CreatedAt.Format("2006-01-02 15:04:05Z07:00"),
	)
	return nil
}
