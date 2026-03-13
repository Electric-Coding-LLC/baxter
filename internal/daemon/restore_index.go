package daemon

import (
	"path/filepath"
	"sort"
	"strings"
	"time"

	"baxter/internal/backup"
)

type restoreManifestCacheKey struct {
	selector   string
	createdAt  time.Time
	entryCount int
	firstPath  string
	lastPath   string
}

type restoreManifestIndex struct {
	paths []string
}

func newRestoreManifestCacheKey(selector string, manifest *backup.Manifest) restoreManifestCacheKey {
	key := restoreManifestCacheKey{
		selector: strings.TrimSpace(selector),
	}
	if manifest == nil {
		return key
	}
	key.createdAt = manifest.CreatedAt.UTC()
	key.entryCount = len(manifest.Entries)
	if len(manifest.Entries) == 0 {
		return key
	}
	key.firstPath = filepath.Clean(manifest.Entries[0].Path)
	key.lastPath = filepath.Clean(manifest.Entries[len(manifest.Entries)-1].Path)
	return key
}

func newRestoreManifestIndex(entries []backup.ManifestEntry) *restoreManifestIndex {
	paths := make([]string, 0, len(entries))
	sorted := true
	previous := ""
	for i, entry := range entries {
		path := filepath.Clean(entry.Path)
		paths = append(paths, path)
		if i > 0 && previous > path {
			sorted = false
		}
		previous = path
	}
	if !sorted {
		sort.Strings(paths)
	}
	return &restoreManifestIndex{paths: paths}
}

func (idx *restoreManifestIndex) filterPaths(prefix string, contains string) []string {
	cleanPrefix := normalizedRestoreFilterPrefix(prefix)
	contains = strings.TrimSpace(contains)

	paths := idx.pathsWithPrefix(cleanPrefix)
	if contains == "" {
		return append([]string(nil), paths...)
	}

	filtered := make([]string, 0, len(paths))
	for _, path := range paths {
		if strings.Contains(path, contains) {
			filtered = append(filtered, path)
		}
	}
	return filtered
}

func (idx *restoreManifestIndex) filterChildrenPaths(prefix string, contains string) []string {
	cleanPrefix := normalizedRestoreFilterPrefix(prefix)
	contains = strings.TrimSpace(contains)

	children := make(map[string]bool)
	for _, path := range idx.pathsWithPrefix(cleanPrefix) {
		if contains != "" && !strings.Contains(path, contains) {
			continue
		}

		childPath, isDirectory, ok := immediateRestoreChild(path, cleanPrefix)
		if !ok {
			continue
		}
		children[childPath] = children[childPath] || isDirectory
	}

	paths := make([]string, 0, len(children))
	for childPath, isDirectory := range children {
		if isDirectory {
			paths = append(paths, childPath+string(filepath.Separator))
			continue
		}
		paths = append(paths, childPath)
	}
	sort.Strings(paths)
	return paths
}

func (idx *restoreManifestIndex) pathsWithPrefix(prefix string) []string {
	if idx == nil || len(idx.paths) == 0 {
		return nil
	}
	if prefix == "" {
		return idx.paths
	}

	start := sort.Search(len(idx.paths), func(i int) bool {
		return idx.paths[i] >= prefix
	})
	if start >= len(idx.paths) {
		return nil
	}

	matches := make([]string, 0)
	for i := start; i < len(idx.paths); i++ {
		path := idx.paths[i]
		if !strings.HasPrefix(path, prefix) {
			break
		}
		if backup.PathHasPrefix(path, prefix) {
			matches = append(matches, path)
		}
	}
	if len(matches) == 0 {
		return nil
	}
	return matches
}

func normalizedRestoreFilterPrefix(prefix string) string {
	cleanPrefix := filepath.Clean(strings.TrimSpace(prefix))
	if cleanPrefix == "." {
		return ""
	}
	return cleanPrefix
}

func (d *Daemon) loadRestoreListIndex(snapshotSelector string) (*restoreManifestIndex, error) {
	manifest, err := d.loadManifestForRestore(snapshotSelector)
	if err != nil {
		return nil, err
	}

	key := newRestoreManifestCacheKey(snapshotSelector, manifest)

	d.restoreIndexMu.Lock()
	cachedKey := d.restoreListIndexKey
	cachedIndex := d.restoreListIndex
	d.restoreIndexMu.Unlock()
	if cachedIndex != nil && cachedKey == key {
		return cachedIndex, nil
	}

	index := newRestoreManifestIndex(manifest.Entries)

	d.restoreIndexMu.Lock()
	if d.restoreListIndex != nil && d.restoreListIndexKey == key {
		index = d.restoreListIndex
	} else {
		d.restoreListIndexKey = key
		d.restoreListIndex = index
	}
	d.restoreIndexMu.Unlock()

	return index, nil
}
