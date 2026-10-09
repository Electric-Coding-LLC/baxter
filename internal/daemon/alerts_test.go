package daemon

import (
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"baxter/internal/backup"
	"baxter/internal/config"
)

type recordedNotifications struct {
	mu     sync.Mutex
	titles []string
	bodies []string
}

func (r *recordedNotifications) record(title string, body string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.titles = append(r.titles, title)
	r.bodies = append(r.bodies, body)
}

func (r *recordedNotifications) count() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.titles)
}

func newAlertTestDaemon(t *testing.T, now *time.Time) (*Daemon, *recordedNotifications) {
	t.Helper()
	homeDir := t.TempDir()
	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)

	d := New(config.DefaultConfig())
	d.clockNow = func() time.Time { return *now }
	notifications := &recordedNotifications{}
	d.notifier = notifications.record
	return d, notifications
}

func TestBackupOverdue(t *testing.T) {
	now := time.Date(2026, time.October, 9, 12, 0, 0, 0, time.UTC)
	for _, tc := range []struct {
		name     string
		last     time.Time
		schedule string
		days     int
		overdue  bool
	}{
		{"never backed up", time.Time{}, "daily", 0, false},
		{"daily recent", now.Add(-47 * time.Hour), "daily", 1, false},
		{"daily overdue", now.Add(-72 * time.Hour), "daily", 3, true},
		{"weekly within two runs", now.Add(-14 * 24 * time.Hour), "weekly", 14, false},
		{"weekly overdue", now.Add(-15 * 24 * time.Hour), "weekly", 15, true},
		{"manual never overdue", now.Add(-90 * 24 * time.Hour), "manual", 90, false},
		{"clock moved back", now.Add(time.Hour), "daily", 0, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			days, overdue := backupOverdue(tc.last, tc.schedule, now)
			if days != tc.days || overdue != tc.overdue {
				t.Fatalf("got days=%d overdue=%v, want days=%d overdue=%v", days, overdue, tc.days, tc.overdue)
			}
		})
	}
}

func TestFailedBackupsAreCountedAndNotified(t *testing.T) {
	now := time.Date(2026, time.October, 9, 22, 0, 0, 0, time.UTC)
	d, notifications := newAlertTestDaemon(t, &now)

	d.setFailed(errors.New("store object: access denied"))
	now = now.Add(24 * time.Hour)
	d.setFailed(errors.New("store object: access denied"))

	status := d.snapshot()
	if status.State != "failed" || status.ConsecutiveFailures != 2 || status.LastFailureAt != now.Format(time.RFC3339) {
		t.Fatalf("unexpected status after failures: %+v", status)
	}
	if notifications.count() != 2 || notifications.titles[0] != "Baxter backup failed" {
		t.Fatalf("each failure must notify when the app is not running: %+v", notifications.titles)
	}

	reloaded := New(config.DefaultConfig())
	if got := reloaded.snapshot().ConsecutiveFailures; got != 2 {
		t.Fatalf("failure count must survive a restart: got %d", got)
	}

	d.setIdleSuccess()
	if got := d.snapshot().ConsecutiveFailures; got != 0 {
		t.Fatalf("a successful backup must reset the failure count: got %d", got)
	}
}

func TestFailedBackupLeavesNotifyingToRunningApp(t *testing.T) {
	now := time.Date(2026, time.October, 9, 22, 0, 0, 0, time.UTC)
	d, notifications := newAlertTestDaemon(t, &now)

	rr := httptest.NewRecorder()
	d.Handler().ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/v1/status", nil))
	if rr.Code != http.StatusOK {
		t.Fatalf("status code: got %d", rr.Code)
	}
	now = now.Add(5 * time.Second)
	d.setFailed(errors.New("boom"))
	if notifications.count() != 0 {
		t.Fatalf("the polling app posts the failure notification: %+v", notifications.titles)
	}

	now = now.Add(appPresenceWindow)
	d.setFailed(errors.New("boom"))
	if notifications.count() != 1 {
		t.Fatalf("the daemon must notify once the app stops polling: %+v", notifications.titles)
	}
}

