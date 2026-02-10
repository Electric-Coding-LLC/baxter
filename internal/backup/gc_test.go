package backup

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"baxter/internal/storage"
)

func TestGarbageCollectObjectsDryRunAndDelete(t *testing.T) {
	manifestPath := filepath.Join(t.TempDir(), "manifest.json")
	snapshotDir := filepath.Join(t.TempDir(), "manifests")
	objectsDir := filepath.Join(t.TempDir(), "objects")
	store := storage.NewLocalClient(objectsDir)

	referencedPath := "/Users/me/Documents/keep.txt"
	referencedKey := ObjectKeyForPath(referencedPath)
	orphanPath := "/Users/me/Documents/delete.txt"
	orphanKey := ObjectKeyForPath(orphanPath)

	if err := store.PutObject(referencedKey, []byte("keep")); err != nil {
		t.Fatalf("put referenced object: %v", err)
	}
	if err := store.PutObject(orphanKey, []byte("delete")); err != nil {
		t.Fatalf("put orphan object: %v", err)
	}

	if err := SaveManifest(manifestPath, &Manifest{
		CreatedAt: time.Now().UTC(),
		Entries:   []ManifestEntry{{Path: referencedPath}},
	}); err != nil {
		t.Fatalf("save latest manifest: %v", err)
	}
	if _, err := SaveSnapshotManifest(snapshotDir, &Manifest{
		CreatedAt: time.Now().UTC(),
		Entries:   []ManifestEntry{{Path: referencedPath}},
	}); err != nil {
		t.Fatalf("save snapshot manifest: %v", err)
	}

	dryRun, err := GarbageCollectObjects(GCOptions{
		LatestManifestPath: manifestPath,
		SnapshotDir:        snapshotDir,
		Store:              store,
		DryRun:             true,
	})
	if err != nil {
		t.Fatalf("gc dry-run: %v", err)
	}
	if dryRun.CandidateDeletes != 1 || dryRun.DeletedObjects != 0 || !dryRun.DryRun {
		t.Fatalf("unexpected dry-run result: %+v", dryRun)
	}
	keys, err := store.ListKeys()
	if err != nil {
		t.Fatalf("list keys after dry-run: %v", err)
	}
	if len(keys) != 2 {
		t.Fatalf("dry-run should keep all objects, got %d", len(keys))
	}

	result, err := GarbageCollectObjects(GCOptions{
		LatestManifestPath: manifestPath,
		SnapshotDir:        snapshotDir,
		Store:              store,
	})
	if err != nil {
		t.Fatalf("gc delete run: %v", err)
	}
	if result.CandidateDeletes != 1 || result.DeletedObjects != 1 || result.RetainedObjects != 1 {
		t.Fatalf("unexpected delete result: %+v", result)
	}
	if _, err := store.GetObject(orphanKey); !os.IsNotExist(err) {
		t.Fatalf("expected orphan key to be deleted, err=%v", err)
	}
	if _, err := store.GetObject(referencedKey); err != nil {
		t.Fatalf("expected referenced key to remain, err=%v", err)
	}
}

func TestGarbageCollectObjectsSkipsWithoutManifestSources(t *testing.T) {
	manifestPath := filepath.Join(t.TempDir(), "manifest.json")
	snapshotDir := filepath.Join(t.TempDir(), "manifests")
	objectsDir := filepath.Join(t.TempDir(), "objects")
	store := storage.NewLocalClient(objectsDir)

	orphanKey := ObjectKeyForPath("/Users/me/Documents/orphan.txt")
	if err := store.PutObject(orphanKey, []byte("orphan")); err != nil {
		t.Fatalf("put object: %v", err)
	}

	result, err := GarbageCollectObjects(GCOptions{
		LatestManifestPath: manifestPath,
		SnapshotDir:        snapshotDir,
		Store:              store,
	})
	if err != nil {
		t.Fatalf("gc run: %v", err)
	}
	if !result.Skipped || result.DeletedObjects != 0 || result.RetainedObjects != 1 {
		t.Fatalf("unexpected skipped result: %+v", result)
	}
	if _, err := store.GetObject(orphanKey); err != nil {
		t.Fatalf("object should not be deleted when gc is skipped, err=%v", err)
	}
}
