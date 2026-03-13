package recoverycache

import (
	"os"
	"path/filepath"
	"slices"
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

	trackingStore := newTrackingStore(store)
	manifest, err := LoadManifest(cfg, trackingStore, "", func() (string, error) {
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
	if got := trackingStore.remoteManifestGetCount(); got != 1 {
		t.Fatalf("expected 1 remote manifest fetch, got %d", got)
	}
	if trackingStore.listKeysCalls != 0 || len(trackingStore.listPrefixCalls) != 0 {
		t.Fatalf("expected no remote key listings, got list=%d prefix=%v", trackingStore.listKeysCalls, trackingStore.listPrefixCalls)
	}
}

func TestLoadManifestHydratesSelectedSnapshotWithoutFullHistory(t *testing.T) {
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
	if err := os.WriteFile(sourcePath, []byte("v3"), 0o600); err != nil {
		t.Fatalf("write source v3: %v", err)
	}
	seedStateBackup(t, cfg, store, passphrase, salt, manifestPath, snapshotDir)

	remoteSnapshots, err := backup.ListSnapshotManifests(snapshotDir)
	if err != nil {
		t.Fatalf("list remote snapshots: %v", err)
	}
	if len(remoteSnapshots) != 3 {
		t.Fatalf("expected 3 remote snapshots, got %d", len(remoteSnapshots))
	}
	selectedSnapshotID := remoteSnapshots[len(remoteSnapshots)-1].ID

	clearLocalRecoveryCache(t)

	trackingStore := newTrackingStore(store)
	manifest, err := LoadManifest(cfg, trackingStore, selectedSnapshotID, func() (string, error) {
		return passphrase, nil
	})
	if err != nil {
		t.Fatalf("load manifest from selected remote snapshot: %v", err)
	}
	if _, err := backup.FindEntryByPath(manifest, sourcePath); err != nil {
		t.Fatalf("selected hydrated manifest missing source path: %v", err)
	}

	localSnapshots, err := backup.ListSnapshotManifests(testManifestSnapshotsDir(t))
	if err != nil {
		t.Fatalf("list hydrated local snapshots: %v", err)
	}
	if len(localSnapshots) != 2 {
		t.Fatalf("expected latest and selected local snapshots, got %d", len(localSnapshots))
	}
	if !slices.ContainsFunc(localSnapshots, func(snapshot backup.ManifestSnapshot) bool { return snapshot.ID == selectedSnapshotID }) {
		t.Fatalf("expected selected snapshot %q in local cache", selectedSnapshotID)
	}
	if !slices.ContainsFunc(localSnapshots, func(snapshot backup.ManifestSnapshot) bool { return snapshot.ID == remoteSnapshots[0].ID }) {
		t.Fatalf("expected latest snapshot %q in local cache", remoteSnapshots[0].ID)
	}

	selectedLocalManifest, err := backup.LoadManifestForRestore(testManifestPath(t), testManifestSnapshotsDir(t), selectedSnapshotID)
	if err != nil {
		t.Fatalf("load hydrated selected snapshot: %v", err)
	}
	entry, err := backup.FindEntryByPath(selectedLocalManifest, sourcePath)
	if err != nil {
		t.Fatalf("find hydrated selected snapshot entry: %v", err)
	}
	if entry.SHA256 == "" {
		t.Fatal("expected hydrated selected snapshot entry checksum")
	}
	if got := trackingStore.remoteManifestGetCount(); got != 2 {
		t.Fatalf("expected 2 remote manifest fetches, got %d", got)
	}
	if trackingStore.listKeysCalls != 0 || len(trackingStore.listPrefixCalls) != 0 {
		t.Fatalf("expected no remote key listings, got list=%d prefix=%v", trackingStore.listKeysCalls, trackingStore.listPrefixCalls)
	}
}

type trackingStore struct {
	inner           storage.ObjectStore
	getKeys         []string
	listKeysCalls   int
	listPrefixCalls []string
}

func newTrackingStore(inner storage.ObjectStore) *trackingStore {
	return &trackingStore{inner: inner}
}

func (s *trackingStore) PutObject(key string, data []byte) error {
	return s.inner.PutObject(key, data)
}

func (s *trackingStore) GetObject(key string) ([]byte, error) {
	s.getKeys = append(s.getKeys, key)
	return s.inner.GetObject(key)
}

func (s *trackingStore) DeleteObject(key string) error {
	return s.inner.DeleteObject(key)
}

func (s *trackingStore) ListKeys() ([]string, error) {
	s.listKeysCalls++
	return s.inner.ListKeys()
}

func (s *trackingStore) ListKeysWithPrefix(prefix string) ([]string, error) {
	s.listPrefixCalls = append(s.listPrefixCalls, prefix)
	if lister, ok := s.inner.(storage.PrefixKeyLister); ok {
		return lister.ListKeysWithPrefix(prefix)
	}
	return s.inner.ListKeys()
}

func (s *trackingStore) remoteManifestGetCount() int {
	count := 0
	for _, key := range s.getKeys {
		if _, ok := backup.RemoteSnapshotManifestIDFromObjectKey(key); ok {
			count++
		}
	}
	return count
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
