package cli

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"baxter/internal/backup"
	"baxter/internal/config"
	"baxter/internal/state"
)

type restoreDrillSummaryPayload struct {
	Checked      int      `json:"checked"`
	Failures     int      `json:"failures"`
	SampledPaths []string `json:"sampled_paths"`
}

func TestRunRestoreDrillSuccess(t *testing.T) {
	homeDir := t.TempDir()
	srcRoot := filepath.Join(t.TempDir(), "src")
	if err := os.MkdirAll(srcRoot, 0o755); err != nil {
		t.Fatalf("mkdir src root: %v", err)
	}
	sourcePath := filepath.Join(srcRoot, "doc.txt")
	if err := os.WriteFile(sourcePath, []byte("restore drill payload"), 0o600); err != nil {
		t.Fatalf("write source file: %v", err)
	}

	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)
	t.Setenv(passphraseEnv, "test-passphrase")

	cfg := config.DefaultConfig()
	cfg.BackupRoots = []string{srcRoot}
	cfg.Schedule = "manual"

	if err := runBackup(cfg); err != nil {
		t.Fatalf("run backup failed: %v", err)
	}

	out, err := captureStdout(t, func() error {
		return runRestoreDrill(cfg, restoreDrillOptions{Sample: 1})
	})
	if err != nil {
		t.Fatalf("run restore drill failed: %v", err)
	}

	var payload restoreDrillSummaryPayload
	if err := json.Unmarshal([]byte(out), &payload); err != nil {
		t.Fatalf("decode restore drill summary: %v output=%q", err, out)
	}
	if payload.Checked != 1 || payload.Failures != 0 {
		t.Fatalf("unexpected restore drill summary: %+v", payload)
	}
	if len(payload.SampledPaths) != 1 || payload.SampledPaths[0] != sourcePath {
		t.Fatalf("unexpected sampled paths: %+v", payload.SampledPaths)
	}
}

func TestRunRestoreDrillReturnsErrorWhenSampleFails(t *testing.T) {
	homeDir := t.TempDir()
	srcRoot := filepath.Join(t.TempDir(), "src")
	if err := os.MkdirAll(srcRoot, 0o755); err != nil {
		t.Fatalf("mkdir src root: %v", err)
	}
	sourcePath := filepath.Join(srcRoot, "doc.txt")
	if err := os.WriteFile(sourcePath, []byte("restore drill payload"), 0o600); err != nil {
		t.Fatalf("write source file: %v", err)
	}

	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)
	t.Setenv(passphraseEnv, "test-passphrase")

	cfg := config.DefaultConfig()
	cfg.BackupRoots = []string{srcRoot}
	cfg.Schedule = "manual"

	if err := runBackup(cfg); err != nil {
		t.Fatalf("run backup failed: %v", err)
	}

	store, err := objectStoreFromConfig(cfg)
	if err != nil {
		t.Fatalf("object store: %v", err)
	}
	manifestPath, err := state.ManifestPath()
	if err != nil {
		t.Fatalf("manifest path: %v", err)
	}
	manifest, err := backup.LoadManifest(manifestPath)
	if err != nil {
		t.Fatalf("load manifest: %v", err)
	}
	entry, err := backup.FindEntryByPath(manifest, sourcePath)
	if err != nil {
		t.Fatalf("find manifest entry: %v", err)
	}
	if err := store.DeleteObject(backup.ResolveObjectKey(entry)); err != nil {
		t.Fatalf("delete object: %v", err)
	}

	out, err := captureStdout(t, func() error {
		return runRestoreDrill(cfg, restoreDrillOptions{Sample: 1})
	})
	if err == nil {
		t.Fatal("expected restore drill to fail")
	}

	var payload restoreDrillSummaryPayload
	if err := json.Unmarshal([]byte(out), &payload); err != nil {
		t.Fatalf("decode restore drill summary: %v output=%q", err, out)
	}
	if payload.Checked != 1 || payload.Failures != 1 {
		t.Fatalf("unexpected restore drill failure summary: %+v", payload)
	}
}
