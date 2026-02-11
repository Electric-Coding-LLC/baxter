package daemon

import (
	"encoding/json"
	"net/http/httptest"
	"testing"
	"time"

	"baxter/internal/state"
)

func decodeErrorResponse(t *testing.T, rr *httptest.ResponseRecorder) errorResponse {
	t.Helper()
	var resp errorResponse
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode error response: %v body=%s", err, rr.Body.String())
	}
	return resp
}

func waitForNextScheduledAt(t *testing.T, d *Daemon, want string) {
	t.Helper()
	deadline := time.Now().Add(500 * time.Millisecond)
	for {
		got := d.snapshot().NextScheduledAt
		if got == want {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("next_scheduled_at mismatch: got %q want %q", got, want)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func testManifestPath(t *testing.T) string {
	t.Helper()
	path, err := state.ManifestPath()
	if err != nil {
		t.Fatalf("manifest path: %v", err)
	}
	return path
}

func testManifestSnapshotsDir(t *testing.T) string {
	t.Helper()
	path, err := state.ManifestSnapshotsDir()
	if err != nil {
		t.Fatalf("manifest snapshots dir: %v", err)
	}
	return path
}
