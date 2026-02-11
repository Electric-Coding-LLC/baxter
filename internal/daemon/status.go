package daemon

import (
	"errors"
	"time"

	"baxter/internal/config"
)

func (d *Daemon) setFailed(err error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.running = false
	d.status.State = "failed"
	d.status.LastError = err.Error()
}

func (d *Daemon) setIdleSuccess() {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.running = false
	d.status.State = "idle"
	d.status.LastBackupAt = d.now().UTC()
	d.status.LastError = ""
}

func (d *Daemon) setNextScheduledAt(next time.Time) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.status.NextScheduledAt = next.UTC()
}

func (d *Daemon) setLastError(lastError string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.status.LastError = lastError
}

func (d *Daemon) setLastRestoreError(lastRestoreError string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.status.LastRestoreError = lastRestoreError
}

func (d *Daemon) setRestoreSuccess(restoredPath string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.status.LastRestoreAt = d.now().UTC()
	d.status.LastRestorePath = restoredPath
	d.status.LastRestoreError = ""
}

func (d *Daemon) notifyScheduleChanged() {
	select {
	case d.scheduleChanged <- struct{}{}:
	default:
	}
}

func (d *Daemon) currentConfig() *config.Config {
	d.mu.Lock()
	defer d.mu.Unlock()
	cloned := *d.cfg
	cloned.BackupRoots = append([]string(nil), d.cfg.BackupRoots...)
	return &cloned
}

func (d *Daemon) reloadConfig() (*config.Config, error) {
	d.mu.Lock()
	configPath := d.configPath
	loader := d.configLoader
	d.mu.Unlock()

	if configPath == "" {
		return nil, errors.New("config path is not set")
	}

	cfg, err := loader(configPath)
	if err != nil {
		return nil, err
	}

	d.mu.Lock()
	d.cfg = cfg
	d.mu.Unlock()
	return cfg, nil
}

func (d *Daemon) snapshot() statusResponse {
	d.mu.Lock()
	defer d.mu.Unlock()

	resp := statusResponse{
		State:     d.status.State,
		LastError: d.status.LastError,
	}
	if !d.status.LastBackupAt.IsZero() {
		resp.LastBackupAt = d.status.LastBackupAt.Format(time.RFC3339)
	}
	if !d.status.NextScheduledAt.IsZero() {
		resp.NextScheduledAt = d.status.NextScheduledAt.Format(time.RFC3339)
	}
	if !d.status.LastRestoreAt.IsZero() {
		resp.LastRestoreAt = d.status.LastRestoreAt.Format(time.RFC3339)
	}
	if d.status.LastRestorePath != "" {
		resp.LastRestorePath = d.status.LastRestorePath
	}
	if d.status.LastRestoreError != "" {
		resp.LastRestoreError = d.status.LastRestoreError
	}
	return resp
}
