package backup

import (
	"os"
	"path/filepath"
	"sync"
	"testing"
)

func skipIfPermissionsNotEnforced(t *testing.T) {
	t.Helper()
	if os.Geteuid() == 0 {
		t.Skip("file permissions are not enforced for root")
	}
}

func makeUnreadable(t *testing.T, path string) {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(path, info.Mode().Perm()) })
}

func manifestEntryContent(t *testing.T, opts RunOptions, path string) (string, bool) {
	t.Helper()
	manifest, err := LoadManifest(opts.ManifestPath)
	if err != nil {
		t.Fatal(err)
	}
	entry, err := FindEntryByPath(manifest, path)
	if err != nil {
		return "", false
	}
	verified, err := VerifyManifestEntries([]ManifestEntry{entry}, opts.EncryptionKey, opts.Store)
	if err != nil || verified.HasFailures() {
		t.Fatalf("entry %s must be restorable: %+v, %v", path, verified, err)
	}
	return entry.SHA256, true
}

func TestRunSkipsUnreadableFileAndBacksUpTheRest(t *testing.T) {
	skipIfPermissionsNotEnforced(t)
	root, cfg, opts, _ := newDedupRun(t)
	locked := filepath.Join(root, "locked.db")
	writeDedupFile(t, locked, "locked")
	writeDedupFile(t, filepath.Join(root, "document.txt"), "keep me")
	makeUnreadable(t, locked)

	result, err := Run(cfg, opts)
	if err != nil {
		t.Fatalf("one unreadable file must not fail the backup: %v", err)
	}
	if result.Uploaded != 1 || result.Total != 1 {
		t.Fatalf("unexpected result: %+v", result)
	}
	if len(result.Skipped) != 1 || result.Skipped[0].Path != locked || result.Skipped[0].Reason == "" {
		t.Fatalf("unreadable file must be reported: %+v", result.Skipped)
	}
	assertLatestManifestVerifies(t, opts, 1)
}

func TestRunKeepsLastGoodBackupOfUnreadablePaths(t *testing.T) {
	skipIfPermissionsNotEnforced(t)
	root, cfg, opts, _ := newDedupRun(t)
	lockedFile := filepath.Join(root, "locked.db")
	lockedDir := filepath.Join(root, "private")
	nested := filepath.Join(lockedDir, "nested", "notes.txt")
	document := filepath.Join(root, "document.txt")
	writeDedupFile(t, lockedFile, "locked v1")
	writeDedupFile(t, nested, "nested v1")
	writeDedupFile(t, document, "document v1")
	if _, err := Run(cfg, opts); err != nil {
		t.Fatal(err)
	}
	lockedSHA, _ := manifestEntryContent(t, opts, lockedFile)
	documentSHA, _ := manifestEntryContent(t, opts, document)

	writeDedupFile(t, lockedFile, "locked v2")
	writeDedupFile(t, document, "document v2")
	makeUnreadable(t, lockedFile)
	makeUnreadable(t, lockedDir)

	result, err := Run(cfg, opts)
	if err != nil {
		t.Fatalf("unreadable paths must not fail the backup: %v", err)
	}
	if result.Uploaded != 1 || result.Total != 3 || result.Removed != 0 {
		t.Fatalf("unexpected result: %+v", result)
	}
	if len(result.Skipped) != 2 || result.Skipped[0].Path != lockedFile || result.Skipped[1].Path != lockedDir {
		t.Fatalf("unreadable paths must be reported: %+v", result.Skipped)
	}
	assertLatestManifestVerifies(t, opts, 3)
	if sha, ok := manifestEntryContent(t, opts, lockedFile); !ok || sha != lockedSHA {
		t.Fatalf("unreadable file must keep its last good backup: %q", sha)
	}
	if _, ok := manifestEntryContent(t, opts, nested); !ok {
		t.Fatal("files under an unreadable folder must keep their last good backup")
	}
	if sha, _ := manifestEntryContent(t, opts, document); sha == documentSHA {
		t.Fatal("readable file must still be backed up")
	}
}

