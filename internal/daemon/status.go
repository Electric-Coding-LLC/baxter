package daemon

import (
	"errors"
	"fmt"
	"time"

	"baxter/internal/backup"
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

func (d *Daemon) setNextVerifyAt(next time.Time) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.status.NextVerifyAt = next.UTC()
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

func (d *Daemon) setVerifyResult(result backup.VerifyResult) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.verifyRunning = false
	d.status.VerifyState = "idle"
	d.status.LastVerifyAt = d.now().UTC()
	d.status.LastVerifyError = ""
	d.status.LastVerifyResult = verifyResultSummary{
		Checked:        result.Checked,
		OK:             result.OK,
		Missing:        result.Missing,
		ReadErrors:     result.ReadErrors,
		DecryptErrors:  result.DecryptErrors,
		ChecksumErrors: result.ChecksumErrors,
	}
}

func (d *Daemon) setVerifyFailed(err error, result backup.VerifyResult) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.verifyRunning = false
	d.status.VerifyState = "failed"
	d.status.LastVerifyAt = d.now().UTC()
	d.status.LastVerifyError = err.Error()
	d.status.LastVerifyResult = verifyResultSummary{
		Checked:        result.Checked,
		OK:             result.OK,
		Missing:        result.Missing,
		ReadErrors:     result.ReadErrors,
		DecryptErrors:  result.DecryptErrors,
		ChecksumErrors: result.ChecksumErrors,
	}
}

func verifyFailureError(result backup.VerifyResult) error {
	return fmt.Errorf(
		"verify failed: missing=%d read_errors=%d decrypt_errors=%d checksum_errors=%d",
		result.Missing,
		result.ReadErrors,
		result.DecryptErrors,
		result.ChecksumErrors,
	)
}

func (d *Daemon) notifyScheduleChanged() {
	select {
	case d.scheduleChanged <- struct{}{}:
	default:
	}
	select {
	case d.verifyScheduleChanged <- struct{}{}:
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
		State:       d.status.State,
		LastError:   d.status.LastError,
		VerifyState: d.status.VerifyState,
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
	if !d.status.LastVerifyAt.IsZero() {
		resp.LastVerifyAt = d.status.LastVerifyAt.Format(time.RFC3339)
	}
	if !d.status.NextVerifyAt.IsZero() {
		resp.NextVerifyAt = d.status.NextVerifyAt.Format(time.RFC3339)
	}
	if d.status.LastVerifyError != "" {
		resp.LastVerifyError = d.status.LastVerifyError
	}
	resp.LastVerifyChecked = d.status.LastVerifyResult.Checked
	resp.LastVerifyOK = d.status.LastVerifyResult.OK
	resp.LastVerifyMissing = d.status.LastVerifyResult.Missing
	resp.LastVerifyReadErrors = d.status.LastVerifyResult.ReadErrors
	resp.LastVerifyDecryptErrors = d.status.LastVerifyResult.DecryptErrors
	resp.LastVerifyChecksumErrors = d.status.LastVerifyResult.ChecksumErrors
	return resp
}
