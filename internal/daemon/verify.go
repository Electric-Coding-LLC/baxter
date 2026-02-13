package daemon

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"strings"

	"baxter/internal/backup"
	"baxter/internal/config"
)

var errVerifyAlreadyRunning = errors.New("verify already running")

func (d *Daemon) triggerVerify() error {
	cfg := d.currentConfig()

	d.mu.Lock()
	if d.verifyRunning {
		d.mu.Unlock()
		return errVerifyAlreadyRunning
	}
	d.verifyRunning = true
	d.status.VerifyState = "running"
	d.status.LastVerifyError = ""
	d.mu.Unlock()

	go func() {
		result, err := d.performVerify(context.Background(), cfg)
		if err != nil {
			d.setVerifyFailed(err, result)
			return
		}
		if result.HasFailures() {
			d.setVerifyFailed(verifyFailureError(result), result)
			return
		}
		d.setVerifyResult(result)
	}()

	return nil
}

func (d *Daemon) performVerify(ctx context.Context, cfg *config.Config) (backup.VerifyResult, error) {
	_ = ctx
	manifest, err := d.loadManifestForRestore("")
	if err != nil {
		return backup.VerifyResult{}, fmt.Errorf("load manifest: %w", err)
	}

	entries := filterManifestEntriesByPrefix(manifest.Entries, cfg.Verify.Prefix)
	if cfg.Verify.Sample > 0 {
		entries = sampleManifestEntries(entries, cfg.Verify.Sample)
	}
	if cfg.Verify.Limit > 0 && cfg.Verify.Limit < len(entries) {
		entries = entries[:cfg.Verify.Limit]
	}

	keys, err := encryptionKeys(cfg)
	if err != nil {
		return backup.VerifyResult{}, err
	}
	store, err := d.objectStore(cfg)
	if err != nil {
		return backup.VerifyResult{}, fmt.Errorf("create object store: %w", err)
	}

	result, err := backup.VerifyManifestEntriesWithKeys(entries, keys.candidates, store)
	if err != nil {
		return backup.VerifyResult{}, err
	}
	fmt.Printf(
		"verify complete: checked=%d ok=%d missing=%d read_errors=%d decrypt_errors=%d checksum_errors=%d\n",
		result.Checked,
		result.OK,
		result.Missing,
		result.ReadErrors,
		result.DecryptErrors,
		result.ChecksumErrors,
	)
	return result, nil
}

func filterManifestEntriesByPrefix(entries []backup.ManifestEntry, prefix string) []backup.ManifestEntry {
	cleanPrefix := filepath.Clean(strings.TrimSpace(prefix))
	if cleanPrefix == "." {
		cleanPrefix = ""
	}
	if cleanPrefix == "" {
		return append([]backup.ManifestEntry(nil), entries...)
	}

	filtered := make([]backup.ManifestEntry, 0, len(entries))
	for _, entry := range entries {
		if strings.HasPrefix(filepath.Clean(entry.Path), cleanPrefix) {
			filtered = append(filtered, entry)
		}
	}
	return filtered
}

func sampleManifestEntries(entries []backup.ManifestEntry, sample int) []backup.ManifestEntry {
	if sample <= 0 || sample >= len(entries) {
		return entries
	}
	if sample == 1 {
		return []backup.ManifestEntry{entries[0]}
	}

	out := make([]backup.ManifestEntry, 0, sample)
	last := -1
	step := float64(len(entries)-1) / float64(sample-1)
	for i := 0; i < sample; i++ {
		idx := int(float64(i) * step)
		if idx <= last {
			idx = last + 1
		}
		if idx >= len(entries) {
			idx = len(entries) - 1
		}
		out = append(out, entries[idx])
		last = idx
	}
	return out
}
