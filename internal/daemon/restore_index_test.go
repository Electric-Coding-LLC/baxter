package daemon

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"
	"time"

	"baxter/internal/backup"
	"baxter/internal/config"
)

func TestRestoreManifestIndexChildrenFiltersMatchingBranches(t *testing.T) {
	index := newRestoreManifestIndex([]backup.ManifestEntry{
		{Path: "/Users/me/Documents/report.txt"},
		{Path: "/Users/me/Documents/notes.txt"},
		{Path: "/Users/me/Desktop/report-draft.txt"},
		{Path: "/Users/me/Pictures/photo.jpg"},
	})

	got := index.filterChildrenPaths("/Users/me", "report")
	want := []string{
		"/Users/me/Desktop/",
		"/Users/me/Documents/",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("unexpected children: got %#v want %#v", got, want)
	}
}

func TestRestoreManifestIndexPathsWithPrefixSkipsPrefixCollisions(t *testing.T) {
	index := newRestoreManifestIndex([]backup.ManifestEntry{
		{Path: "/Users/me/actions-runner/config.sh"},
		{Path: "/Users/me/actions-runner/bin/runner"},
		{Path: "/Users/me/actions-runner-config.txt"},
	})

	got := index.filterChildrenPaths("/Users/me/actions-runner", "")
	want := []string{
		"/Users/me/actions-runner/bin/",
		"/Users/me/actions-runner/config.sh",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("unexpected children: got %#v want %#v", got, want)
	}
}

func TestRestoreListEndpointRefreshesCachedIndexAfterManifestChange(t *testing.T) {
	homeDir := t.TempDir()
	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)

	manifestPath := testManifestPath(t)
	first := &backup.Manifest{
		CreatedAt: time.Date(2026, time.January, 2, 3, 4, 5, 0, time.UTC),
		Entries: []backup.ManifestEntry{
			{Path: "/Users/me/Documents/alpha.txt"},
		},
	}
	if err := backup.SaveManifest(manifestPath, first); err != nil {
		t.Fatalf("save first manifest: %v", err)
	}

	d := New(config.DefaultConfig())
	firstResp := performRestoreListRequest(t, d, "/v1/restore/list?contains=alpha")
	if !reflect.DeepEqual(firstResp.Paths, []string{"/Users/me/Documents/alpha.txt"}) {
		t.Fatalf("unexpected first response: %#v", firstResp.Paths)
	}

	second := &backup.Manifest{
		CreatedAt: time.Date(2026, time.January, 2, 3, 5, 5, 0, time.UTC),
		Entries: []backup.ManifestEntry{
			{Path: "/Users/me/Documents/beta.txt"},
		},
	}
	if err := backup.SaveManifest(manifestPath, second); err != nil {
		t.Fatalf("save second manifest: %v", err)
	}

	secondResp := performRestoreListRequest(t, d, "/v1/restore/list?contains=beta")
	if !reflect.DeepEqual(secondResp.Paths, []string{"/Users/me/Documents/beta.txt"}) {
		t.Fatalf("unexpected second response: %#v", secondResp.Paths)
	}
}

func performRestoreListRequest(t *testing.T, d *Daemon, path string) restoreListResponse {
	t.Helper()

	req := httptest.NewRequest(http.MethodGet, path, nil)
	rr := httptest.NewRecorder()
	d.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("status code: got %d want %d body=%s", rr.Code, http.StatusOK, rr.Body.String())
	}

	var resp restoreListResponse
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	return resp
}
