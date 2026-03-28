//go:build !darwin

package backup

import "io/fs"

func isCloudPlaceholderFileInfo(info fs.FileInfo) bool {
	return false
}
