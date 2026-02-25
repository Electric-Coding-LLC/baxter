package backup

import (
	"errors"
	"os"
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

func TestPruneSnapshotManifestsWithPolicyMixedRetention(t *testing.T) {
	snapshotDir := filepath.Join(t.TempDir(), "manifests")
	now := time.Date(2026, time.February, 25, 15, 0, 0, 0, time.UTC)

	_ = mustSaveSnapshot(t, snapshotDir, now.AddDate(0, 0, -1))
	_ = mustSaveSnapshot(t, snapshotDir, now.AddDate(0, 0, -2))
	oldButRetainedByCount := mustSaveSnapshot(t, snapshotDir, now.AddDate(0, 0, -45))
	veryOld := mustSaveSnapshot(t, snapshotDir, now.AddDate(0, 0, -70))

	removed, err := PruneSnapshotManifestsWithPolicy(snapshotDir, SnapshotPrunePolicy{
		Retain:     3,
		MaxAgeDays: 30,
		Now:        now,
	})
	if err != nil {
		t.Fatalf("prune snapshots: %v", err)
	}
	if removed != 2 {
		t.Fatalf("unexpected removed count: got %d want 2", removed)
	}

	remaining, err := ListSnapshotManifests(snapshotDir)
	if err != nil {
		t.Fatalf("list snapshots: %v", err)
	}
	if len(remaining) != 2 {
		t.Fatalf("unexpected remaining count: got %d want 2", len(remaining))
	}
	for _, snapshot := range remaining {
		if snapshot.ID == oldButRetainedByCount.ID || snapshot.ID == veryOld.ID {
			t.Fatalf("expected old snapshots to be pruned, remaining=%+v", remaining)
		}
	}
}

func TestPlanSnapshotPruneManifestsWithPolicyBoundaryCutoff(t *testing.T) {
	snapshotDir := filepath.Join(t.TempDir(), "manifests")
	now := time.Date(2026, time.March, 1, 0, 0, 0, 0, time.UTC)

	cutoffAge := now.AddDate(0, 0, -30)
	atCutoff := mustSaveSnapshot(t, snapshotDir, cutoffAge)
	older := mustSaveSnapshot(t, snapshotDir, cutoffAge.Add(-time.Second))

	candidates, err := PlanSnapshotPruneManifestsWithPolicy(snapshotDir, SnapshotPrunePolicy{
		MaxAgeDays: 30,
		Now:        now,
	})
	if err != nil {
		t.Fatalf("plan prune snapshots: %v", err)
	}
	if len(candidates) != 1 {
		t.Fatalf("unexpected candidate count: got %d want 1", len(candidates))
	}
	if candidates[0].ID != older.ID {
		t.Fatalf("unexpected prune candidate: got %s want %s", candidates[0].ID, older.ID)
	}

	// Ensure plan-only mode is non-destructive.
	if _, err := os.Stat(atCutoff.Path); err != nil {
		t.Fatalf("expected snapshot at cutoff to remain on disk: %v", err)
	}
	if _, err := os.Stat(older.Path); err != nil {
		t.Fatalf("expected older snapshot to remain on disk in plan mode: %v", err)
	}
}

func mustSaveSnapshot(t *testing.T, dir string, createdAt time.Time) ManifestSnapshot {
	t.Helper()

	snapshot, err := SaveSnapshotManifest(dir, &Manifest{
		CreatedAt: createdAt,
		Entries:   []ManifestEntry{{Path: createdAt.Format(time.RFC3339)}},
	})
	if err != nil {
		t.Fatalf("save snapshot: %v", err)
	}
	return snapshot
}
