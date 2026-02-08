package backup

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const snapshotIDLayout = "20060102T150405.000000000Z"
const latestSnapshotSelector = "latest"

var ErrSnapshotNotFound = errors.New("snapshot not found")

type ManifestSnapshot struct {
	ID        string
	Path      string
	CreatedAt time.Time
	Entries   int
}

func SaveSnapshotManifest(snapshotDir string, m *Manifest) (ManifestSnapshot, error) {
	if strings.TrimSpace(snapshotDir) == "" {
		return ManifestSnapshot{}, errors.New("snapshot directory is required")
	}
	if m == nil {
		return ManifestSnapshot{}, errors.New("manifest is required")
	}

	baseID := SnapshotID(m.CreatedAt)
	id := baseID
	path := filepath.Join(snapshotDir, id+".json")
	for suffix := 1; ; suffix++ {
		_, err := os.Stat(path)
		if os.IsNotExist(err) {
			break
		}
		if err != nil {
			return ManifestSnapshot{}, err
		}
		id = fmt.Sprintf("%s-%d", baseID, suffix)
		path = filepath.Join(snapshotDir, id+".json")
	}

	if err := SaveManifest(path, m); err != nil {
		return ManifestSnapshot{}, err
	}
	return ManifestSnapshot{
		ID:        id,
		Path:      path,
		CreatedAt: m.CreatedAt.UTC(),
		Entries:   len(m.Entries),
	}, nil
}

func SnapshotID(t time.Time) string {
	if t.IsZero() {
		t = time.Now().UTC()
	}
	return t.UTC().Format(snapshotIDLayout)
}

func ListSnapshotManifests(snapshotDir string) ([]ManifestSnapshot, error) {
	if strings.TrimSpace(snapshotDir) == "" {
		return []ManifestSnapshot{}, nil
	}
	entries, err := os.ReadDir(snapshotDir)
	if err != nil {
		if os.IsNotExist(err) {
			return []ManifestSnapshot{}, nil
		}
		return nil, err
	}

	snapshots := make([]ManifestSnapshot, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		if filepath.Ext(name) != ".json" {
			continue
		}

		id := strings.TrimSuffix(name, ".json")
		path := filepath.Join(snapshotDir, name)
		manifest, err := LoadManifest(path)
		if err != nil {
			return nil, fmt.Errorf("load snapshot %s: %w", name, err)
		}
		snapshots = append(snapshots, ManifestSnapshot{
			ID:        id,
			Path:      path,
			CreatedAt: manifest.CreatedAt.UTC(),
			Entries:   len(manifest.Entries),
		})
	}

	sort.Slice(snapshots, func(i, j int) bool {
		a := snapshots[i]
		b := snapshots[j]
		if a.CreatedAt.Equal(b.CreatedAt) {
			return a.ID > b.ID
		}
		return a.CreatedAt.After(b.CreatedAt)
	})
	return snapshots, nil
}

func PruneSnapshotManifests(snapshotDir string, retain int) (int, error) {
	if retain <= 0 {
		return 0, nil
	}

	snapshots, err := ListSnapshotManifests(snapshotDir)
	if err != nil {
		return 0, err
	}
	if len(snapshots) <= retain {
		return 0, nil
	}

	removed := 0
	for _, snapshot := range snapshots[retain:] {
		if err := os.Remove(snapshot.Path); err != nil && !os.IsNotExist(err) {
			return removed, err
		}
		removed++
	}
	return removed, nil
}

func LoadManifestForRestore(latestManifestPath, snapshotDir, selector string) (*Manifest, error) {
	trimmed := strings.TrimSpace(selector)
	if trimmed == "" || strings.EqualFold(trimmed, latestSnapshotSelector) {
		return LoadManifest(latestManifestPath)
	}

	if asOf, err := time.Parse(time.RFC3339, trimmed); err == nil {
		snapshots, listErr := ListSnapshotManifests(snapshotDir)
		if listErr != nil {
			return nil, listErr
		}
		for _, snapshot := range snapshots {
			if !snapshot.CreatedAt.After(asOf.UTC()) {
				return LoadManifest(snapshot.Path)
			}
		}
		return nil, fmt.Errorf("%w: %s", ErrSnapshotNotFound, trimmed)
	}

	path := filepath.Join(snapshotDir, trimmed+".json")
	if _, err := os.Stat(path); err != nil {
		if os.IsNotExist(err) {
			return nil, fmt.Errorf("%w: %s", ErrSnapshotNotFound, trimmed)
		}
		return nil, err
	}
	return LoadManifest(path)
}
