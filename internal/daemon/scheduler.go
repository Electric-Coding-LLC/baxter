package daemon

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"baxter/internal/backup"
)

func (d *Daemon) runScheduler(ctx context.Context) {
	for {
		now := d.now()
		schedule := d.backupScheduleConfig()
		nextRun, enabled := nextScheduledRun(schedule, now)
		if !enabled {
			fmt.Printf("backup scheduler disabled: schedule=%s\n", schedule.Schedule)
			d.setNextScheduledAt(time.Time{})
			select {
			case <-ctx.Done():
				return
			case <-d.scheduleChanged:
				continue
			}
		}

		d.setNextScheduledAt(nextRun)
		wait := time.Until(nextRun)
		if wait < 0 {
			wait = 0
		}
		fmt.Printf("backup scheduler next run: schedule=%s next=%s wait=%s\n", schedule.Schedule, nextRun.Format(time.RFC3339), wait)

		select {
		case <-ctx.Done():
			return
		case <-d.scheduleChanged:
			fmt.Printf("backup scheduler config changed: recomputing next run\n")
			continue
		case <-d.timerAfter(wait):
			if err := d.triggerBackup(); err != nil && !errors.Is(err, errBackupAlreadyRunning) {
				d.setFailed(err)
			}
		}
	}
}

func (d *Daemon) runVerifyScheduler(ctx context.Context) {
	for {
		now := d.now()
		schedule := d.verifyScheduleConfig()
		nextRun, enabled := nextScheduledRun(schedule, now)
		if !enabled {
			fmt.Printf("verify scheduler disabled: schedule=%s\n", schedule.Schedule)
			d.setNextVerifyAt(time.Time{})
			select {
			case <-ctx.Done():
				return
			case <-d.verifyScheduleChanged:
				continue
			}
		}

		d.setNextVerifyAt(nextRun)
		wait := time.Until(nextRun)
		if wait < 0 {
			wait = 0
		}
		fmt.Printf("verify scheduler next run: schedule=%s next=%s wait=%s\n", schedule.Schedule, nextRun.Format(time.RFC3339), wait)

		select {
		case <-ctx.Done():
			return
		case <-d.verifyScheduleChanged:
			fmt.Printf("verify scheduler config changed: recomputing next run\n")
			continue
		case <-d.timerAfter(wait):
			if err := d.triggerVerify(); err != nil && !errors.Is(err, errVerifyAlreadyRunning) {
				d.setVerifyFailed(err, backup.VerifyResult{})
			}
		}
	}
}

func (d *Daemon) now() time.Time {
	return d.clockNow()
}

func (d *Daemon) backupScheduleConfig() scheduleConfig {
	d.mu.Lock()
	defer d.mu.Unlock()
	return scheduleConfig{
		Schedule:   d.cfg.Schedule,
		DailyTime:  d.cfg.DailyTime,
		WeeklyDay:  d.cfg.WeeklyDay,
		WeeklyTime: d.cfg.WeeklyTime,
	}
}

func (d *Daemon) verifyScheduleConfig() scheduleConfig {
	d.mu.Lock()
	defer d.mu.Unlock()
	return scheduleConfig{
		Schedule:   d.cfg.Verify.Schedule,
		DailyTime:  d.cfg.Verify.DailyTime,
		WeeklyDay:  d.cfg.Verify.WeeklyDay,
		WeeklyTime: d.cfg.Verify.WeeklyTime,
	}
}

func nextScheduledRun(cfg scheduleConfig, now time.Time) (time.Time, bool) {
	switch cfg.Schedule {
	case "daily":
		hour, minute, ok := parseHHMM(cfg.DailyTime)
		if !ok {
			return time.Time{}, false
		}
		return nextDailyRun(now, hour, minute), true
	case "weekly":
		weekday, ok := parseWeekday(cfg.WeeklyDay)
		if !ok {
			return time.Time{}, false
		}
		hour, minute, ok := parseHHMM(cfg.WeeklyTime)
		if !ok {
			return time.Time{}, false
		}
		return nextWeeklyRun(now, weekday, hour, minute), true
	default:
		return time.Time{}, false
	}
}

func nextDailyRun(now time.Time, hour int, minute int) time.Time {
	return nextRunAtLocalTime(now, hour, minute, nil)
}

func nextWeeklyRun(now time.Time, weekday time.Weekday, hour int, minute int) time.Time {
	return nextRunAtLocalTime(now, hour, minute, &weekday)
}

func nextRunAtLocalTime(now time.Time, hour int, minute int, weeklyDay *time.Weekday) time.Time {
	loc := now.Location()
	if loc == nil {
		loc = time.Local
	}

	nowLocal := now.In(loc)
	candidate := time.Date(
		nowLocal.Year(),
		nowLocal.Month(),
		nowLocal.Day(),
		hour,
		minute,
		0,
		0,
		loc,
	)

	if weeklyDay != nil {
		daysAhead := (int(*weeklyDay) - int(nowLocal.Weekday()) + 7) % 7
		candidate = candidate.AddDate(0, 0, daysAhead)
		if !candidate.After(nowLocal) {
			candidate = candidate.AddDate(0, 0, 7)
		}
		return candidate
	}

	if !candidate.After(nowLocal) {
		candidate = candidate.AddDate(0, 0, 1)
	}
	return candidate
}

func parseHHMM(value string) (int, int, bool) {
	if len(value) != 5 || value[2] != ':' {
		return 0, 0, false
	}
	hourTens := value[0]
	hourOnes := value[1]
	minuteTens := value[3]
	minuteOnes := value[4]
	if hourTens < '0' || hourTens > '2' || hourOnes < '0' || hourOnes > '9' {
		return 0, 0, false
	}
	if minuteTens < '0' || minuteTens > '5' || minuteOnes < '0' || minuteOnes > '9' {
		return 0, 0, false
	}
	hour := int(hourTens-'0')*10 + int(hourOnes-'0')
	minute := int(minuteTens-'0')*10 + int(minuteOnes-'0')
	if hour < 0 || hour > 23 {
		return 0, 0, false
	}
	return hour, minute, true
}

func parseWeekday(value string) (time.Weekday, bool) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "sunday":
		return time.Sunday, true
	case "monday":
		return time.Monday, true
	case "tuesday":
		return time.Tuesday, true
	case "wednesday":
		return time.Wednesday, true
	case "thursday":
		return time.Thursday, true
	case "friday":
		return time.Friday, true
	case "saturday":
		return time.Saturday, true
	default:
		return time.Sunday, false
	}
}
