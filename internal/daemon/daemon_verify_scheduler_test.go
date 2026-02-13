package daemon

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"baxter/internal/config"
)

func TestStatusIncludesNextVerifyAt(t *testing.T) {
	d := New(config.DefaultConfig())
	next := time.Date(2026, time.February, 6, 10, 30, 0, 0, time.UTC)
	d.setNextVerifyAt(next)

	resp := d.snapshot()
	if resp.NextVerifyAt == "" {
		t.Fatalf("expected next_verify_at in response")
	}
	if resp.NextVerifyAt != next.Format(time.RFC3339) {
		t.Fatalf("unexpected next_verify_at: got %q want %q", resp.NextVerifyAt, next.Format(time.RFC3339))
	}
}

func TestVerifyStatusEndpointScheduleVisibility(t *testing.T) {
	tests := []struct {
		name        string
		schedule    string
		shouldExist bool
	}{
		{name: "daily includes next_verify_at", schedule: "daily", shouldExist: true},
		{name: "weekly includes next_verify_at", schedule: "weekly", shouldExist: true},
		{name: "manual omits next_verify_at", schedule: "manual", shouldExist: false},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			cfg := config.DefaultConfig()
			cfg.Verify.Schedule = tc.schedule
			d := New(cfg)

			ctx, cancel := context.WithCancel(context.Background())
			done := make(chan struct{})
			go func() {
				d.runVerifyScheduler(ctx)
				close(done)
			}()

			if tc.shouldExist {
				deadline := time.Now().Add(500 * time.Millisecond)
				for {
					resp := d.snapshot()
					if resp.NextVerifyAt != "" {
						break
					}
					if time.Now().After(deadline) {
						t.Fatal("next_verify_at was not set in time")
					}
					time.Sleep(5 * time.Millisecond)
				}
			} else {
				deadline := time.Now().Add(500 * time.Millisecond)
				for {
					resp := d.snapshot()
					if resp.NextVerifyAt == "" {
						break
					}
					if time.Now().After(deadline) {
						t.Fatal("expected empty next_verify_at for manual schedule")
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

			if tc.shouldExist && resp.NextVerifyAt == "" {
				t.Fatalf("expected next_verify_at for schedule %q", tc.schedule)
			}
			if !tc.shouldExist && resp.NextVerifyAt != "" {
				t.Fatalf("expected empty next_verify_at for schedule %q, got %q", tc.schedule, resp.NextVerifyAt)
			}

			cancel()
			select {
			case <-done:
			case <-time.After(500 * time.Millisecond):
				t.Fatal("verify scheduler goroutine did not stop in time")
			}
		})
	}
}

func TestReloadConfigEndpointUpdatesNextVerifyAtWithFixedClock(t *testing.T) {
	now := time.Date(2026, time.February, 8, 8, 0, 0, 0, time.UTC)
	cfg := config.DefaultConfig()
	cfg.Verify.Schedule = "daily"
	cfg.Verify.DailyTime = "09:30"
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
			updated.Verify.Schedule = "weekly"
			updated.Verify.WeeklyDay = "friday"
			updated.Verify.WeeklyTime = "18:15"
		default:
			updated.Verify.Schedule = "manual"
		}
		step++
		return updated, nil
	}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		d.runVerifyScheduler(ctx)
		close(done)
	}()
	defer func() {
		cancel()
		select {
		case <-done:
		case <-time.After(500 * time.Millisecond):
			t.Fatal("verify scheduler goroutine did not stop in time")
		}
	}()

	waitForNextVerifyAt(t, d, time.Date(2026, time.February, 8, 9, 30, 0, 0, time.UTC).Format(time.RFC3339))

	req := httptest.NewRequest(http.MethodPost, "/v1/config/reload", nil)
	rr := httptest.NewRecorder()
	d.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("reload status code: got %d want %d", rr.Code, http.StatusOK)
	}
	waitForNextVerifyAt(t, d, time.Date(2026, time.February, 13, 18, 15, 0, 0, time.UTC).Format(time.RFC3339))

	req = httptest.NewRequest(http.MethodPost, "/v1/config/reload", nil)
	rr = httptest.NewRecorder()
	d.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("reload status code: got %d want %d", rr.Code, http.StatusOK)
	}
	waitForNextVerifyAt(t, d, "")
}