func TestOverdueBackupAlertsOncePerDay(t *testing.T) {
	now := time.Date(2026, time.October, 9, 9, 0, 0, 0, time.UTC)
	d, notifications := newAlertTestDaemon(t, &now)
	d.setIdleSuccess()

	now = now.Add(2 * 24 * time.Hour)
	d.alertIfBackupOverdue()
	if status := d.snapshot(); notifications.count() != 0 || status.BackupOverdue || status.DaysSinceLastBackup != 2 {
		t.Fatalf("two days without a backup is not overdue: %+v", status)
	}

	now = now.Add(2 * 24 * time.Hour)
	d.alertIfBackupOverdue()
	d.alertIfBackupOverdue()
	status := d.snapshot()
	if !status.BackupOverdue || status.DaysSinceLastBackup != 4 {
		t.Fatalf("status must report the overdue backup: %+v", status)
	}
	if notifications.count() != 1 || notifications.titles[0] != "No Baxter backup in 4 days" {
		t.Fatalf("overdue backup must alert once: %+v", notifications.titles)
	}

	restarted := New(config.DefaultConfig())
	restarted.clockNow = d.clockNow
	restarted.notifier = notifications.record
	restarted.alertIfBackupOverdue()
	if notifications.count() != 1 {
		t.Fatalf("a restart must not repeat the alert: %+v", notifications.titles)
	}

	now = now.Add(overdueAlertInterval)
	d.alertIfBackupOverdue()
	if notifications.count() != 2 || notifications.titles[1] != "No Baxter backup in 5 days" {
		t.Fatalf("overdue backup must alert again the next day: %+v", notifications.titles)
	}

	d.setIdleSuccess()
	now = now.Add(overdueAlertInterval)
	d.alertIfBackupOverdue()
	if status := d.snapshot(); notifications.count() != 2 || status.BackupOverdue {
		t.Fatalf("a successful backup must clear the alert: %+v", status)
	}
}

func TestSkippedFilesAreReportedInStatus(t *testing.T) {
	now := time.Date(2026, time.October, 9, 22, 0, 0, 0, time.UTC)
	d, notifications := newAlertTestDaemon(t, &now)

	skipped := make([]backup.SkippedFile, 0, maxReportedSkippedFiles+5)
	for i := 0; i < maxReportedSkippedFiles+5; i++ {
		skipped = append(skipped, backup.SkippedFile{
			Path:   fmt.Sprintf("/Users/me/Library/Mail/%03d.emlx", i),
			Reason: "operation not permitted",
		})
	}
	d.recordSkippedFiles(skipped)
	d.setIdleSuccess()
	d.recordSkippedFiles(skipped)
	d.setIdleSuccess()

	status := d.snapshot()
	if status.LastBackupSkippedCount != len(skipped) || len(status.LastBackupSkipped) != maxReportedSkippedFiles {
		t.Fatalf("unexpected skipped files in status: count=%d listed=%d", status.LastBackupSkippedCount, len(status.LastBackupSkipped))
	}
	if status.LastBackupSkipped[0] != skipped[0] {
		t.Fatalf("unexpected first skipped file: %+v", status.LastBackupSkipped[0])
	}
	if notifications.count() != 1 || notifications.titles[0] != "Baxter skipped 55 files" {
		t.Fatalf("skipped files must notify once when they start: %+v", notifications.titles)
	}

	reloaded := New(config.DefaultConfig())
	if got := reloaded.snapshot().LastBackupSkippedCount; got != len(skipped) {
		t.Fatalf("skipped files must survive a restart: got %d", got)
	}

	d.recordSkippedFiles(nil)
	d.setIdleSuccess()
	if status := d.snapshot(); status.LastBackupSkippedCount != 0 || len(status.LastBackupSkipped) != 0 {
		t.Fatalf("a clean backup must clear skipped files: %+v", status)
	}
}
