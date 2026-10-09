package backup

import (
	"bytes"
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"sync"
	"testing"

	"baxter/internal/config"
	"baxter/internal/crypto"
	"baxter/internal/storage"
)

func TestRunOmitsFilesDeletedAfterScan(t *testing.T) {
	for _, previouslyBackedUp := range []bool{false, true} {
		name := "new"
		if previouslyBackedUp {
			name = "previously-backed-up"
		}
		t.Run(name, func(t *testing.T) {
			root := t.TempDir()
			checkpoint := filepath.Join(root, ".git", "refs", "codex", "turn-diffs", "checkpoints", "checkpoint")
			if err := os.MkdirAll(filepath.Dir(checkpoint), 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(checkpoint, []byte("old checkpoint"), 0o600); err != nil {
				t.Fatal(err)
			}
			stateDir := t.TempDir()
			store := storage.NewLocalClient(filepath.Join(stateDir, "objects"))
			opts := RunOptions{
				ManifestPath:  filepath.Join(stateDir, "manifest.json"),
				SnapshotDir:   filepath.Join(stateDir, "manifests"),
				EncryptionKey: []byte("01234567890123456789012345678901"),
				KDFSalt:       testKDFSalt,
				BackupSetID:   "local-test",
				Store:         store,
			}
			cfg := &config.Config{BackupRoots: []string{root}}
			if previouslyBackedUp {
				if _, err := Run(cfg, opts); err != nil {
					t.Fatal(err)
				}
			}
			if err := os.WriteFile(checkpoint, []byte("new checkpoint"), 0o600); err != nil {
				t.Fatal(err)
			}
			kept := filepath.Join(root, "document.txt")
			if err := os.WriteFile(kept, []byte("keep me"), 0o600); err != nil {
				t.Fatal(err)
			}
			var once sync.Once
			var mu sync.Mutex
			var lastProgress ProgressUpdate
			opts.Progress = func(update ProgressUpdate) {
				once.Do(func() {
					// The initial progress callback runs after scanning, before workers start.
					if err := os.Remove(checkpoint); err != nil {
						t.Error(err)
					}
				})
				mu.Lock()
				lastProgress = update
				mu.Unlock()
			}
			result, err := Run(cfg, opts)
			if err != nil {
				t.Fatalf("backup after checkpoint deletion: %v", err)
			}
			wantRemoved := 0
			if previouslyBackedUp {
				wantRemoved = 1
			}
			if result.Uploaded != 1 || result.Total != 1 || result.Removed != wantRemoved {
				t.Fatalf("unexpected result: %+v", result)
			}
			if lastProgress.Uploaded != 1 || lastProgress.Total != 1 {
				t.Fatalf("unexpected final progress: %+v", lastProgress)
			}
			manifest, err := LoadManifest(opts.ManifestPath)
			if err != nil {
				t.Fatal(err)
			}
			if len(manifest.Entries) != 1 || manifest.Entries[0].Path != kept {
				t.Fatalf("unexpected latest manifest: %+v", manifest)
			}
			snapshots, err := ListSnapshotManifests(opts.SnapshotDir)
			if err != nil {
				t.Fatal(err)
			}
			for _, snapshot := range snapshots {
				m, err := LoadManifest(snapshot.Path)
				if err != nil {
					t.Fatal(err)
				}
				verified, err := VerifyManifestEntries(m.Entries, opts.EncryptionKey, store)
				if err != nil || verified.HasFailures() || verified.OK != len(m.Entries) {
					t.Fatalf("snapshot must remain restorable: %+v, %v", verified, err)
				}
				remoteKey, err := RemoteSnapshotManifestObjectKey(snapshot.ID)
				if err != nil {
					t.Fatal(err)
				}
				payload, err := store.GetObject(remoteKey)
				if err != nil {
					t.Fatal(err)
				}
				plain, err := crypto.DecryptBytes(opts.EncryptionKey, payload)
				if err != nil {
					t.Fatal(err)
				}
				var remote Manifest
				if err := json.Unmarshal(plain, &remote); err != nil {
					t.Fatal(err)
				}
				if !reflect.DeepEqual(m, &remote) {
					t.Fatal("local and remote snapshots differ")
				}
			}
		})
	}
}

type missingPutStore struct{ storage.ObjectStore }

func (s missingPutStore) PutObject(string, []byte) error { return os.ErrNotExist }

func TestRunPreservesBackupOnSourceOrStorageFailure(t *testing.T) {
	for _, failure := range []string{"root-deleted", "permission", "size-changed", "checksum-changed", "store-missing"} {
		t.Run(failure, func(t *testing.T) {
			root := t.TempDir()
			path := filepath.Join(root, "document.txt")
			if err := os.WriteFile(path, []byte("original"), 0o600); err != nil {
				t.Fatal(err)
			}
			stateDir := t.TempDir()
			opts := RunOptions{
				ManifestPath:  filepath.Join(stateDir, "manifest.json"),
				SnapshotDir:   filepath.Join(stateDir, "manifests"),
				EncryptionKey: []byte("01234567890123456789012345678901"),
				KDFSalt:       testKDFSalt,
				BackupSetID:   "local-test",
				Store:         storage.NewLocalClient(filepath.Join(stateDir, "objects")),
			}
			cfg := &config.Config{BackupRoots: []string{root}}
			if _, err := Run(cfg, opts); err != nil {
				t.Fatal(err)
			}
			before, err := os.ReadFile(opts.ManifestPath)
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(path, []byte("modified"), 0o600); err != nil {
				t.Fatal(err)
			}
			var once sync.Once
			opts.Progress = func(ProgressUpdate) {
				once.Do(func() {
					var err error
					switch failure {
					case "root-deleted":
						err = os.RemoveAll(root)
					case "permission":
						err = os.Chmod(path, 0)
					case "size-changed":
						err = os.WriteFile(path, []byte("longer content"), 0o600)
					case "checksum-changed":
						err = os.WriteFile(path, []byte("replaced"), 0o600)
					}
					if err != nil {
						t.Error(err)
					}
				})
			}
			if failure == "store-missing" {
				opts.Store = missingPutStore{opts.Store}
			}
			if _, err := Run(cfg, opts); err == nil {
				t.Fatal("expected backup failure")
			} else if failure == "permission" && !errors.Is(err, fs.ErrPermission) {
				t.Fatalf("expected permission failure: %v", err)
			}
			after, err := os.ReadFile(opts.ManifestPath)
			if err != nil || !bytes.Equal(before, after) {
				t.Fatalf("previous manifest changed on failure: %v", err)
			}
			snapshots, err := ListSnapshotManifests(opts.SnapshotDir)
			if err != nil || len(snapshots) != 1 {
				t.Fatalf("unexpected snapshots after failure: %+v, %v", snapshots, err)
			}
		})
	}
}

func TestScanDisappearanceKeepsRootAndReadFailuresFatal(t *testing.T) {
	root := t.TempDir()
	child := filepath.Join(root, "deleted")
	for _, tc := range []struct {
		path   string
		err    error
		ignore bool
	}{
		{child, &fs.PathError{Op: "open", Path: child, Err: fs.ErrNotExist}, true},
		{root, &fs.PathError{Op: "stat", Path: root, Err: fs.ErrNotExist}, false},
		{child, &fs.PathError{Op: "open", Path: child, Err: fs.ErrPermission}, false},
		{child, errors.New("read failed"), false},
	} {
		if got := shouldIgnoreScanError(root, tc.path, tc.err); got != tc.ignore {
			t.Errorf("error %v at %s: ignore=%v, want %v", tc.err, tc.path, got, tc.ignore)
		}
	}
	if _, err := BuildManifest([]string{child}); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("missing configured root must fail: %v", err)
	}
	if _, err := BuildManifestWithOptions([]string{child}, BuildOptions{ExcludePaths: []string{child}}); err != nil {
		t.Fatalf("excluded root should not be required: %v", err)
	}
}
