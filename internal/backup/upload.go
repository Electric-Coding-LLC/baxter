package backup

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"

	"baxter/internal/crypto"
	"baxter/internal/storage"
)

// uploadOutcome describes how the upload pass differed from the scan.
type uploadOutcome struct {
	// stored counts the objects written.
	stored int
	// vanished paths were deleted before they could be read.
	vanished []string
	// skipped paths could not be read.
	skipped []SkippedFile
	// replaced entries changed after the scan and describe the content stored.
	replaced []ManifestEntry
}

func (o uploadOutcome) changesManifest() bool {
	return len(o.vanished) > 0 || len(o.skipped) > 0 || len(o.replaced) > 0
}

// applyTo makes current reference only content that is stored: vanished paths
// are dropped, skipped paths fall back to their previous entry, and replaced
// paths describe what was read.
func (o uploadOutcome) applyTo(previous, current *Manifest) {
	drop := make(map[string]bool, len(o.vanished)+len(o.skipped))
	for _, path := range o.vanished {
		drop[path] = true
	}
	substitute := make(map[string]ManifestEntry, len(o.skipped)+len(o.replaced))
	if len(o.skipped) > 0 {
		lastGood := make(map[string]ManifestEntry, len(previous.Entries))
		for _, entry := range previous.Entries {
			lastGood[filepath.Clean(entry.Path)] = entry
		}
		for _, file := range o.skipped {
			if entry, ok := lastGood[file.Path]; ok {
				substitute[file.Path] = entry
			} else {
				drop[file.Path] = true
			}
		}
	}
	for _, entry := range o.replaced {
		substitute[entry.Path] = entry
	}

	kept := current.Entries[:0]
	for _, entry := range current.Entries {
		if drop[entry.Path] {
			continue
		}
		if replacement, ok := substitute[entry.Path]; ok {
			entry = replacement
		}
		kept = append(kept, entry)
	}
	current.Entries = kept
}

type uploader struct {
	opts    RunOptions
	mu      sync.Mutex
	outcome uploadOutcome
}

// uploadChangedEntries stores one object per distinct object key. A source
// that cannot be read is recorded and left out; only encryption and storage
// failures fail the run.
func uploadChangedEntries(entries []ManifestEntry, opts RunOptions) (uploadOutcome, error) {
	uploadable := make([][]ManifestEntry, 0, len(entries))
	jobIndex := make(map[string]int, len(entries))
	for _, entry := range entries {
		if !entry.HasStoredContent() {
			continue
		}
		if i, ok := jobIndex[entry.ObjectKey]; ok {
			uploadable[i] = append(uploadable[i], entry)
			continue
		}
		jobIndex[entry.ObjectKey] = len(uploadable)
		uploadable = append(uploadable, []ManifestEntry{entry})
	}

	total := len(uploadable)
	if opts.Progress != nil {
		opts.Progress(ProgressUpdate{Total: total})
	}
	if total == 0 {
		return uploadOutcome{}, nil
	}

	jobs := make(chan []ManifestEntry)
	errCh := make(chan error, 1)
	var progressed atomic.Int32
	var once sync.Once
	u := &uploader{opts: opts}
	workerCount := opts.effectiveUploadConcurrency()
	if workerCount > total {
		workerCount = total
	}

	var wg sync.WaitGroup
	for i := 0; i < workerCount; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for job := range jobs {
				path, err := u.storeJob(job)
				if err != nil {
					once.Do(func() { errCh <- err })
					return
				}
				if path != "" && opts.Progress != nil {
					opts.Progress(ProgressUpdate{
						Uploaded: int(progressed.Add(1)),
						Total:    total,
						Path:     path,
					})
				}
			}
		}()
	}

	for _, job := range uploadable {
		select {
		case err := <-errCh:
			close(jobs)
			wg.Wait()
			return uploadOutcome{}, err
		case jobs <- job:
		}
	}
	close(jobs)
	wg.Wait()

	select {
	case err := <-errCh:
		return uploadOutcome{}, err
	default:
	}

	if done := int(progressed.Load()); done != total && opts.Progress != nil {
		opts.Progress(ProgressUpdate{Uploaded: done, Total: done})
	}
	return u.outcome, nil
}

