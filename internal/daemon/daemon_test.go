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

func TestStatusEndpointDefaultsToIdle(t *testing.T) {
	d := New(config.DefaultConfig())
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
	if resp.State != "idle" {
		t.Fatalf("state: got %q want idle", resp.State)
	}
}

func TestStatusEndpointRejectsNonGet(t *testing.T) {
	d := New(config.DefaultConfig())
	req := httptest.NewRequest(http.MethodPost, "/v1/status", nil)
	rr := httptest.NewRecorder()

	d.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status code: got %d want %d", rr.Code, http.StatusMethodNotAllowed)
	}
}

func TestRunBackupEndpointReturnsConflictWhenAlreadyRunning(t *testing.T) {
	d := New(config.DefaultConfig())
	d.mu.Lock()
	d.running = true
	d.status.State = "running"
	d.mu.Unlock()

	req := httptest.NewRequest(http.MethodPost, "/v1/backup/run", nil)
	rr := httptest.NewRecorder()

	d.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusConflict {
		t.Fatalf("status code: got %d want %d", rr.Code, http.StatusConflict)
	}
}

func TestRunBackupEndpointRejectsNonPost(t *testing.T) {
	d := New(config.DefaultConfig())
	req := httptest.NewRequest(http.MethodGet, "/v1/backup/run", nil)
	rr := httptest.NewRecorder()

	d.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status code: got %d want %d", rr.Code, http.StatusMethodNotAllowed)
	}
}

func TestScheduleInterval(t *testing.T) {
	tests := []struct {
		name     string
		schedule string
		want     time.Duration
		enabled  bool
	}{
		{name: "manual", schedule: "manual", want: 0, enabled: false},
		{name: "daily", schedule: "daily", want: 24 * time.Hour, enabled: true},
		{name: "weekly", schedule: "weekly", want: 7 * 24 * time.Hour, enabled: true},
		{name: "unknown", schedule: "monthly", want: 0, enabled: false},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, enabled := scheduleInterval(tc.schedule)
			if got != tc.want || enabled != tc.enabled {
				t.Fatalf("scheduleInterval(%q) = (%v, %v), want (%v, %v)", tc.schedule, got, enabled, tc.want, tc.enabled)
			}
		})
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
				select {
				case <-done:
				case <-time.After(500 * time.Millisecond):
					t.Fatal("manual scheduler did not return in time")
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
