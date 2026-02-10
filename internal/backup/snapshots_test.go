package backup

import (
	"errors"
	"path/filepath"
	"testing"
	"time"
)

func TestLoadManifestForRestoreBySnapshotIDAndTimestamp(t *testing.T) {
	manifestPath := filepath.Join(t.TempDir(), "manifest.json")
	snapshotDir := filepath.Join(t.TempDir(), "manifests")

	latest := &Manifest{
		CreatedAt: time.Date(2026, time.January, 3, 0, 0, 0, 0, time.UTC),
		Entries:   []ManifestEntry{{Path: "/latest.txt"}},
	}
	if err := SaveManifest(manifestPath, latest); err != nil {
		t.Fatalf("save latest manifest: %v", err)
	}

	oldSnapshotManifest := &Manifest{
		CreatedAt: time.Date(2026, time.January, 1, 0, 0, 0, 0, time.UTC),
		Entries:   []ManifestEntry{{Path: "/old.txt"}},
	}
	oldSnapshot, err := SaveSnapshotManifest(snapshotDir, oldSnapshotManifest)
	if err != nil {
		t.Fatalf("save old snapshot: %v", err)
	}

	newSnapshotManifest := &Manifest{
		CreatedAt: time.Date(2026, time.January, 2, 0, 0, 0, 0, time.UTC),
		Entries:   []ManifestEntry{{Path: "/new.txt"}},
	}
	if _, err := SaveSnapshotManifest(snapshotDir, newSnapshotManifest); err != nil {
		t.Fatalf("save new snapshot: %v", err)
	}

	gotLatest, err := LoadManifestForRestore(manifestPath, snapshotDir, "")
	if err != nil {
		t.Fatalf("load latest manifest: %v", err)
	}
	if len(gotLatest.Entries) != 1 || gotLatest.Entries[0].Path != "/latest.txt" {
		t.Fatalf("unexpected latest entries: %#v", gotLatest.Entries)
	}

	gotOldByID, err := LoadManifestForRestore(manifestPath, snapshotDir, oldSnapshot.ID)
	if err != nil {
		t.Fatalf("load old snapshot by id: %v", err)
	}
	if len(gotOldByID.Entries) != 1 || gotOldByID.Entries[0].Path != "/old.txt" {
		t.Fatalf("unexpected old snapshot entries: %#v", gotOldByID.Entries)
	}

	gotByTime, err := LoadManifestForRestore(manifestPath, snapshotDir, "2026-01-01T12:00:00Z")
	if err != nil {
		t.Fatalf("load snapshot by time: %v", err)
	}
	if len(gotByTime.Entries) != 1 || gotByTime.Entries[0].Path != "/old.txt" {
		t.Fatalf("unexpected snapshot-by-time entries: %#v", gotByTime.Entries)
	}
}

func TestLoadManifestForRestoreSnapshotNotFound(t *testing.T) {
	manifestPath := filepath.Join(t.TempDir(), "manifest.json")
	snapshotDir := filepath.Join(t.TempDir(), "manifests")

	if _, err := LoadManifestForRestore(manifestPath, snapshotDir, "missing-snapshot"); !errors.Is(err, ErrSnapshotNotFound) {
		t.Fatalf("expected ErrSnapshotNotFound, got %v", err)
	}
}
