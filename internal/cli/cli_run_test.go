package cli

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"baxter/internal/backup"
	"baxter/internal/config"
	"baxter/internal/crypto"
	"baxter/internal/recovery"
	"baxter/internal/state"
	"baxter/internal/storage"
)

func TestRunRequiresCommand(t *testing.T) {
	setCLIHome(t)

	err := Run(nil)
	if err == nil {
		t.Fatal("expected usage error for missing command")
	}
	if !strings.Contains(err.Error(), "usage: baxter") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestRunRejectsUnknownCommands(t *testing.T) {
	setCLIHome(t)

	tests := []struct {
		name string
		args []string
		want string
	}{
		{name: "unknown top-level", args: []string{"nope"}, want: "usage: baxter"},
		{name: "missing backup subcommand", args: []string{"backup"}, want: "missing backup subcommand"},
		{name: "unknown backup subcommand", args: []string{"backup", "nope"}, want: "unknown backup subcommand"},
		{name: "missing recovery subcommand", args: []string{"recovery"}, want: "missing recovery subcommand"},
		{name: "unknown recovery subcommand", args: []string{"recovery", "nope"}, want: "unknown recovery subcommand"},
		{name: "unknown snapshot subcommand", args: []string{"snapshot", "nope"}, want: "unknown snapshot subcommand"},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			err := Run(tc.args)
			if err == nil {
				t.Fatalf("expected error for args=%v", tc.args)
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("unexpected error for args=%v: got %q want substring %q", tc.args, err.Error(), tc.want)
			}
		})
	}
}

func TestRunBackupStatusPrintsManifestObjectAndSnapshotCounts(t *testing.T) {
	setCLIHome(t)

	manifestPath, err := state.ManifestPath()
	if err != nil {
		t.Fatalf("manifest path: %v", err)
	}
	snapshotDir, err := state.ManifestSnapshotsDir()
	if err != nil {
		t.Fatalf("snapshot dir: %v", err)
	}

	createdAt := time.Date(2026, time.February, 13, 12, 30, 0, 0, time.UTC)
	entryPath := "/Users/me/Documents/report.txt"
	manifest := &backup.Manifest{
		CreatedAt: createdAt,
		Entries: []backup.ManifestEntry{{
			Path: entryPath,
		}},
	}
	if err := backup.SaveManifest(manifestPath, manifest); err != nil {
		t.Fatalf("save manifest: %v", err)
	}

	if _, err := backup.SaveSnapshotManifest(snapshotDir, &backup.Manifest{CreatedAt: createdAt.Add(-time.Hour), Entries: manifest.Entries}); err != nil {
		t.Fatalf("save older snapshot: %v", err)
	}
	latestSnapshot, err := backup.SaveSnapshotManifest(snapshotDir, &backup.Manifest{CreatedAt: createdAt, Entries: manifest.Entries})
	if err != nil {
		t.Fatalf("save latest snapshot: %v", err)
	}

	cfg := config.DefaultConfig()
	store, err := objectStoreFromConfig(cfg)
	if err != nil {
		t.Fatalf("object store: %v", err)
	}
	if err := store.PutObject(backup.ObjectKeyForPath(entryPath), []byte("payload")); err != nil {
		t.Fatalf("put object: %v", err)
	}

	out, err := captureStdout(t, func() error {
		return Run([]string{"backup", "status"})
	})
	if err != nil {
		t.Fatalf("run backup status: %v", err)
	}

	if !strings.Contains(out, "manifest entries=1") {
		t.Fatalf("status output missing manifest count: %q", out)
	}
	if !strings.Contains(out, "objects=1") {
		t.Fatalf("status output missing object count: %q", out)
	}
	if !strings.Contains(out, "snapshots=2") {
		t.Fatalf("status output missing snapshot count: %q", out)
	}
	if !strings.Contains(out, "latest_snapshot="+latestSnapshot.ID) {
		t.Fatalf("status output missing latest snapshot id: %q", out)
	}
	if !strings.Contains(out, "created_at="+createdAt.Format("2006-01-02 15:04:05Z07:00")) {
		t.Fatalf("status output missing created_at: %q", out)
	}
}

