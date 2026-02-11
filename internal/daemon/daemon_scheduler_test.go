package daemon

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"baxter/internal/config"
)

func TestNextScheduledRun(t *testing.T) {
	loc := time.FixedZone("UTC-0800", -8*60*60)

	tests := []struct {
		name    string
		cfg     scheduleConfig
		now     time.Time
		want    time.Time
		enabled bool
	}{
		{
			name: "manual disabled",
			cfg: scheduleConfig{
				Schedule: "manual",
			},
			now:     time.Date(2026, time.February, 8, 8, 0, 0, 0, loc),
			want:    time.Time{},
			enabled: false,
		},
		{
			name: "daily before configured time uses same day",
			cfg: scheduleConfig{
				Schedule:  "daily",
				DailyTime: "09:30",
			},
			now:     time.Date(2026, time.February, 8, 8, 0, 0, 0, loc),
			want:    time.Date(2026, time.February, 8, 9, 30, 0, 0, loc),
			enabled: true,
		},
		{
			name: "daily after configured time uses next day",
			cfg: scheduleConfig{
				Schedule:  "daily",
				DailyTime: "09:30",
			},
			now:     time.Date(2026, time.February, 8, 10, 0, 0, 0, loc),
			want:    time.Date(2026, time.February, 9, 9, 30, 0, 0, loc),
			enabled: true,
		},
		{
			name: "weekly before configured weekday/time uses same week",
			cfg: scheduleConfig{
				Schedule:   "weekly",
				WeeklyDay:  "sunday",
				WeeklyTime: "09:30",
			},
			now:     time.Date(2026, time.February, 6, 8, 0, 0, 0, loc),  // Friday
			want:    time.Date(2026, time.February, 8, 9, 30, 0, 0, loc), // Sunday
			enabled: true,
		},
		{
			name: "weekly after configured weekday/time uses next week",
			cfg: scheduleConfig{
				Schedule:   "weekly",
				WeeklyDay:  "sunday",
				WeeklyTime: "09:30",
			},
			now:     time.Date(2026, time.February, 8, 12, 0, 0, 0, loc),  // Sunday
			want:    time.Date(2026, time.February, 15, 9, 30, 0, 0, loc), // next Sunday
			enabled: true,
		},
		{
			name: "invalid daily time disabled",
			cfg: scheduleConfig{
				Schedule:  "daily",
				DailyTime: "oops",
			},
			now:     time.Date(2026, time.February, 8, 8, 0, 0, 0, loc),
			want:    time.Time{},
			enabled: false,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, enabled := nextScheduledRun(tc.cfg, tc.now)
			if enabled != tc.enabled {
				t.Fatalf("nextScheduledRun(%+v) enabled=%v want %v", tc.cfg, enabled, tc.enabled)
			}
			if !got.Equal(tc.want) {
				t.Fatalf("nextScheduledRun(%+v) = %v, want %v", tc.cfg, got, tc.want)
			}
		})
	}
}

func TestNextScheduledRunDailyPreservesWallClockAcrossDST(t *testing.T) {
	loc, err := time.LoadLocation("America/Los_Angeles")
	if err != nil {
		t.Skipf("timezone data unavailable: %v", err)
	}

	tests := []struct {
		name      string
		now       time.Time
		want      time.Time
		wantDelta time.Duration
	}{
		{
			name:      "spring forward keeps same local clock time",
			now:       time.Date(2026, time.March, 8, 10, 0, 0, 0, loc), // PDT
			want:      time.Date(2026, time.March, 9, 9, 30, 0, 0, loc), // PDT
			wantDelta: 23*time.Hour + 30*time.Minute,
		},
		{
			name:      "fall back keeps same local clock time",
			now:       time.Date(2026, time.October, 31, 10, 0, 0, 0, loc), // PDT
			want:      time.Date(2026, time.November, 1, 9, 30, 0, 0, loc), // PST
			wantDelta: 24*time.Hour + 30*time.Minute,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			cfg := scheduleConfig{Schedule: "daily", DailyTime: "09:30"}
			got, enabled := nextScheduledRun(cfg, tc.now)
			if !enabled {
				t.Fatal("expected daily schedule to be enabled")
			}
			if !got.Equal(tc.want) {
				t.Fatalf("nextScheduledRun(daily) = %v, want %v", got, tc.want)
			}
			if delta := got.Sub(tc.now); delta != tc.wantDelta {
				t.Fatalf("unexpected next-run delta: got %v want %v", delta, tc.wantDelta)
			}
		})
	}
}

