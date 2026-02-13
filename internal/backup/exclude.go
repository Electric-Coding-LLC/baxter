package backup

import (
	"path/filepath"
	"strings"
)

type BuildOptions struct {
	ExcludePaths []string
	ExcludeGlobs []string
}

type exclusionMatcher struct {
	exactPaths map[string]struct{}
	pathRoots  []string
	globs      []string
}

func newExclusionMatcher(opts BuildOptions) exclusionMatcher {
	exact := make(map[string]struct{}, len(opts.ExcludePaths))
	pathRoots := make([]string, 0, len(opts.ExcludePaths))
	for _, path := range opts.ExcludePaths {
		clean := filepath.Clean(strings.TrimSpace(path))
		if clean == "" || clean == "." {
			continue
		}
		if _, exists := exact[clean]; exists {
			continue
		}
		exact[clean] = struct{}{}
		pathRoots = append(pathRoots, clean)
	}

	globs := make([]string, 0, len(opts.ExcludeGlobs))
	seenGlobs := make(map[string]struct{}, len(opts.ExcludeGlobs))
	for _, pattern := range opts.ExcludeGlobs {
		clean := strings.TrimSpace(pattern)
		if clean == "" {
			continue
		}
		if _, exists := seenGlobs[clean]; exists {
			continue
		}
		seenGlobs[clean] = struct{}{}
		globs = append(globs, clean)
	}

	return exclusionMatcher{
		exactPaths: exact,
		pathRoots:  pathRoots,
		globs:      globs,
	}
}

func (m exclusionMatcher) isExcluded(path string) bool {
	clean := filepath.Clean(path)
	if _, exists := m.exactPaths[clean]; exists {
		return true
	}
	for _, root := range m.pathRoots {
		if hasPathPrefix(clean, root) {
			return true
		}
	}

	if len(m.globs) == 0 {
		return false
	}
	base := filepath.Base(clean)
	slashPath := filepath.ToSlash(clean)
	for _, pattern := range m.globs {
		if matched, _ := filepath.Match(pattern, base); matched {
			return true
		}
		if matched, _ := filepath.Match(filepath.ToSlash(pattern), slashPath); matched {
			return true
		}
	}
	return false
}

func hasPathPrefix(path string, root string) bool {
	if path == root {
		return true
	}
	prefix := root
	if !strings.HasSuffix(prefix, string(filepath.Separator)) {
		prefix += string(filepath.Separator)
	}
	return strings.HasPrefix(path, prefix)
}
