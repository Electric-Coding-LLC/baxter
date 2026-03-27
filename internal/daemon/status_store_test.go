package daemon

import (
	"testing"
	"time"

	"baxter/internal/backup"
	"baxter/internal/config"
)

func TestNewLoadsPersistedStatus(t *testing.T) {
	homeDir := t.TempDir()
	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)

	first := New(config.DefaultConfig())
	fixedBackupAt := time.Date(2026, time.March, 25, 21, 12, 0, 0, time.UTC)
	first.clockNow = func() time.Time { return fixedBackupAt }
	first.setIdleSuccess()

	deadline := time.Now().Add(2 * time.Second)
	for {
		second := New(config.DefaultConfig())
		snapshot := second.snapshot()
		if snapshot.LastBackupAt == fixedBackupAt.Format(time.RFC3339) && snapshot.State == "idle" {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("persisted status not loaded, got %+v", snapshot)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestNewLoadsPersistedVerifyStatus(t *testing.T) {
	homeDir := t.TempDir()
	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)

	first := New(config.DefaultConfig())
	verifyAt := time.Date(2026, time.March, 25, 21, 13, 0, 0, time.UTC)
	first.clockNow = func() time.Time { return verifyAt }
	first.setVerifyResult(backup.VerifyResult{
		Checked: 5,
		OK:      5,
	})

	deadline := time.Now().Add(2 * time.Second)
	for {
		second := New(config.DefaultConfig())
		snapshot := second.snapshot()
		if snapshot.VerifyState == "idle" &&
			snapshot.LastVerifyAt == verifyAt.Format(time.RFC3339) &&
			snapshot.LastVerifyChecked == 5 &&
			snapshot.LastVerifyOK == 5 {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("persisted verify status not loaded, got %+v", snapshot)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestNewClearsStaleRunningStateAndProgress(t *testing.T) {
	homeDir := t.TempDir()
	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)

	first := New(config.DefaultConfig())
	first.mu.Lock()
	first.status.State = "running"
	first.status.BackupProgress = backupProgressSummary{
		Uploaded:    42,
		Total:       100,
		CurrentPath: "/tmp/example.txt",
	}
	first.mu.Unlock()
	first.persistStatus()

	second := New(config.DefaultConfig())
	snapshot := second.snapshot()
	if snapshot.State != "idle" {
		t.Fatalf("expected persisted running state to reset to idle, got %q", snapshot.State)
	}
	if snapshot.BackupUploaded != 0 || snapshot.BackupTotal != 0 || snapshot.BackupCurrentPath != "" {
		t.Fatalf("expected persisted progress to be cleared, got %+v", snapshot)
	}
}

func TestNewRecoversLastBackupAtFromLatestSnapshot(t *testing.T) {
	homeDir := t.TempDir()
	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)

	older := time.Date(2026, time.February, 8, 9, 30, 0, 0, time.UTC)
	if err := writeDaemonStatus(daemonStatus{
		State:        "idle",
		VerifyState:  "idle",
		LastBackupAt: older,
	}); err != nil {
		t.Fatalf("seed daemon status: %v", err)
	}

	snapshotDir := testManifestSnapshotsDir(t)
	latest := time.Date(2026, time.March, 27, 2, 44, 6, 626478000, time.UTC)
	if _, err := backup.SaveSnapshotManifest(snapshotDir, &backup.Manifest{
		CreatedAt: latest,
		Entries: []backup.ManifestEntry{
			{Path: "/tmp/example.txt", SHA256: "abc"},
		},
	}); err != nil {
		t.Fatalf("save snapshot manifest: %v", err)
	}

	d := New(config.DefaultConfig())
	snapshot := d.snapshot()
	if snapshot.LastBackupAt != latest.Format(time.RFC3339) {
		t.Fatalf("expected recovered last_backup_at %q, got %+v", latest.Format(time.RFC3339), snapshot)
	}
}

func TestNewDoesNotRecoverLastBackupAtFromManifestWithoutSnapshots(t *testing.T) {
	homeDir := t.TempDir()
	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)

	manifestPath := testManifestPath(t)
	latest := time.Date(2026, time.March, 28, 4, 0, 0, 0, time.UTC)
	if err := backup.SaveManifest(manifestPath, &backup.Manifest{
		CreatedAt: latest,
		Entries: []backup.ManifestEntry{
			{Path: "/tmp/example.txt", SHA256: "abc"},
		},
	}); err != nil {
		t.Fatalf("save manifest: %v", err)
	}

	d := New(config.DefaultConfig())
	snapshot := d.snapshot()
	if snapshot.LastBackupAt != "" {
		t.Fatalf("expected no recovered last_backup_at without snapshots, got %+v", snapshot)
	}
}
