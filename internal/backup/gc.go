package backup

import (
	"fmt"
	"os"
	"strings"

	"baxter/internal/storage"
)

type GCOptions struct {
	LatestManifestPath string
	SnapshotDir        string
	Store              storage.ObjectStore
	DryRun             bool
}

type GCResult struct {
	SourceManifests   int
	ReferencedObjects int
	ExistingObjects   int
	RetainedObjects   int
	CandidateDeletes  int
	DeletedObjects    int
	DryRun            bool
	Skipped           bool
}

func GarbageCollectObjects(opts GCOptions) (GCResult, error) {
	if strings.TrimSpace(opts.LatestManifestPath) == "" {
		return GCResult{}, fmt.Errorf("latest manifest path is required")
	}
	if strings.TrimSpace(opts.SnapshotDir) == "" {
		return GCResult{}, fmt.Errorf("snapshot directory is required")
	}
	if opts.Store == nil {
		return GCResult{}, fmt.Errorf("object store is required")
	}

	reachableKeys, sourceManifestCount, err := reachableObjectKeys(opts.LatestManifestPath, opts.SnapshotDir)
	if err != nil {
		return GCResult{}, err
	}

	existingKeys, err := opts.Store.ListKeys()
	if err != nil {
		return GCResult{}, fmt.Errorf("list object keys: %w", err)
	}

	result := GCResult{
		SourceManifests:   sourceManifestCount,
		ReferencedObjects: len(reachableKeys),
		ExistingObjects:   len(existingKeys),
		DryRun:            opts.DryRun,
	}
	if sourceManifestCount == 0 {
		// Safety rail: without manifest sources we should not delete any objects.
		result.RetainedObjects = len(existingKeys)
		result.Skipped = true
		return result, nil
	}

	for _, key := range existingKeys {
		if _, ok := reachableKeys[key]; ok {
			result.RetainedObjects++
			continue
		}

		result.CandidateDeletes++
		if opts.DryRun {
			continue
		}
		if err := opts.Store.DeleteObject(key); err != nil {
			return result, fmt.Errorf("delete object %s: %w", key, err)
		}
		result.DeletedObjects++
	}

	return result, nil
}

func reachableObjectKeys(latestManifestPath, snapshotDir string) (map[string]struct{}, int, error) {
	keys := make(map[string]struct{})
	sourceManifestCount := 0

	if _, err := os.Stat(latestManifestPath); err == nil {
		manifest, err := LoadManifest(latestManifestPath)
		if err != nil {
			return nil, 0, fmt.Errorf("load latest manifest: %w", err)
		}
		sourceManifestCount++
		addManifestObjectKeys(keys, manifest)
	} else if !os.IsNotExist(err) {
		return nil, 0, fmt.Errorf("stat latest manifest: %w", err)
	}

	snapshots, err := ListSnapshotManifests(snapshotDir)
	if err != nil {
		return nil, 0, fmt.Errorf("list snapshots: %w", err)
	}
	for _, snapshot := range snapshots {
		manifest, err := LoadManifest(snapshot.Path)
		if err != nil {
			return nil, 0, fmt.Errorf("load snapshot %s: %w", snapshot.ID, err)
		}
		sourceManifestCount++
		addManifestObjectKeys(keys, manifest)
	}

	return keys, sourceManifestCount, nil
}

func addManifestObjectKeys(target map[string]struct{}, m *Manifest) {
	if m == nil {
		return
	}
	for _, entry := range m.Entries {
		target[ObjectKeyForPath(entry.Path)] = struct{}{}
	}
}
