package backup

import (
	"path/filepath"
	"reflect"
	"testing"
)

func TestPlanChangesDetectsNewChangedRemoved(t *testing.T) {
	prev := &Manifest{Entries: []ManifestEntry{
		{Path: "/a.txt", Size: 10, SHA256: "old-a"},
		{Path: "/b.txt", Size: 20, SHA256: "same-b"},
		{Path: "/gone.txt", Size: 30, SHA256: "old-gone"},
	}}
	curr := &Manifest{Entries: []ManifestEntry{
		{Path: "/a.txt", Size: 11, SHA256: "new-a"},
		{Path: "/b.txt", Size: 20, SHA256: "same-b"},
		{Path: "/new.txt", Size: 1, SHA256: "new-file"},
	}}

	plan := PlanChanges(prev, curr)

	gotChanged := []string{plan.NewOrChanged[0].Path, plan.NewOrChanged[1].Path}
	wantChanged := []string{"/a.txt", "/new.txt"}
	if !reflect.DeepEqual(gotChanged, wantChanged) {
		t.Fatalf("new/changed mismatch: got %v want %v", gotChanged, wantChanged)
	}

	wantRemoved := []string{"/gone.txt"}
	if !reflect.DeepEqual(plan.RemovedPaths, wantRemoved) {
		t.Fatalf("removed mismatch: got %v want %v", plan.RemovedPaths, wantRemoved)
	}
}

func TestFindEntryByPathCleansInput(t *testing.T) {
	entry := ManifestEntry{Path: filepath.Clean("/tmp/test/file.txt"), SHA256: "x"}
	m := &Manifest{Entries: []ManifestEntry{entry}}

	got, err := FindEntryByPath(m, "/tmp/test/./file.txt")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.Path != entry.Path {
		t.Fatalf("path mismatch: got %s want %s", got.Path, entry.Path)
	}
}
