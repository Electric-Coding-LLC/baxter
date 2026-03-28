package backup

import (
	"fmt"
	"io/fs"
	"os"
)

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
	if info == nil || !isCloudPlaceholderFileInfo(info) {
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
