package cli

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"baxter/internal/backup"
	"baxter/internal/config"
	"baxter/internal/crypto"
	"baxter/internal/storage"
)

type restoreDrillFailure struct {
	Path  string `json:"path"`
	Error string `json:"error"`
}

type restoreDrillSummary struct {
	Snapshot       string                `json:"snapshot"`
	Prefix         string                `json:"prefix"`
	CandidateCount int                   `json:"candidate_count"`
	Checked        int                   `json:"checked"`
	Failures       int                   `json:"failures"`
	SampledPaths   []string              `json:"sampled_paths"`
	FailureDetails []restoreDrillFailure `json:"failure_details,omitempty"`
	TempDir        string                `json:"temp_dir"`
	StartedAt      string                `json:"started_at"`
	FinishedAt     string                `json:"finished_at"`
}

func runRestoreDrill(cfg *config.Config, opts restoreDrillOptions) error {
	startedAt := time.Now().UTC()
	manifest, err := loadRestoreManifest(cfg, opts.Snapshot)
	if err != nil {
		return err
	}

	entries := filterManifestEntriesByPrefix(manifest.Entries, opts.Prefix)
	candidateCount := len(entries)
	if opts.Sample > 0 {
		entries = sampleManifestEntries(entries, opts.Sample)
	}
	if opts.Limit > 0 && opts.Limit < len(entries) {
		entries = entries[:opts.Limit]
	}

	store, err := objectStoreFromConfig(cfg)
	if err != nil {
		return err
	}
	keySet, err := accessEncryptionKeys(cfg, store)
	if err != nil {
		return err
	}

	tempDir, err := os.MkdirTemp("", "baxter-restore-drill-*")
	if err != nil {
		return fmt.Errorf("create restore drill temp dir: %w", err)
	}
	defer os.RemoveAll(tempDir)

	failures := make([]restoreDrillFailure, 0)
	sampledPaths := make([]string, 0, len(entries))
	for _, entry := range entries {
		sampledPaths = append(sampledPaths, entry.Path)
		if err := runRestoreDrillEntry(tempDir, entry, keySet.candidates, store); err != nil {
			failures = append(failures, restoreDrillFailure{
				Path:  entry.Path,
				Error: err.Error(),
			})
		}
	}

	summary := restoreDrillSummary{
		Snapshot:       opts.Snapshot,
		Prefix:         opts.Prefix,
		CandidateCount: candidateCount,
		Checked:        len(entries),
		Failures:       len(failures),
		SampledPaths:   sampledPaths,
		FailureDetails: failures,
		TempDir:        tempDir,
		StartedAt:      startedAt.Format(time.RFC3339),
		FinishedAt:     time.Now().UTC().Format(time.RFC3339),
	}
	encoded, err := json.Marshal(summary)
	if err != nil {
		return fmt.Errorf("encode restore drill summary: %w", err)
	}
	fmt.Println(string(encoded))

	if len(failures) > 0 {
		return fmt.Errorf("restore drill failed: failures=%d checked=%d", len(failures), len(entries))
	}
	return nil
}

func runRestoreDrillEntry(tempDir string, entry backup.ManifestEntry, decryptionKeys [][]byte, store storage.ObjectStore) error {
	targetPath, err := resolvedRestorePath(entry.Path, tempDir)
	if err != nil {
		return fmt.Errorf("resolve target: %w", err)
	}

	payload, err := store.GetObject(backup.ResolveObjectKey(entry))
	if err != nil {
		return fmt.Errorf("read object: %w", err)
	}

	plain, err := crypto.DecryptBytesWithAnyKey(decryptionKeys, payload)
	if err != nil {
		return fmt.Errorf("decrypt object: %w", err)
	}
	if err := backup.VerifyEntryContent(entry, plain); err != nil {
		return fmt.Errorf("verify content: %w", err)
	}

	if err := os.MkdirAll(filepath.Dir(targetPath), 0o755); err != nil {
		return fmt.Errorf("create target dir: %w", err)
	}
	if err := os.WriteFile(targetPath, plain, entry.Mode.Perm()); err != nil {
		return fmt.Errorf("write target: %w", err)
	}

	restored, err := os.ReadFile(targetPath)
	if err != nil {
		return fmt.Errorf("read restored target: %w", err)
	}
	if err := backup.VerifyEntryContent(entry, restored); err != nil {
		return fmt.Errorf("verify restored target: %w", err)
	}
	return nil
}
