package daemon

import (
	"context"
	"fmt"
	"time"

	"baxter/internal/backup"
)

const (
	maxReportedSkippedFiles = 50
	alertCheckInterval      = time.Hour
	overdueAlertInterval    = 24 * time.Hour
	appPresenceWindow       = 2 * time.Minute
	dailyOverdueAfter       = 3 * 24 * time.Hour
	weeklyOverdueAfter      = 15 * 24 * time.Hour
)

var defaultNotifier = postUserNotification

// backupOverdue reports whole days since the last successful backup and
// whether a scheduled backup has gone without one for too long.
func backupOverdue(lastBackupAt time.Time, schedule string, now time.Time) (int, bool) {
	if lastBackupAt.IsZero() {
		return 0, false
	}
	age := now.Sub(lastBackupAt)
	if age < 0 {
		return 0, false
	}
	days := int(age / (24 * time.Hour))
	switch schedule {
	case "daily":
		return days, age >= dailyOverdueAfter
	case "weekly":
		return days, age >= weeklyOverdueAfter
	default:
		return days, false
	}
}

func (d *Daemon) runAlertMonitor(ctx context.Context) {
	for {
		d.alertIfBackupOverdue()
		select {
		case <-ctx.Done():
			return
		case <-d.alertTick(alertCheckInterval):
		}
	}
}

func (d *Daemon) alertIfBackupOverdue() {
	now := d.now()

	d.mu.Lock()
	days, overdue := backupOverdue(d.status.LastBackupAt, d.cfg.Schedule, now)
	lastAlertAt := d.status.LastOverdueAlertAt
	due := overdue && !d.running && (lastAlertAt.IsZero() || now.Sub(lastAlertAt) >= overdueAlertInterval)
	lastError := d.status.LastError
	if due {
		d.status.LastOverdueAlertAt = now.UTC()
	}
	d.mu.Unlock()

	if !due {
		return
	}
	d.persistStatus()
	body := "Open Baxter to see what is wrong."
	if lastError != "" {
		body = "Last error: " + lastError
	}
	d.notify(fmt.Sprintf("No Baxter backup in %d days", days), body)
}

// alertBackupFailed notifies directly only when the menu bar app, which posts
// its own failure notification, is not polling for status.
func (d *Daemon) alertBackupFailed(err error) {
	d.mu.Lock()
	appWatching := !d.lastStatusPollAt.IsZero() && d.now().Sub(d.lastStatusPollAt) < appPresenceWindow
	d.mu.Unlock()
	if appWatching {
		return
	}
	d.notify("Baxter backup failed", err.Error())
}

func (d *Daemon) noteStatusPoll() {
	now := d.now()
	d.mu.Lock()
	d.lastStatusPollAt = now
	d.mu.Unlock()
}

// recordSkippedFiles stores what the latest completed backup left out and
// notifies when a backup starts skipping files or skips at least twice as many
// as the one before.
func (d *Daemon) recordSkippedFiles(skipped []backup.SkippedFile) {
	reported := skipped
	if len(reported) > maxReportedSkippedFiles {
		reported = reported[:maxReportedSkippedFiles]
	}

	d.mu.Lock()
	previousCount := d.status.LastSkippedCount
	d.status.LastSkippedCount = len(skipped)
	d.status.LastSkipped = append([]backup.SkippedFile(nil), reported...)
	d.mu.Unlock()

	if len(skipped) == 0 || (previousCount > 0 && len(skipped) < 2*previousCount) {
		return
	}
	title := fmt.Sprintf("Baxter skipped %d files", len(skipped))
	if len(skipped) == 1 {
		title = "Baxter skipped 1 file"
	}
	d.notify(title, fmt.Sprintf("%s: %s", skipped[0].Path, skipped[0].Reason))
}

func (d *Daemon) notify(title string, body string) {
	d.mu.Lock()
	notifier := d.notifier
	d.mu.Unlock()
	if notifier == nil {
		return
	}
	notifier(title, body)
}
