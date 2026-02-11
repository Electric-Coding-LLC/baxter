package daemon

import (
	"errors"
	"fmt"
	"net/http"
	"path/filepath"
	"strings"

	"baxter/internal/backup"
	"baxter/internal/state"
)

var (
	errRestoreManifestLoad  = errors.New("manifest load failed")
	errRestorePathLookup    = errors.New("path lookup failed")
	errRestoreTargetInvalid = errors.New("invalid restore target")
)

func (d *Daemon) resolveRestoreTarget(requestedPath string, toDir string, snapshotSelector string) (backup.ManifestEntry, string, error) {
	m, err := d.loadManifestForRestore(snapshotSelector)
	if err != nil {
		return backup.ManifestEntry{}, "", fmt.Errorf("%w: load manifest: %v", errRestoreManifestLoad, err)
	}

	entry, err := backup.FindEntryByPath(m, requestedPath)
	if err != nil {
		absPath, absErr := filepath.Abs(requestedPath)
		if absErr != nil {
			return backup.ManifestEntry{}, "", fmt.Errorf("%w: %v", errRestorePathLookup, err)
		}
		entry, err = backup.FindEntryByPath(m, absPath)
		if err != nil {
			return backup.ManifestEntry{}, "", fmt.Errorf("%w: %v", errRestorePathLookup, err)
		}
	}

	targetPath, err := resolvedRestorePath(entry.Path, toDir)
	if err != nil {
		return backup.ManifestEntry{}, "", fmt.Errorf("%w: %v", errRestoreTargetInvalid, err)
	}
	return entry, targetPath, nil
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
		if cleanPrefix != "" && !strings.HasPrefix(filepath.Clean(path), cleanPrefix) {
			continue
		}
		if contains != "" && !strings.Contains(path, contains) {
			continue
		}
		paths = append(paths, path)
	}
	return paths
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
