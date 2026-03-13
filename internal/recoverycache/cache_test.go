package recoverycache

import (
	"os"
	"path/filepath"
	"testing"

	"baxter/internal/backup"
	"baxter/internal/config"
	"baxter/internal/crypto"
	"baxter/internal/recovery"
	"baxter/internal/state"
	"baxter/internal/storage"
)

func TestLoadManifestFallsBackToRemoteAndHydratesLocalCache(t *testing.T) {
	setRecoveryCacheHome(t)

	srcRoot := filepath.Join(t.TempDir(), "src")
	sourcePath := filepath.Join(srcRoot, "doc.txt")
	if err := os.MkdirAll(srcRoot, 0o755); err != nil {
		t.Fatalf("mkdir src root: %v", err)
	}
	if err := os.WriteFile(sourcePath, []byte("remote fallback"), 0o600); err != nil {
		t.Fatalf("write source file: %v", err)
	}

	cfg := config.DefaultConfig()
	cfg.BackupRoots = []string{srcRoot}
	cfg.Schedule = "manual"

	passphrase := "recovery-fallback-passphrase"
	salt, err := crypto.NewKDFSalt()
	if err != nil {
		t.Fatalf("generate salt: %v", err)
	}
	store := testRecoveryCacheStore(t)
	seedStateBackup(t, cfg, store, passphrase, salt, testManifestPath(t), testManifestSnapshotsDir(t))
	clearLocalRecoveryCache(t)

	manifest, err := LoadManifest(cfg, store, "", func() (string, error) {
		return passphrase, nil
	})
	if err != nil {
		t.Fatalf("load manifest with remote fallback: %v", err)
	}

	if _, err := backup.FindEntryByPath(manifest, sourcePath); err != nil {
		t.Fatalf("remote fallback manifest missing source path: %v", err)
	}
	if _, err := os.Stat(testManifestPath(t)); err != nil {
		t.Fatalf("stat rebuilt manifest cache: %v", err)
	}
	snapshots, err := backup.ListSnapshotManifests(testManifestSnapshotsDir(t))
	if err != nil {
		t.Fatalf("list rebuilt snapshots: %v", err)
	}
	if len(snapshots) != 1 {
		t.Fatalf("expected 1 rebuilt snapshot, got %d", len(snapshots))
	}
	rebuiltSalt, err := os.ReadFile(testKDFSaltPath(t))
	if err != nil {
		t.Fatalf("read rebuilt kdf salt: %v", err)
	}
	if err := crypto.ValidateKDFSalt(rebuiltSalt); err != nil {
		t.Fatalf("validate rebuilt kdf salt: %v", err)
	}
}

func TestLoadManifestRefreshesStaleLatestCache(t *testing.T) {
	setRecoveryCacheHome(t)

	srcRoot := filepath.Join(t.TempDir(), "src")
	sourcePath := filepath.Join(srcRoot, "doc.txt")
	if err := os.MkdirAll(srcRoot, 0o755); err != nil {
		t.Fatalf("mkdir src root: %v", err)
	}
	if err := os.WriteFile(sourcePath, []byte("v1"), 0o600); err != nil {
		t.Fatalf("write source v1: %v", err)
	}

	cfg := config.DefaultConfig()
	cfg.BackupRoots = []string{srcRoot}
	cfg.Schedule = "manual"

	passphrase := "stale-cache-passphrase"
	salt, err := crypto.NewKDFSalt()
	if err != nil {
		t.Fatalf("generate salt: %v", err)
	}
	store := testRecoveryCacheStore(t)
	seedStateBackup(t, cfg, store, passphrase, salt, testManifestPath(t), testManifestSnapshotsDir(t))

	localSnapshots, err := backup.ListSnapshotManifests(testManifestSnapshotsDir(t))
	if err != nil {
		t.Fatalf("list local snapshots: %v", err)
	}
	if len(localSnapshots) != 1 {
		t.Fatalf("expected 1 local snapshot, got %d", len(localSnapshots))
	}
	staleSnapshotID := localSnapshots[0].ID

	if err := os.WriteFile(sourcePath, []byte("v2"), 0o600); err != nil {
		t.Fatalf("write source v2: %v", err)
	}
	remoteManifestPath := filepath.Join(t.TempDir(), "remote-manifest.json")
	remoteSnapshotDir := filepath.Join(t.TempDir(), "remote-manifests")
	seedStateBackup(t, cfg, store, passphrase, salt, remoteManifestPath, remoteSnapshotDir)

	metadata, err := recovery.ReadMetadata(store)
	if err != nil {
		t.Fatalf("read recovery metadata: %v", err)
	}
	if metadata.LatestSnapshotID == staleSnapshotID {
		t.Fatalf("expected remote latest snapshot id to move beyond %q", staleSnapshotID)
	}

	manifest, err := LoadManifest(cfg, store, "", func() (string, error) {
		return passphrase, nil
	})
	if err != nil {
		t.Fatalf("load manifest after remote refresh: %v", err)
	}
	if _, err := backup.FindEntryByPath(manifest, sourcePath); err != nil {
		t.Fatalf("refreshed manifest missing source path: %v", err)
	}

	refreshedSnapshots, err := backup.ListSnapshotManifests(testManifestSnapshotsDir(t))
	if err != nil {
		t.Fatalf("list refreshed snapshots: %v", err)
	}
	if len(refreshedSnapshots) == 0 {
		t.Fatal("expected refreshed local snapshots")
	}
	if refreshedSnapshots[0].ID != metadata.LatestSnapshotID {
		t.Fatalf("unexpected refreshed latest snapshot: got %q want %q", refreshedSnapshots[0].ID, metadata.LatestSnapshotID)
	}
}