// storeJob stores the content shared by entries from the first source that
// still holds it, and returns the last path it stored content for.
func (u *uploader) storeJob(entries []ManifestEntry) (string, error) {
	storedPath := ""
	for _, entry := range entries {
		plain, actual, err := readEntryContent(entry)
		switch {
		case err == nil && actual.SHA256 == entry.SHA256 && actual.Size == entry.Size:
			if err := u.put(entry, plain); err != nil {
				return "", err
			}
			return entry.Path, nil
		case err == nil:
			// A live source can be rewritten between scanning and uploading.
			// Store what was read and record it, so the snapshot still
			// references exactly the content that was stored.
			if err := u.put(actual, plain); err != nil {
				return "", err
			}
			storedPath = actual.Path
			u.record(func(o *uploadOutcome) { o.replaced = append(o.replaced, actual) })
		case errors.Is(err, os.ErrNotExist):
			// A live source can be deleted between scanning and uploading.
			u.record(func(o *uploadOutcome) { o.vanished = append(o.vanished, entry.Path) })
		default:
			skipped := SkippedFile{Path: entry.Path, Reason: skipReason(err)}
			u.record(func(o *uploadOutcome) { o.skipped = append(o.skipped, skipped) })
		}
	}
	return storedPath, nil
}

func (u *uploader) record(update func(*uploadOutcome)) {
	u.mu.Lock()
	defer u.mu.Unlock()
	update(&u.outcome)
}

func (u *uploader) put(entry ManifestEntry, plain []byte) error {
	encrypted, err := crypto.EncryptBytes(u.opts.EncryptionKey, plain)
	if err != nil {
		return fmt.Errorf("encrypt file %s: %w", entry.Path, err)
	}
	if err := putObjectWithRetry(u.opts.Store, entry.ObjectKey, encrypted, u.opts.effectiveUploadMaxAttempts()); err != nil {
		return fmt.Errorf("store object %s: %w", entry.Path, err)
	}
	u.record(func(o *uploadOutcome) { o.stored++ })
	return nil
}

func putObjectWithRetry(store storage.ObjectStore, key string, data []byte, maxAttempts int) error {
	if maxAttempts <= 0 {
		maxAttempts = 1
	}

	var lastErr error
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		if err := store.PutObject(key, data); err == nil {
			return nil
		} else {
			lastErr = err
		}
	}
	return lastErr
}

// readEntryContent reads the entry's source and returns the entry describing
// what was read, which differs from entry when the source changed after it was
// scanned.
func readEntryContent(entry ManifestEntry) ([]byte, ManifestEntry, error) {
	if err := cloudPlaceholderRestoreError(entry); err != nil {
		return nil, ManifestEntry{}, err
	}
	if err := cloudPlaceholderErrorForPath(entry.Path); err != nil {
		return nil, ManifestEntry{}, err
	}
	plain, err := os.ReadFile(entry.Path)
	if err != nil {
		if placeholderErr := cloudPlaceholderErrorForPath(entry.Path); placeholderErr != nil {
			return nil, ManifestEntry{}, placeholderErr
		}
		return nil, ManifestEntry{}, fmt.Errorf("read file %s: %w", entry.Path, err)
	}
	sum := sha256.Sum256(plain)
	hash := hex.EncodeToString(sum[:])
	if int64(len(plain)) == entry.Size && hash == entry.SHA256 {
		return plain, entry, nil
	}

	actual := entry
	actual.Size = int64(len(plain))
	actual.SHA256 = hash
	actual.ObjectKey = ObjectKeyForContentSHA256(hash)
	if info, err := os.Stat(entry.Path); err == nil {
		actual.Mode = info.Mode()
		actual.ModTime = info.ModTime().UTC()
	}
	return plain, actual, nil
}