func TestRunBackupRejectsMissingRecoveryMetadataForExistingLocalState(t *testing.T) {
	setCLIHome(t)
	t.Setenv(passphraseEnv, "backup-passphrase")

	srcRoot := filepath.Join(t.TempDir(), "src")
	if err := os.MkdirAll(srcRoot, 0o755); err != nil {
		t.Fatalf("mkdir src root: %v", err)
	}
	if err := os.WriteFile(filepath.Join(srcRoot, "doc.txt"), []byte("payload"), 0o600); err != nil {
		t.Fatalf("write source file: %v", err)
	}

	cfg := config.DefaultConfig()
	cfg.BackupRoots = []string{srcRoot}
	cfg.Schedule = "manual"

	if _, err := encryptionKey(cfg); err != nil {
		t.Fatalf("seed local kdf state: %v", err)
	}

	err := runBackup(cfg)
	if err == nil {
		t.Fatal("expected backup to fail without recovery metadata")
	}
	if !strings.Contains(err.Error(), "recovery metadata not found for existing backup set") {
		t.Fatalf("unexpected backup error: %v", err)
	}
}

func TestRunBackupMigratesLegacyBackupSetWithoutReupload(t *testing.T) {
	setCLIHome(t)
	t.Setenv(passphraseEnv, "legacy-passphrase")

	srcRoot := filepath.Join(t.TempDir(), "src")
	restoreRoot := filepath.Join(t.TempDir(), "restore")
	if err := os.MkdirAll(srcRoot, 0o755); err != nil {
		t.Fatalf("mkdir src root: %v", err)
	}
	sourcePath := filepath.Join(srcRoot, "doc.txt")
	sourceBody := []byte("legacy payload")
	if err := os.WriteFile(sourcePath, sourceBody, 0o600); err != nil {
		t.Fatalf("write source file: %v", err)
	}

	cfg := config.DefaultConfig()
	cfg.BackupRoots = []string{srcRoot}
	cfg.Schedule = "manual"

	manifestPath, err := state.ManifestPath()
	if err != nil {
		t.Fatalf("manifest path: %v", err)
	}
	snapshotDir, err := state.ManifestSnapshotsDir()
	if err != nil {
		t.Fatalf("snapshot dir: %v", err)
	}
	store, err := objectStoreFromConfig(cfg)
	if err != nil {
		t.Fatalf("object store: %v", err)
	}

	salt, initialDataKeys := seedLegacyBackupSet(t, cfg, store, manifestPath, snapshotDir, "legacy-passphrase")

	out, err := captureStdout(t, func() error {
		return runBackup(cfg)
	})
	if err != nil {
		t.Fatalf("run backup: %v", err)
	}
	if !strings.Contains(out, "uploaded=0") {
		t.Fatalf("expected no object reupload, output=%q", out)
	}

	metadata, err := recovery.ReadMetadata(store)
	if err != nil {
		t.Fatalf("read recovery metadata: %v", err)
	}
	if metadata.WrappedMasterKey == "" {
		t.Fatal("expected wrapped master key after migration")
	}
	metadataSalt, err := metadata.KDFSalt()
	if err != nil {
		t.Fatalf("metadata salt: %v", err)
	}
	if !bytes.Equal(metadataSalt, salt) {
		t.Fatal("expected migration to preserve local kdf salt")
	}

	keys, err := store.ListKeys()
	if err != nil {
		t.Fatalf("list keys: %v", err)
	}
	dataKeys := backup.FilterDataObjectKeys(keys)
	if len(dataKeys) != len(initialDataKeys) {
		t.Fatalf("unexpected data object count after migration: got %d want %d", len(dataKeys), len(initialDataKeys))
	}

	clearCLIRecoveryCache(t)

	if _, err := bootstrapRecoveryCache(cfg, store); err != nil {
		t.Fatalf("bootstrap recovery cache: %v", err)
	}
	if err := restorePath(cfg, sourcePath, restoreOptions{ToDir: restoreRoot}); err != nil {
		t.Fatalf("restore migrated legacy object: %v", err)
	}

	trimmedSource := strings.TrimPrefix(filepath.Clean(sourcePath), string(filepath.Separator))
	restoredPath := filepath.Join(restoreRoot, trimmedSource)
	restoredBody, err := os.ReadFile(restoredPath)
	if err != nil {
		t.Fatalf("read restored file: %v", err)
	}
	if !bytes.Equal(restoredBody, sourceBody) {
		t.Fatalf("restored body mismatch: got %q want %q", string(restoredBody), string(sourceBody))
	}
}

