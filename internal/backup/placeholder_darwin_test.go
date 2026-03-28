//go:build darwin

package backup

import (
	"io/fs"
	"syscall"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

func TestCloudPlaceholderErrorDetectsDatalessFiles(t *testing.T) {
	info := fakeFileInfo{
		name: "placeholder.pdf",
		mode: 0o600,
		sys: &syscall.Stat_t{
			Flags: unix.SF_DATALESS,
		},
	}

	err := cloudPlaceholderError("/tmp/placeholder.pdf", info)
	placeholderErr, ok := err.(*CloudPlaceholderError)
	if !ok {
		t.Fatalf("expected CloudPlaceholderError, got %T", err)
	}
	if placeholderErr.Path != "/tmp/placeholder.pdf" {
		t.Fatalf("unexpected placeholder path: %q", placeholderErr.Path)
	}
}

type fakeFileInfo struct {
	name string
	size int64
	mode fs.FileMode
	sys  any
}

func (f fakeFileInfo) Name() string       { return f.name }
func (f fakeFileInfo) Size() int64        { return f.size }
func (f fakeFileInfo) Mode() fs.FileMode  { return f.mode }
func (f fakeFileInfo) ModTime() time.Time { return time.Time{} }
func (f fakeFileInfo) IsDir() bool        { return f.mode.IsDir() }
func (f fakeFileInfo) Sys() any           { return f.sys }