func TestSetIdleSuccessUsesInjectedClock(t *testing.T) {
	d := New(config.DefaultConfig())
	fixed := time.Date(2026, time.February, 8, 11, 15, 0, 0, time.UTC)
	d.clockNow = func() time.Time { return fixed }

	d.mu.Lock()
	d.running = true
	d.mu.Unlock()
	d.setIdleSuccess()

	resp := d.snapshot()
	if resp.LastBackupAt != fixed.Format(time.RFC3339) {
		t.Fatalf("unexpected last_backup_at: got %q want %q", resp.LastBackupAt, fixed.Format(time.RFC3339))
	}
}

func TestStatusIncludesNextScheduledAt(t *testing.T) {
	d := New(config.DefaultConfig())
	next := time.Date(2026, time.February, 6, 10, 30, 0, 0, time.UTC)
	d.setNextScheduledAt(next)

	resp := d.snapshot()
	if resp.NextScheduledAt == "" {
		t.Fatalf("expected next_scheduled_at in response")
	}
	if resp.NextScheduledAt != next.Format(time.RFC3339) {
		t.Fatalf("unexpected next_scheduled_at: got %q want %q", resp.NextScheduledAt, next.Format(time.RFC3339))
	}
}

func TestStatusEndpointScheduleVisibility(t *testing.T) {
	tests := []struct {
		name        string
		schedule    string
		shouldExist bool
	}{
		{name: "daily includes next_scheduled_at", schedule: "daily", shouldExist: true},
		{name: "weekly includes next_scheduled_at", schedule: "weekly", shouldExist: true},
		{name: "manual omits next_scheduled_at", schedule: "manual", shouldExist: false},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			cfg := config.DefaultConfig()
			cfg.Schedule = tc.schedule
			d := New(cfg)

			ctx, cancel := context.WithCancel(context.Background())
			done := make(chan struct{})
			go func() {
				d.runScheduler(ctx)
				close(done)
			}()

			if tc.shouldExist {
				deadline := time.Now().Add(500 * time.Millisecond)
				for {
					resp := d.snapshot()
					if resp.NextScheduledAt != "" {
						break
					}
					if time.Now().After(deadline) {
						t.Fatal("next_scheduled_at was not set in time")
					}
					time.Sleep(5 * time.Millisecond)
				}
			} else {
				deadline := time.Now().Add(500 * time.Millisecond)
				for {
					resp := d.snapshot()
					if resp.NextScheduledAt == "" {
						break
					}
					if time.Now().After(deadline) {
						t.Fatal("expected empty next_scheduled_at for manual schedule")
					}
					time.Sleep(5 * time.Millisecond)
				}
			}

			req := httptest.NewRequest(http.MethodGet, "/v1/status", nil)
			rr := httptest.NewRecorder()
			d.Handler().ServeHTTP(rr, req)
			if rr.Code != http.StatusOK {
				t.Fatalf("status code: got %d want %d", rr.Code, http.StatusOK)
			}

			var resp statusResponse
			if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
				t.Fatalf("decode response: %v", err)
			}

			if tc.shouldExist && resp.NextScheduledAt == "" {
				t.Fatalf("expected next_scheduled_at for schedule %q", tc.schedule)
			}
			if !tc.shouldExist && resp.NextScheduledAt != "" {
				t.Fatalf("expected empty next_scheduled_at for schedule %q, got %q", tc.schedule, resp.NextScheduledAt)
			}

			cancel()
			select {
			case <-done:
			case <-time.After(500 * time.Millisecond):
				t.Fatal("scheduler goroutine did not stop in time")
			}
		})
	}
}