func TestRunSkipsFileThatBecomesUnreadableAfterScan(t *testing.T) {
	skipIfPermissionsNotEnforced(t)
	for _, previouslyBackedUp := range []bool{false, true} {
		name := "new"
		if previouslyBackedUp {
			name = "previously-backed-up"
		}
		t.Run(name, func(t *testing.T) {
			root, cfg, opts, _ := newDedupRun(t)
			locked := filepath.Join(root, "locked.db")
			writeDedupFile(t, locked, "locked v1")
			lockedSHA := ""
			if previouslyBackedUp {
				if _, err := Run(cfg, opts); err != nil {
					t.Fatal(err)
				}
				lockedSHA, _ = manifestEntryContent(t, opts, locked)
			}
			writeDedupFile(t, locked, "locked v2")
			writeDedupFile(t, filepath.Join(root, "document.txt"), "keep me")

			var once sync.Once
			opts.Progress = func(ProgressUpdate) {
				once.Do(func() { makeUnreadable(t, locked) })
			}
			result, err := Run(cfg, opts)
			if err != nil {
				t.Fatalf("a file locked after the scan must not fail the backup: %v", err)
			}
			wantTotal := 1
			if previouslyBackedUp {
				wantTotal = 2
			}
			if result.Uploaded != 1 || result.Total != wantTotal || result.Removed != 0 {
				t.Fatalf("unexpected result: %+v", result)
			}
			if len(result.Skipped) != 1 || result.Skipped[0].Path != locked {
				t.Fatalf("unreadable file must be reported: %+v", result.Skipped)
			}
			assertLatestManifestVerifies(t, opts, wantTotal)
			if sha, ok := manifestEntryContent(t, opts, locked); ok != previouslyBackedUp || sha != lockedSHA {
				t.Fatalf("unexpected entry for unreadable file: %q %v", sha, ok)
			}
		})
	}
}

func TestRunBacksUpFileThatChangesAfterScan(t *testing.T) {
	for _, change := range []string{"longer content", "replaced"} {
		t.Run(change, func(t *testing.T) {
			root, cfg, opts, store := newDedupRun(t)
			live := filepath.Join(root, "live.db")
			writeDedupFile(t, live, "original")
			if _, err := Run(cfg, opts); err != nil {
				t.Fatal(err)
			}
			writeDedupFile(t, live, "modified")
			writeDedupFile(t, filepath.Join(root, "document.txt"), "keep me")
			store.reset()

			var once sync.Once
			opts.Progress = func(ProgressUpdate) {
				once.Do(func() { writeDedupFile(t, live, change) })
			}
			result, err := Run(cfg, opts)
			if err != nil {
				t.Fatalf("a file changing during the backup must not fail it: %v", err)
			}
			if result.Uploaded != 2 || result.Total != 2 || len(result.Skipped) != 0 || store.contentPuts() != 2 {
				t.Fatalf("unexpected result: %+v, puts=%d", result, store.contentPuts())
			}
			assertLatestManifestVerifies(t, opts, 2)
			manifest, err := LoadManifest(opts.ManifestPath)
			if err != nil {
				t.Fatal(err)
			}
			entry, err := FindEntryByPath(manifest, live)
			if err != nil {
				t.Fatal(err)
			}
			if err := VerifyEntryContent(entry, []byte(change)); err != nil || entry.Size != int64(len(change)) {
				t.Fatalf("snapshot must describe the content that was stored: %+v, %v", entry, err)
			}
		})
	}
}

func TestRunStoresSharedContentWhenOneCopyChangesAfterScan(t *testing.T) {
	root, cfg, opts, _ := newDedupRun(t)
	first := filepath.Join(root, "a.txt")
	writeDedupFile(t, first, "same content")
	writeDedupFile(t, filepath.Join(root, "b.txt"), "same content")

	var once sync.Once
	opts.Progress = func(ProgressUpdate) {
		once.Do(func() { writeDedupFile(t, first, "different now") })
	}
	result, err := Run(cfg, opts)
	if err != nil {
		t.Fatal(err)
	}
	if result.Uploaded != 2 || result.Total != 2 {
		t.Fatalf("unexpected result: %+v", result)
	}
	assertLatestManifestVerifies(t, opts, 2)
}
