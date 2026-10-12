package backup

import (
	"io/fs"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// offloadFiles makes the backup treat files named *.offloaded as cloud-only
// until the returned function is called.
func offloadFiles(t *testing.T) func() {
	t.Helper()
	var mu sync.Mutex
	offloaded := true
	original := isCloudPlaceholder
	isCloudPlaceholder = func(info fs.FileInfo) bool {
		mu.Lock()
		defer mu.Unlock()
		return offloaded && strings.HasSuffix(info.Name(), ".offloaded")
	}
	t.Cleanup(func() { isCloudPlaceholder = original })
	return func() {
		mu.Lock()
		offloaded = false
		mu.Unlock()
	}
}

func TestRunReportsCloudOnlyFilesAsSkipped(t *testing.T) {
	root, cfg, opts, _ := newDedupRun(t)
	cloudOnly := filepath.Join(root, "scan.pdf.offloaded")
	writeDedupFile(t, cloudOnly, "never downloaded")
	writeDedupFile(t, filepath.Join(root, "document.txt"), "keep me")
	download := offloadFiles(t)

	result, err := Run(cfg, opts)
	if err != nil {
		t.Fatalf("a cloud-only file must not fail the backup: %v", err)
	}
	if result.Uploaded != 1 || result.Total != 2 {
		t.Fatalf("unexpected result: %+v", result)
	}
	if len(result.Skipped) != 1 || result.Skipped[0] != (SkippedFile{Path: cloudOnly, Reason: CloudOnlySkipReason}) {
		t.Fatalf("cloud-only file must be reported: %+v", result.Skipped)
	}
	manifest, err := LoadManifest(opts.ManifestPath)
	if err != nil {
		t.Fatal(err)
	}
	if entry, err := FindEntryByPath(manifest, cloudOnly); err != nil || !entry.IsCloudPlaceholder() {
		t.Fatalf("cloud-only file must stay listed as a placeholder: %+v, %v", entry, err)
	}

	download()
	result, err = Run(cfg, opts)
	if err != nil {
		t.Fatal(err)
	}
	if result.Uploaded != 1 || len(result.Skipped) != 0 {
		t.Fatalf("a downloaded file must be backed up: %+v", result)
	}
	if _, ok := manifestEntryContent(t, opts, cloudOnly); !ok {
		t.Fatal("a downloaded file must be restorable")
	}
}

func TestRunKeepsLastGoodBackupOfOffloadedFile(t *testing.T) {
	root, cfg, opts, store := newDedupRun(t)
	offloaded := filepath.Join(root, "taxes.pdf.offloaded")
	writeDedupFile(t, offloaded, "backed up before offloading")
	if _, err := Run(cfg, opts); err != nil {
		t.Fatal(err)
	}
	backedUpSHA, _ := manifestEntryContent(t, opts, offloaded)
	store.reset()
	offloadFiles(t)

	for run := 0; run < 2; run++ {
		result, err := Run(cfg, opts)
		if err != nil {
			t.Fatal(err)
		}
		if result.Uploaded != 0 || result.Total != 1 || result.Removed != 0 || store.contentPuts() != 0 {
			t.Fatalf("unexpected result: %+v, puts=%d", result, store.contentPuts())
		}
		if len(result.Skipped) != 1 || result.Skipped[0].Path != offloaded || result.Skipped[0].Reason != CloudOnlySkipReason {
			t.Fatalf("offloaded file must be reported: %+v", result.Skipped)
		}
		if sha, ok := manifestEntryContent(t, opts, offloaded); !ok || sha != backedUpSHA {
			t.Fatalf("offloaded file must keep its last good backup: %q", sha)
		}
	}
}

func TestRunSkipsFileOffloadedAfterScan(t *testing.T) {
	root, cfg, opts, _ := newDedupRun(t)
	offloaded := filepath.Join(root, "movie.mov.offloaded")
	writeDedupFile(t, offloaded, "offloaded during the backup")
	writeDedupFile(t, filepath.Join(root, "document.txt"), "keep me")

	original := isCloudPlaceholder
	t.Cleanup(func() { isCloudPlaceholder = original })
	scanned := false
	isCloudPlaceholder = func(info fs.FileInfo) bool {
		if !strings.HasSuffix(info.Name(), ".offloaded") {
			return false
		}
		wasScanned := scanned
		scanned = true
		return wasScanned
	}
	opts.UploadConcurrency = 1

	result, err := Run(cfg, opts)
	if err != nil {
		t.Fatalf("a file offloaded during the backup must not fail it: %v", err)
	}
	if result.Uploaded != 1 || result.Total != 1 {
		t.Fatalf("unexpected result: %+v", result)
	}
	if len(result.Skipped) != 1 || result.Skipped[0] != (SkippedFile{Path: offloaded, Reason: CloudOnlySkipReason}) {
		t.Fatalf("offloaded file must be reported: %+v", result.Skipped)
	}
	assertLatestManifestVerifies(t, opts, 1)
}