func TestRunSnapshotListRespectsLimitAndSortOrder(t *testing.T) {
	setCLIHome(t)

	snapshotDir, err := state.ManifestSnapshotsDir()
	if err != nil {
		t.Fatalf("snapshot dir: %v", err)
	}

	oldest, err := backup.SaveSnapshotManifest(snapshotDir, &backup.Manifest{
		CreatedAt: time.Date(2026, time.February, 10, 9, 0, 0, 0, time.UTC),
		Entries:   []backup.ManifestEntry{},
	})
	if err != nil {
		t.Fatalf("save oldest snapshot: %v", err)
	}
	middle, err := backup.SaveSnapshotManifest(snapshotDir, &backup.Manifest{
		CreatedAt: time.Date(2026, time.February, 11, 9, 0, 0, 0, time.UTC),
		Entries:   []backup.ManifestEntry{},
	})
	if err != nil {
		t.Fatalf("save middle snapshot: %v", err)
	}
	newest, err := backup.SaveSnapshotManifest(snapshotDir, &backup.Manifest{
		CreatedAt: time.Date(2026, time.February, 12, 9, 0, 0, 0, time.UTC),
		Entries:   []backup.ManifestEntry{},
	})
	if err != nil {
		t.Fatalf("save newest snapshot: %v", err)
	}

	out, err := captureStdout(t, func() error {
		return Run([]string{"snapshot", "list", "--limit", "2"})
	})
	if err != nil {
		t.Fatalf("run snapshot list: %v", err)
	}

	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) != 2 {
		t.Fatalf("expected 2 lines from snapshot list, got %d output=%q", len(lines), out)
	}
	if !strings.HasPrefix(lines[0], newest.ID+" ") {
		t.Fatalf("expected newest snapshot first, got %q", lines[0])
	}
	if !strings.HasPrefix(lines[1], middle.ID+" ") {
		t.Fatalf("expected middle snapshot second, got %q", lines[1])
	}
	if strings.Contains(out, oldest.ID) {
		t.Fatalf("did not expect oldest snapshot due to limit, output=%q", out)
	}
}

func setCLIHome(t *testing.T) {
	t.Helper()

	homeDir := t.TempDir()
	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)
}

func clearCLIRecoveryCache(t *testing.T) {
	t.Helper()

	manifestPath, err := state.ManifestPath()
	if err != nil {
		t.Fatalf("manifest path: %v", err)
	}
	if err := os.Remove(manifestPath); err != nil && !os.IsNotExist(err) {
		t.Fatalf("remove manifest cache: %v", err)
	}

	snapshotDir, err := state.ManifestSnapshotsDir()
	if err != nil {
		t.Fatalf("snapshot dir: %v", err)
	}
	if err := os.RemoveAll(snapshotDir); err != nil {
		t.Fatalf("remove snapshot cache: %v", err)
	}

	saltPath, err := state.KDFSaltPath()
	if err != nil {
		t.Fatalf("kdf salt path: %v", err)
	}
	if err := os.Remove(saltPath); err != nil && !os.IsNotExist(err) {
		t.Fatalf("remove kdf salt: %v", err)
	}
}

func seedLegacyBackupSet(t *testing.T, cfg *config.Config, store storage.ObjectStore, manifestPath string, snapshotDir string, passphrase string) ([]byte, []string) {
	t.Helper()

	salt, err := crypto.NewKDFSalt()
	if err != nil {
		t.Fatalf("generate salt: %v", err)
	}
	if err := persistKDFSalt(salt); err != nil {
		t.Fatalf("persist local salt: %v", err)
	}

	manifest, err := backup.BuildManifest(cfg.BackupRoots)
	if err != nil {
		t.Fatalf("build manifest: %v", err)
	}
	backup.AssignObjectKeys(&backup.Manifest{Entries: []backup.ManifestEntry{}}, manifest)
	key := crypto.KeyFromPassphraseWithSalt(passphrase, salt)

	for _, entry := range manifest.Entries {
		plain, err := os.ReadFile(entry.Path)
		if err != nil {
			t.Fatalf("read source file: %v", err)
		}
		encrypted, err := crypto.EncryptBytes(key, plain)
		if err != nil {
			t.Fatalf("encrypt legacy object: %v", err)
		}
		if err := store.PutObject(backup.ResolveObjectKey(entry), encrypted); err != nil {
			t.Fatalf("put legacy object: %v", err)
		}
	}

	if err := backup.SaveManifest(manifestPath, manifest); err != nil {
		t.Fatalf("save legacy manifest: %v", err)
	}
	if _, err := backup.SaveSnapshotManifest(snapshotDir, manifest); err != nil {
		t.Fatalf("save legacy snapshot: %v", err)
	}

	keys, err := store.ListKeys()
	if err != nil {
		t.Fatalf("list legacy keys: %v", err)
	}
	return salt, backup.FilterDataObjectKeys(keys)
}
