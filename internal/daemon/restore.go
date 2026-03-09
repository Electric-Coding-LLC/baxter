package daemon

import (
	"errors"
	"fmt"
	"net/http"
	"path/filepath"
	"sort"
	"strings"

	"baxter/internal/backup"
	"baxter/internal/state"
	"baxter/internal/storage"
)

var (
	errRestoreManifestLoad  = errors.New("manifest load failed")
	errRestorePathLookup    = errors.New("path lookup failed")
	errRestoreTargetInvalid = errors.New("invalid restore target")
)

type restoreTarget struct {
	Entry      backup.ManifestEntry
	TargetPath string
}

type restoreTargetPlan struct {
	SourcePath string
	TargetPath string
	Targets    []restoreTarget
}

func (d *Daemon) resolveRestoreTarget(requestedPath string, toDir string, snapshotSelector string) (restoreTargetPlan, error) {
	m, err := d.loadManifestForRestore(snapshotSelector)
	if err != nil {
		return restoreTargetPlan{}, fmt.Errorf("%w: load manifest: %v", errRestoreManifestLoad, err)
	}

	selection, err := backup.ResolveRestoreSelection(m, requestedPath)
	if err != nil {
		return restoreTargetPlan{}, fmt.Errorf("%w: %v", errRestorePathLookup, err)
	}

	targetPath, err := resolvedRestorePath(selection.SourcePath, toDir)
	if err != nil {
		return restoreTargetPlan{}, fmt.Errorf("%w: %v", errRestoreTargetInvalid, err)
	}

	targets := make([]restoreTarget, 0, len(selection.Entries))
	for _, entry := range selection.Entries {
		entryTargetPath, err := resolvedRestorePath(entry.Path, toDir)
		if err != nil {
			return restoreTargetPlan{}, fmt.Errorf("%w: %v", errRestoreTargetInvalid, err)
		}
		targets = append(targets, restoreTarget{
			Entry:      entry,
			TargetPath: entryTargetPath,
		})
	}

	return restoreTargetPlan{
		SourcePath: selection.SourcePath,
		TargetPath: targetPath,
		Targets:    targets,
	}, nil
}

func (d *Daemon) writeRestoreError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, errRestoreManifestLoad):
		d.writeError(w, http.StatusBadRequest, "manifest_load_failed", err.Error())
	case errors.Is(err, errRestorePathLookup):
		d.writeError(w, http.StatusBadRequest, "path_lookup_failed", err.Error())
	case errors.Is(err, errRestoreTargetInvalid):
		d.writeError(w, http.StatusBadRequest, "invalid_restore_target", err.Error())
	default:
		d.writeError(w, http.StatusBadRequest, "restore_failed", err.Error())
	}
}

func filterRestorePaths(entries []backup.ManifestEntry, prefix string, contains string) []string {
	cleanPrefix := filepath.Clean(strings.TrimSpace(prefix))
	if cleanPrefix == "." {
		cleanPrefix = ""
	}
	contains = strings.TrimSpace(contains)

	paths := make([]string, 0, len(entries))
	for _, entry := range entries {
		path := entry.Path
		if !backup.PathHasPrefix(path, cleanPrefix) {
			continue
		}
		if contains != "" && !strings.Contains(path, contains) {
			continue
		}
		paths = append(paths, path)
	}
	return paths
}

func filterRestoreChildrenPaths(entries []backup.ManifestEntry, prefix string, contains string) []string {
	cleanPrefix := filepath.Clean(strings.TrimSpace(prefix))
	if cleanPrefix == "." {
		cleanPrefix = ""
	}
	contains = strings.TrimSpace(contains)

	children := make(map[string]bool)
	for _, entry := range entries {
		path := filepath.Clean(entry.Path)
		if path == "." {
			continue
		}
		if cleanPrefix != "" && !pathHasPrefix(path, cleanPrefix) {
			continue
		}
		if contains != "" && !strings.Contains(entry.Path, contains) {
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

func pathHasPrefix(path string, prefix string) bool {
	return backup.PathHasPrefix(path, prefix)
}

func immediateRestoreChild(path string, prefix string) (string, bool, bool) {
	if prefix != "" {
		relPath, err := filepath.Rel(prefix, path)
		if err != nil || relPath == "." || relPath == "" {
			return "", false, false
		}
		if relPath == ".." || strings.HasPrefix(relPath, ".."+string(filepath.Separator)) {
			return "", false, false
		}

		parts := strings.Split(relPath, string(filepath.Separator))
		if len(parts) == 0 || parts[0] == "" {
			return "", false, false
		}
		childPath := filepath.Clean(filepath.Join(prefix, parts[0]))
		return childPath, len(parts) > 1, true
	}

	isAbsolute := filepath.IsAbs(path)
	trimmed := strings.TrimPrefix(path, string(filepath.Separator))
	if trimmed == "" {
		return "", false, false
	}

	first, rest, _ := strings.Cut(trimmed, string(filepath.Separator))
	if first == "" {
		return "", false, false
	}
	childPath := first
	if isAbsolute {
		childPath = string(filepath.Separator) + first
	}
	return childPath, rest != "", true
}

func resolvedRestorePath(sourcePath string, toDir string) (string, error) {
	if strings.TrimSpace(toDir) == "" {
		return sourcePath, nil
	}

	cleanToDir := filepath.Clean(toDir)
	cleanSource := filepath.Clean(sourcePath)
	if cleanSource == "." || cleanSource == "" {
		return "", errors.New("invalid restore source path")
	}

	relSource := cleanSource
	if filepath.IsAbs(cleanSource) {
		relSource = strings.TrimPrefix(cleanSource, string(filepath.Separator))
	}
	if relSource == "" || relSource == "." {
		return "", errors.New("invalid restore source path")
	}
	if relSource == ".." || strings.HasPrefix(relSource, ".."+string(filepath.Separator)) {
		return "", errors.New("restore path escapes destination root")
	}

	targetPath := filepath.Join(cleanToDir, relSource)
	targetPath = filepath.Clean(targetPath)

	relToRoot, err := filepath.Rel(cleanToDir, targetPath)
	if err != nil {
		return "", err
	}
	if relToRoot == ".." || strings.HasPrefix(relToRoot, ".."+string(filepath.Separator)) {
		return "", errors.New("restore path escapes destination root")
	}

	return targetPath, nil
}

func (d *Daemon) loadManifestForRestore(snapshotSelector string) (*backup.Manifest, error) {
	manifestPath, err := state.ManifestPath()
	if err != nil {
		return nil, err
	}
	snapshotDir, err := state.ManifestSnapshotsDir()
	if err != nil {
		return nil, err
	}
	return backup.LoadManifestForRestore(manifestPath, snapshotDir, snapshotSelector)
}

func classifyRestoreReadObjectError(entryPath string, err error) (int, string, string) {
	switch {
	case storage.IsNotFound(err):
		return http.StatusNotFound, "restore_object_missing", fmt.Sprintf("restore object missing for path %s", entryPath)
	case storage.IsTransient(err):
		return http.StatusServiceUnavailable, "restore_storage_transient", fmt.Sprintf("transient storage read failure for %s: %v", entryPath, err)
	default:
		return http.StatusBadRequest, "read_object_failed", fmt.Sprintf("read object: %v", err)
	}
}
