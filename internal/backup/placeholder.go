package backup

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
)

// CloudOnlySkipReason is the reason reported for files whose content is held
// by a cloud provider and is not downloaded to this Mac.
const CloudOnlySkipReason = "cloud-only file is not downloaded to this Mac"

var isCloudPlaceholder = isCloudPlaceholderFileInfo

type CloudPlaceholderError struct {
	Path string
}

func (e *CloudPlaceholderError) Error() string {
	return fmt.Sprintf("cloud-only file is not downloaded locally: %s", e.Path)
}

type CloudPlaceholderRestoreError struct {
	Path string
}

func (e *CloudPlaceholderRestoreError) Error() string {
	return fmt.Sprintf("restore not available for cloud-only path %s; recover it through its cloud provider", e.Path)
}

func cloudPlaceholderError(path string, info fs.FileInfo) error {
	if info == nil || !isCloudPlaceholder(info) {
		return nil
	}
	return &CloudPlaceholderError{Path: path}
}

func cloudPlaceholderManifestEntry(path string, info fs.FileInfo) (ManifestEntry, bool) {
	if err := cloudPlaceholderError(path, info); err == nil {
		return ManifestEntry{}, false
	}
	return ManifestEntry{
		Path:       path,
		Size:       info.Size(),
		Mode:       info.Mode(),
		ModTime:    info.ModTime().UTC(),
		SourceKind: manifestSourceKindCloudPlaceholder,
	}, true
}

func cloudPlaceholderErrorForPath(path string) error {
	info, err := os.Stat(path)
	if err != nil {
		return nil
	}
	return cloudPlaceholderError(path, info)
}

func cloudPlaceholderRestoreError(entry ManifestEntry) error {
	if !entry.IsCloudPlaceholder() {
		return nil
	}
	return &CloudPlaceholderRestoreError{Path: entry.Path}
}

func CloudPlaceholderRestoreErrorForEntry(entry ManifestEntry) error {
	return cloudPlaceholderRestoreError(entry)
}

// keepLastGoodForCloudPlaceholders keeps the previous manifest's entry for a
// file that was backed up and has since been offloaded to its cloud provider,
// so it stays restorable from its last good backup.
func keepLastGoodForCloudPlaceholders(previous, current *Manifest) {
	if previous == nil || current == nil {
		return
	}
	var lastGood map[string]ManifestEntry
	for i, entry := range current.Entries {
		if !entry.IsCloudPlaceholder() {
			continue
		}
		if lastGood == nil {
			lastGood = make(map[string]ManifestEntry, len(previous.Entries))
			for _, prev := range previous.Entries {
				if prev.HasStoredContent() {
					lastGood[filepath.Clean(prev.Path)] = prev
				}
			}
		}
		if prev, ok := lastGood[entry.Path]; ok {
			current.Entries[i] = prev
		}
	}
}