func TestLoadManifestHydratesRemoteSnapshotHistory(t *testing.T) {
	setRecoveryCacheHome(t)

	srcRoot := filepath.Join(t.TempDir(), "src")
	sourcePath := filepath.Join(srcRoot, "doc.txt")
	if err := os.MkdirAll(srcRoot, 0o755); err != nil {
		t.Fatalf("mkdir src root: %v", err)
	}
	if err := os.WriteFile(sourcePath, []byte("v1"), 0o600); err != nil {
		t.Fatalf("write source v1: %v", err)
	}

	cfg := config.DefaultConfig()
	cfg.BackupRoots = []string{srcRoot}
	cfg.Schedule = "manual"

	passphrase := "snapshot-history-passphrase"
	salt, err := crypto.NewKDFSalt()
	if err != nil {
		t.Fatalf("generate salt: %v", err)
	}
	store := testRecoveryCacheStore(t)
	manifestPath := filepath.Join(t.TempDir(), "remote-manifest.json")
	snapshotDir := filepath.Join(t.TempDir(), "remote-manifests")
	seedStateBackup(t, cfg, store, passphrase, salt, manifestPath, snapshotDir)

	if err := os.WriteFile(sourcePath, []byte("v2"), 0o600); err != nil {
		t.Fatalf("write source v2: %v", err)
	}
	seedStateBackup(t, cfg, store, passphrase, salt, manifestPath, snapshotDir)

	remoteSnapshots, err := backup.ListSnapshotManifests(snapshotDir)
	if err != nil {
		t.Fatalf("list remote snapshots: %v", err)
	}
	if len(remoteSnapshots) != 2 {
		t.Fatalf("expected 2 remote snapshots, got %d", len(remoteSnapshots))
	}

	clearLocalRecoveryCache(t)

	manifest, err := LoadManifest(cfg, store, "", func() (string, error) {
		return passphrase, nil
	})
	if err != nil {
		t.Fatalf("load manifest from remote history: %v", err)
	}
	if _, err := backup.FindEntryByPath(manifest, sourcePath); err != nil {
		t.Fatalf("latest hydrated manifest missing source path: %v", err)
	}

	localSnapshots, err := backup.ListSnapshotManifests(testManifestSnapshotsDir(t))
	if err != nil {
		t.Fatalf("list hydrated local snapshots: %v", err)
	}
	if len(localSnapshots) != len(remoteSnapshots) {
		t.Fatalf("expected %d hydrated local snapshots, got %d", len(remoteSnapshots), len(localSnapshots))
	}

	oldestRemoteSnapshotID := remoteSnapshots[len(remoteSnapshots)-1].ID
	oldestLocalManifest, err := backup.LoadManifestForRestore(testManifestPath(t), testManifestSnapshotsDir(t), oldestRemoteSnapshotID)
	if err != nil {
		t.Fatalf("load hydrated older snapshot: %v", err)
	}
	entry, err := backup.FindEntryByPath(oldestLocalManifest, sourcePath)
	if err != nil {
		t.Fatalf("find hydrated older snapshot entry: %v", err)
	}
	if entry.SHA256 == "" {
		t.Fatal("expected hydrated older snapshot entry checksum")
	}
}

func seedStateBackup(t *testing.T, cfg *config.Config, store storage.ObjectStore, passphrase string, salt []byte, manifestPath string, snapshotDir string) {
	t.Helper()

	if _, err := backup.Run(cfg, backup.RunOptions{
		ManifestPath:      manifestPath,
		SnapshotDir:       snapshotDir,
		SnapshotRetention: 30,
		EncryptionKey:     crypto.KeyFromPassphraseWithSalt(passphrase, salt),
		KDFSalt:           salt,
		BackupSetID:       recovery.BackupSetID(cfg),
		Store:             store,
	}); err != nil {
		t.Fatalf("run backup: %v", err)
	}
}

func clearLocalRecoveryCache(t *testing.T) {
	t.Helper()

	if err := os.Remove(testManifestPath(t)); err != nil && !os.IsNotExist(err) {
		t.Fatalf("remove manifest cache: %v", err)
	}
	if err := os.RemoveAll(testManifestSnapshotsDir(t)); err != nil {
		t.Fatalf("remove snapshot cache: %v", err)
	}
	if err := os.Remove(testKDFSaltPath(t)); err != nil && !os.IsNotExist(err) {
		t.Fatalf("remove kdf salt cache: %v", err)
	}
}

func testRecoveryCacheStore(t *testing.T) storage.ObjectStore {
	t.Helper()

	objectsDir, err := state.ObjectStoreDir()
	if err != nil {
		t.Fatalf("object store dir: %v", err)
	}
	return storage.NewLocalClient(objectsDir)
}

func setRecoveryCacheHome(t *testing.T) {
	t.Helper()

	homeDir := t.TempDir()
	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)
}

func testManifestPath(t *testing.T) string {
	t.Helper()

	path, err := state.ManifestPath()
	if err != nil {
		t.Fatalf("manifest path: %v", err)
	}
	return path
}

func testManifestSnapshotsDir(t *testing.T) string {
	t.Helper()

	path, err := state.ManifestSnapshotsDir()
	if err != nil {
		t.Fatalf("manifest snapshots dir: %v", err)
	}
	return path
}

func testKDFSaltPath(t *testing.T) string {
	t.Helper()

	path, err := state.KDFSaltPath()
	if err != nil {
		t.Fatalf("kdf salt path: %v", err)
	}
	return path
}