func TestReloadConfigEndpointUpdatesNextScheduledAtWithFixedClock(t *testing.T) {
	now := time.Date(2026, time.February, 8, 8, 0, 0, 0, time.UTC)
	cfg := config.DefaultConfig()
	cfg.Schedule = "daily"
	cfg.DailyTime = "09:30"
	d := New(cfg)
	d.clockNow = func() time.Time { return now }
	d.timerAfter = func(time.Duration) <-chan time.Time {
		return make(chan time.Time)
	}

	var step int
	d.SetConfigPath("/tmp/config.toml")
	d.configLoader = func(path string) (*config.Config, error) {
		updated := config.DefaultConfig()
		switch step {
		case 0:
			updated.Schedule = "weekly"
			updated.WeeklyDay = "friday"
			updated.WeeklyTime = "18:15"
		default:
			updated.Schedule = "manual"
		}
		step++
		return updated, nil
	}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		d.runScheduler(ctx)
		close(done)
	}()
	defer func() {
		cancel()
		select {
		case <-done:
		case <-time.After(500 * time.Millisecond):
			t.Fatal("scheduler goroutine did not stop in time")
		}
	}()

	waitForNextScheduledAt(t, d, time.Date(2026, time.February, 8, 9, 30, 0, 0, time.UTC).Format(time.RFC3339))

	req := httptest.NewRequest(http.MethodPost, "/v1/config/reload", nil)
	rr := httptest.NewRecorder()
	d.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("reload status code: got %d want %d", rr.Code, http.StatusOK)
	}
	waitForNextScheduledAt(t, d, time.Date(2026, time.February, 13, 18, 15, 0, 0, time.UTC).Format(time.RFC3339))

	req = httptest.NewRequest(http.MethodPost, "/v1/config/reload", nil)
	rr = httptest.NewRecorder()
	d.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("reload status code: got %d want %d", rr.Code, http.StatusOK)
	}
	waitForNextScheduledAt(t, d, "")
}

func TestDaemonEndToEndReloadScheduledTriggerAndStatus(t *testing.T) {
	initialNow := time.Date(2026, time.February, 8, 9, 0, 0, 0, time.UTC)
	currentNow := initialNow
	var nowMu sync.Mutex

	cfg := config.DefaultConfig()
	cfg.Schedule = "daily"
	cfg.DailyTime = "09:30"
	d := New(cfg)
	d.clockNow = func() time.Time {
		nowMu.Lock()
		defer nowMu.Unlock()
		return currentNow
	}

	timerCh := make(chan time.Time, 1)
	d.timerAfter = func(time.Duration) <-chan time.Time {
		return timerCh
	}

	backupDone := make(chan struct{}, 1)
	d.backupRunner = func(ctx context.Context, cfg *config.Config) error {
		nowMu.Lock()
		currentNow = time.Date(2026, time.February, 8, 9, 30, 0, 0, time.UTC)
		nowMu.Unlock()
		backupDone <- struct{}{}
		return nil
	}

	d.SetConfigPath("/tmp/config.toml")
	d.configLoader = func(path string) (*config.Config, error) {
		updated := config.DefaultConfig()
		updated.Schedule = "manual"
		return updated, nil
	}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		d.runScheduler(ctx)
		close(done)
	}()
	defer func() {
		cancel()
		select {
		case <-done:
		case <-time.After(500 * time.Millisecond):
			t.Fatal("scheduler goroutine did not stop in time")
		}
	}()

	waitForNextScheduledAt(t, d, time.Date(2026, time.February, 8, 9, 30, 0, 0, time.UTC).Format(time.RFC3339))

	timerCh <- time.Now()
	select {
	case <-backupDone:
	case <-time.After(500 * time.Millisecond):
		t.Fatal("scheduled backup did not trigger")
	}

	deadline := time.Now().Add(500 * time.Millisecond)
	for {
		snap := d.snapshot()
		if snap.State == "idle" && snap.LastBackupAt == time.Date(2026, time.February, 8, 9, 30, 0, 0, time.UTC).Format(time.RFC3339) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("unexpected status after scheduled run: %+v", snap)
		}
		time.Sleep(5 * time.Millisecond)
	}

	req := httptest.NewRequest(http.MethodPost, "/v1/config/reload", nil)
	rr := httptest.NewRecorder()
	d.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("reload status code: got %d want %d", rr.Code, http.StatusOK)
	}
	waitForNextScheduledAt(t, d, "")
}
