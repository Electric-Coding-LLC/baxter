package backup

import (
	"errors"
	"path/filepath"
	"sort"
)

var errRestoreSelectionNotFound = errors.New("path not found in manifest")

type RestoreSelection struct {
	SourcePath  string
	Entries     []ManifestEntry
	IsDirectory bool
}

func ResolveRestoreSelection(m *Manifest, requestedPath string) (RestoreSelection, error) {
	for _, candidate := range restoreLookupCandidates(requestedPath) {
		entry, err := FindEntryByPath(m, candidate)
		if err == nil {
			return RestoreSelection{
				SourcePath: filepath.Clean(entry.Path),
				Entries:    []ManifestEntry{entry},
			}, nil
		}

		entries := findEntriesByPrefix(m, candidate)
		if len(entries) == 0 {
			continue
		}
		return RestoreSelection{
			SourcePath:  filepath.Clean(candidate),
			Entries:     entries,
			IsDirectory: true,
		}, nil
	}

	return RestoreSelection{}, errRestoreSelectionNotFound
}

func restoreLookupCandidates(requestedPath string) []string {
	candidates := make([]string, 0, 2)
	addCandidate := func(path string) {
		cleanPath := filepath.Clean(path)
		for _, existing := range candidates {
			if existing == cleanPath {
				return
			}
		}
		candidates = append(candidates, cleanPath)
	}

	addCandidate(requestedPath)
	if absPath, err := filepath.Abs(requestedPath); err == nil {
		addCandidate(absPath)
	}

	return candidates
}

func findEntriesByPrefix(m *Manifest, prefix string) []ManifestEntry {
	cleanPrefix := filepath.Clean(prefix)
	entries := make([]ManifestEntry, 0)
	for _, entry := range m.Entries {
		if PathHasPrefix(entry.Path, cleanPrefix) {
			entries = append(entries, entry)
		}
	}
	sort.Slice(entries, func(i, j int) bool {
		return entries[i].Path < entries[j].Path
	})
	return entries
}
