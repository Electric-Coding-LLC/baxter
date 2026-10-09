package backup

import (
	"bytes"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"time"

	"baxter/internal/config"
	"baxter/internal/recovery"
	"baxter/internal/storage"
)

const defaultUploadMaxAttempts = 3
const defaultUploadConcurrency = 4

type ProgressUpdate struct {
	Uploaded int
	Total    int
	Path     string
}

type RunOptions struct {
	ManifestPath       string
	SnapshotDir        string
	SnapshotRetention  int
	SnapshotMaxAgeDays int
	SnapshotPruneNow   time.Time
	UploadMaxAttempts  int
	UploadConcurrency  int
	EncryptionKey      []byte
	KDFSalt            []byte
	WrappedMasterKey   []byte
	BackupSetID        string
	Store              storage.ObjectStore
	Progress           func(ProgressUpdate)
}

type RunResult struct {
	Uploaded int
	Removed  int
	Total    int
	Skipped  []SkippedFile
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

	buildOpts := BuildOptions{
		ExcludePaths: cfg.ExcludePaths,
		ExcludeGlobs: cfg.ExcludeGlobs,
	}
	current, skipped, err := ScanManifest(cfg.BackupRoots, buildOpts)
	if err != nil {
		return RunResult{}, fmt.Errorf("build manifest: %w", err)
	}
	carryForwardSkipped(previous, current, skipped, buildOpts)
	AssignObjectKeys(previous, current)

	plan := PlanChanges(previous, current)
	outcome, err := uploadChangedEntries(entriesMissingStoredContent(previous, plan.NewOrChanged), opts)
	if err != nil {
		return RunResult{}, err
	}
	if err := validateManifestRoots(cfg.BackupRoots, buildOpts); err != nil {
		return RunResult{}, err
	}
	if outcome.changesManifest() {
		outcome.applyTo(previous, current)
		plan = PlanChanges(previous, current)
	}
	skipped = sortedSkippedFiles(append(skipped, outcome.skipped...))

	snapshot, err := ReserveSnapshotManifest(opts.SnapshotDir, current)
	if err != nil {
		return RunResult{}, fmt.Errorf("reserve snapshot manifest: %w", err)
	}
	if err := WriteEncryptedSnapshotManifest(opts.Store, snapshot.ID, current, opts.EncryptionKey); err != nil {
		return RunResult{}, err
	}
	if err := writeRecoveryMetadata(opts, snapshot.ID, current.CreatedAt); err != nil {
		return RunResult{}, err
	}
	if err := SaveManifest(opts.ManifestPath, current); err != nil {
		return RunResult{}, fmt.Errorf("save manifest: %w", err)
	}
	if err := SaveSnapshotManifestAt(snapshot, current); err != nil {
		return RunResult{}, fmt.Errorf("save snapshot manifest: %w", err)
	}
	if _, err := PruneSnapshotManifestsWithPolicy(opts.SnapshotDir, SnapshotPrunePolicy{
		Retain:     opts.SnapshotRetention,
		MaxAgeDays: opts.SnapshotMaxAgeDays,
		Now:        opts.SnapshotPruneNow,
	}); err != nil {
		return RunResult{}, fmt.Errorf("prune snapshot manifests: %w", err)
	}

	return RunResult{
		Uploaded: outcome.stored,
		Removed:  len(plan.RemovedPaths),
		Total:    len(current.Entries),
		Skipped:  skipped,
	}, nil
}

func (o RunOptions) effectiveUploadMaxAttempts() int {
	if o.UploadMaxAttempts <= 0 {
		return defaultUploadMaxAttempts
	}
	return o.UploadMaxAttempts
}

func (o RunOptions) effectiveUploadConcurrency() int {
	if o.UploadConcurrency <= 0 {
		return defaultUploadConcurrency
	}
	return o.UploadConcurrency
}

// entriesMissingStoredContent drops entries whose content-addressed object the
// previous manifest already references, so renamed or copied files are not
// uploaded again.
func entriesMissingStoredContent(previous *Manifest, entries []ManifestEntry) []ManifestEntry {
	stored := make(map[string]struct{})
	if previous != nil {
		for _, entry := range previous.Entries {
			if !entry.HasStoredContent() {
				continue
			}
			if key := ResolveObjectKey(entry); strings.HasPrefix(key, contentObjectKeyPrefix) {
				stored[key] = struct{}{}
			}
		}
	}

	missing := make([]ManifestEntry, 0, len(entries))
	for _, entry := range entries {
		if _, ok := stored[entry.ObjectKey]; ok {
			continue
		}
		missing = append(missing, entry)
	}
	return missing
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
		if len(opts.WrappedMasterKey) > 0 {
			if existing, err := metadata.WrappedMasterKeyBytes(); err != nil {
				return err
			} else if len(existing) > 0 && !bytes.Equal(existing, opts.WrappedMasterKey) {
				return fmt.Errorf("recovery metadata wrapped master key mismatch")
			}
			metadata.WrappedMasterKey = hex.EncodeToString(opts.WrappedMasterKey)
		}
		metadata.LatestSnapshotID = latestSnapshotID
		metadata.UpdatedAt = now.UTC()
	case errors.Is(err, recovery.ErrMetadataNotFound):
		metadata, err = recovery.NewMetadata(opts.BackupSetID, opts.KDFSalt, latestSnapshotID, opts.WrappedMasterKey, now)
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
