package backup

import (
	"errors"
	"io/fs"
	"path/filepath"
	"sort"
)

// SkippedFile is a path a backup run left out because it could not be read.
type SkippedFile struct {
	Path   string `json:"path"`
	Reason string `json:"reason"`
}

func skipReason(err error) string {
	var pathErr *fs.PathError
	if errors.As(err, &pathErr) && pathErr.Err != nil {
		return pathErr.Err.Error()
	}
	return err.Error()
}

func sortedSkippedFiles(skipped []SkippedFile) []SkippedFile {
	if len(skipped) == 0 {
		return nil
	}
	sort.SliceStable(skipped, func(i, j int) bool {
		return skipped[i].Path < skipped[j].Path
	})
	unique := skipped[:1]
	for _, file := range skipped[1:] {
		if file.Path != unique[len(unique)-1].Path {
			unique = append(unique, file)
		}
	}
	return unique
}

// carryForwardSkipped keeps the previous manifest's entries for paths the scan
// could not read, so a skipped file or folder stays restorable from its last
// good backup instead of looking deleted.
func carryForwardSkipped(previous, current *Manifest, skipped []SkippedFile, opts BuildOptions) {
	if previous == nil || current == nil || len(skipped) == 0 {
		return
	}
	unreadable := make(map[string]struct{}, len(skipped))
	for _, file := range skipped {
		unreadable[file.Path] = struct{}{}
	}
	scanned := make(map[string]struct{}, len(current.Entries))
	for _, entry := range current.Entries {
		scanned[entry.Path] = struct{}{}
	}
	matcher := newExclusionMatcher(opts)

	carried := false
	for _, entry := range previous.Entries {
		path := filepath.Clean(entry.Path)
		if _, ok := scanned[path]; ok {
			continue
		}
		if !underUnreadablePath(path, unreadable) || matcher.isExcluded(path) {
			continue
		}
		current.Entries = append(current.Entries, entry)
		carried = true
	}
	if carried {
		sort.Slice(current.Entries, func(i, j int) bool {
			return current.Entries[i].Path < current.Entries[j].Path
		})
	}
}

func underUnreadablePath(path string, unreadable map[string]struct{}) bool {
	for {
		if _, ok := unreadable[path]; ok {
			return true
		}
		parent := filepath.Dir(path)
		if parent == path {
			return false
		}
		path = parent
	}
}
