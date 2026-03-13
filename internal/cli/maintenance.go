package cli

import (
	"fmt"

	"baxter/internal/backup"
	"baxter/internal/config"
	"baxter/internal/state"
)

func runGC(cfg *config.Config, opts gcOptions) error {
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

	snapshotPolicy := backup.SnapshotPrunePolicy{
		Retain:     cfg.Retention.ManifestSnapshots,
		MaxAgeDays: cfg.Retention.ManifestMaxAgeDays,
	}
	prunedSnapshots := 0
	if opts.DryRun {
		candidates, err := backup.PlanSnapshotPruneManifestsWithPolicy(snapshotDir, snapshotPolicy)
		if err != nil {
			return err
		}
		prunedSnapshots = len(candidates)
	} else {
		prunedSnapshots, err = backup.PruneSnapshotManifestsWithPolicy(snapshotDir, snapshotPolicy)
		if err != nil {
			return err
		}
	}

	result, err := backup.GarbageCollectObjects(backup.GCOptions{
		LatestManifestPath: manifestPath,
		SnapshotDir:        snapshotDir,
		Store:              store,
		DryRun:             opts.DryRun,
	})
	if err != nil {
		return err
	}

	if result.Skipped {
		fmt.Printf(
			"gc skipped: no manifest sources found (existing=%d retained=%d snapshots=%d)\n",
			result.ExistingObjects,
			result.RetainedObjects,
			prunedSnapshots,
		)
		return nil
	}
	if opts.DryRun {
		fmt.Printf(
			"gc dry-run: manifests=%d referenced=%d existing=%d would_delete=%d retained=%d would_prune_snapshots=%d\n",
			result.SourceManifests,
			result.ReferencedObjects,
			result.ExistingObjects,
			result.CandidateDeletes,
			result.RetainedObjects,
			prunedSnapshots,
		)
		return nil
	}

	fmt.Printf(
		"gc complete: manifests=%d referenced=%d existing=%d deleted=%d retained=%d pruned_snapshots=%d\n",
		result.SourceManifests,
		result.ReferencedObjects,
		result.ExistingObjects,
		result.DeletedObjects,
		result.RetainedObjects,
		prunedSnapshots,
	)
	return nil
}

func runVerify(cfg *config.Config, opts verifyOptions) error {
	manifest, err := loadRestoreManifest(cfg, opts.Snapshot)
	if err != nil {
		return err
	}

	entries := filterManifestEntriesByPrefix(manifest.Entries, opts.Prefix)
	totalCandidates := len(entries)
	if opts.Sample > 0 {
		entries = sampleManifestEntries(entries, opts.Sample)
	}
	if opts.Limit > 0 && opts.Limit < len(entries) {
		entries = entries[:opts.Limit]
	}

	keys, err := encryptionKeys(cfg)
	if err != nil {
		return err
	}
	store, err := objectStoreFromConfig(cfg)
	if err != nil {
		return err
	}

	result, err := backup.VerifyManifestEntriesWithKeys(entries, keys.candidates, store)
	if err != nil {
		return err
	}

	fmt.Printf(
		"verify complete: total=%d checked=%d ok=%d missing=%d read_errors=%d decrypt_errors=%d checksum_errors=%d\n",
		totalCandidates,
		result.Checked,
		result.OK,
		result.Missing,
		result.ReadErrors,
		result.DecryptErrors,
		result.ChecksumErrors,
	)

	if result.HasFailures() {
		return fmt.Errorf(
			"verify failed: missing=%d read_errors=%d decrypt_errors=%d checksum_errors=%d",
			result.Missing,
			result.ReadErrors,
			result.DecryptErrors,
			result.ChecksumErrors,
		)
	}
	return nil
}
