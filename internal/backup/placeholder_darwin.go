//go:build darwin

package backup

import (
	"io/fs"
	"syscall"

	"golang.org/x/sys/unix"
)

func isCloudPlaceholderFileInfo(info fs.FileInfo) bool {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat == nil {
		return false
	}
	return stat.Flags&unix.SF_DATALESS != 0
}
