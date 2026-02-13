package daemon

import "time"

const DefaultIPCAddress = "127.0.0.1:41820"
const passphraseEnv = "BAXTER_PASSPHRASE"

type daemonStatus struct {
	State            string
	LastBackupAt     time.Time
	NextScheduledAt  time.Time
	LastError        string
	LastRestoreAt    time.Time
	LastRestorePath  string
	LastRestoreError string
	VerifyState      string
	LastVerifyAt     time.Time
	NextVerifyAt     time.Time
	LastVerifyError  string
	LastVerifyResult verifyResultSummary
}

type verifyResultSummary struct {
	Checked        int
	OK             int
	Missing        int
	ReadErrors     int
	DecryptErrors  int
	ChecksumErrors int
}

type statusResponse struct {
	State                    string `json:"state"`
	LastBackupAt             string `json:"last_backup_at,omitempty"`
	NextScheduledAt          string `json:"next_scheduled_at,omitempty"`
	LastError                string `json:"last_error,omitempty"`
	LastRestoreAt            string `json:"last_restore_at,omitempty"`
	LastRestorePath          string `json:"last_restore_path,omitempty"`
	LastRestoreError         string `json:"last_restore_error,omitempty"`
	VerifyState              string `json:"verify_state"`
	LastVerifyAt             string `json:"last_verify_at,omitempty"`
	NextVerifyAt             string `json:"next_verify_at,omitempty"`
	LastVerifyError          string `json:"last_verify_error,omitempty"`
	LastVerifyChecked        int    `json:"last_verify_checked,omitempty"`
	LastVerifyOK             int    `json:"last_verify_ok,omitempty"`
	LastVerifyMissing        int    `json:"last_verify_missing,omitempty"`
	LastVerifyReadErrors     int    `json:"last_verify_read_errors,omitempty"`
	LastVerifyDecryptErrors  int    `json:"last_verify_decrypt_errors,omitempty"`
	LastVerifyChecksumErrors int    `json:"last_verify_checksum_errors,omitempty"`
}

type restoreListResponse struct {
	Paths []string `json:"paths"`
}

type restoreDryRunRequest struct {
	Path      string `json:"path"`
	ToDir     string `json:"to_dir,omitempty"`
	Overwrite bool   `json:"overwrite,omitempty"`
	Snapshot  string `json:"snapshot,omitempty"`
}

type restoreDryRunResponse struct {
	SourcePath string `json:"source_path"`
	TargetPath string `json:"target_path"`
	Overwrite  bool   `json:"overwrite"`
}

type restoreRunRequest struct {
	Path       string `json:"path"`
	ToDir      string `json:"to_dir,omitempty"`
	Overwrite  bool   `json:"overwrite,omitempty"`
	VerifyOnly bool   `json:"verify_only,omitempty"`
	Snapshot   string `json:"snapshot,omitempty"`
}

type restoreRunResponse struct {
	SourcePath string `json:"source_path"`
	TargetPath string `json:"target_path"`
	Verified   bool   `json:"verified"`
	Wrote      bool   `json:"wrote"`
}

type errorResponse struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type scheduleConfig struct {
	Schedule   string
	DailyTime  string
	WeeklyDay  string
	WeeklyTime string
}

type snapshotSummary struct {
	ID        string `json:"id"`
	CreatedAt string `json:"created_at"`
	Entries   int    `json:"entries"`
}

type snapshotsResponse struct {
	Snapshots []snapshotSummary `json:"snapshots"`
}
