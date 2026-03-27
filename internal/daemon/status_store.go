package daemon

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"baxter/internal/backup"
	"baxter/internal/state"
)

func (d *Daemon) persistStatus() {
	if d == nil {
		return
	}

	d.mu.Lock()
	status := d.status
	d.mu.Unlock()

	if err := writeDaemonStatus(status); err != nil {
		fmt.Fprintf(os.Stderr, "persist daemon status: %v\n", err)
	}
}

func (d *Daemon) loadPersistedStatus() {
	status, err := readDaemonStatus()
	if err != nil {
		if !os.IsNotExist(err) {
			return
		}
		status = daemonStatus{}
	}
	changed := false

	if status.State == "" {
		status.State = "idle"
		changed = true
	}
	if status.VerifyState == "" {
		status.VerifyState = "idle"
		changed = true
	}
	if status.State == "running" {
		status.State = "idle"
		changed = true
	}
	if status.BackupProgress != (backupProgressSummary{}) {
		status.BackupProgress = backupProgressSummary{}
		changed = true
	}
	if recovered, ok := recoverLastBackupAt(status.LastBackupAt); ok && !recovered.Equal(status.LastBackupAt) {
		status.LastBackupAt = recovered
		changed = true
	}

	d.mu.Lock()
	d.status = status
	d.running = false
	d.verifyRunning = false
	d.mu.Unlock()

	if changed {
		if err := writeDaemonStatus(status); err != nil {
			fmt.Fprintf(os.Stderr, "persist normalized daemon status: %v\n", err)
		}
	}
}

func readDaemonStatus() (daemonStatus, error) {
	path, err := state.DaemonStatusPath()
	if err != nil {
		return daemonStatus{}, err
	}

	data, err := os.ReadFile(path)
	if err != nil {
		return daemonStatus{}, err
	}

	var status daemonStatus
	if err := json.Unmarshal(data, &status); err != nil {
		return daemonStatus{}, err
	}
	return status, nil
}

func writeDaemonStatus(status daemonStatus) error {
	path, err := state.DaemonStatusPath()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}

	data, err := json.MarshalIndent(status, "", "  ")
	if err != nil {
		return err
	}

	tmpPath := path + ".tmp"
	if err := os.WriteFile(tmpPath, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmpPath, path)
}

func recoverLastBackupAt(current time.Time) (time.Time, bool) {
	latest, ok := latestLocalBackupTime()
	if !ok {
		return current, false
	}
	if current.IsZero() || latest.After(current) {
		return latest, true
	}
	return current, false
}

func latestLocalBackupTime() (time.Time, bool) {
	snapshotDir, err := state.ManifestSnapshotsDir()
	if err != nil {
		return time.Time{}, false
	}
	snapshots, err := backup.ListSnapshotManifests(snapshotDir)
	if err != nil || len(snapshots) == 0 {
		return time.Time{}, false
	}
	return snapshots[0].CreatedAt.UTC(), true
}
