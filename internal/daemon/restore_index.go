package daemon

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"baxter/internal/backup"
	"baxter/internal/state"
)

const restoreListLatestCacheTTL = 5 * time.Second

type restoreManifestSourceState struct {
	selector   string
	path       string
	exists     bool
	size       int64
	modTimeUTC time.Time
}

type restoreManifestIndex struct {
	paths []string
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
	sourceState, cacheable, err := resolveRestoreManifestSourceState(snapshotSelector)
	if err != nil {
		return nil, err
	}
	if cacheable {
		if cached := d.cachedRestoreListIndex(sourceState); cached != nil {
			return cached, nil
		}
	}

	manifest, err := d.loadManifestForRestore(snapshotSelector)
	if err != nil {
		return nil, err
	}
	index := newRestoreManifestIndex(manifest.Entries)
	if !cacheable {
		return index, nil
	}

	refreshedState, _, err := resolveRestoreManifestSourceState(snapshotSelector)
	if err == nil {
		d.cacheRestoreListIndex(refreshedState, index)
	}

	return index, nil
}

func resolveRestoreManifestSourceState(snapshotSelector string) (restoreManifestSourceState, bool, error) {
	selector := normalizedRestoreManifestSelector(snapshotSelector)
	if _, err := time.Parse(time.RFC3339, selector); err == nil {
		return restoreManifestSourceState{}, false, nil
	}

	var path string
	var err error
	if selector == "" {
		path, err = state.ManifestPath()
	} else {
		var snapshotDir string
		snapshotDir, err = state.ManifestSnapshotsDir()
		if err == nil {
			path = filepath.Join(snapshotDir, selector+".json")
		}
	}
	if err != nil {
		return restoreManifestSourceState{}, false, err
	}
	return statRestoreManifestSource(selector, path)
}

func statRestoreManifestSource(selector string, path string) (restoreManifestSourceState, bool, error) {
	sourceState := restoreManifestSourceState{
		selector: normalizedRestoreManifestSelector(selector),
		path:     path,
	}
	info, err := os.Stat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return sourceState, true, nil
		}
		return restoreManifestSourceState{}, false, err
	}
	sourceState.exists = true
	sourceState.size = info.Size()
	sourceState.modTimeUTC = info.ModTime().UTC()
	return sourceState, true, nil
}

func normalizedRestoreManifestSelector(selector string) string {
	trimmed := strings.TrimSpace(selector)
	if trimmed == "" || strings.EqualFold(trimmed, "latest") {
		return ""
	}
	return trimmed
}

func (d *Daemon) cachedRestoreListIndex(sourceState restoreManifestSourceState) *restoreManifestIndex {
	d.restoreIndexMu.Lock()
	defer d.restoreIndexMu.Unlock()

	if d.restoreListIndex == nil || d.restoreListSource != sourceState {
		return nil
	}
	if sourceState.selector == "" && !d.restoreListIndexedAt.IsZero() {
		if d.clockNow().Sub(d.restoreListIndexedAt) >= restoreListLatestCacheTTL {
			return nil
		}
	}
	return d.restoreListIndex
}

func (d *Daemon) cacheRestoreListIndex(sourceState restoreManifestSourceState, index *restoreManifestIndex) {
	d.restoreIndexMu.Lock()
	defer d.restoreIndexMu.Unlock()

	d.restoreListSource = sourceState
	d.restoreListIndexedAt = d.clockNow()
	d.restoreListIndex = index
}
