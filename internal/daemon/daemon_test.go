package daemon

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

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
