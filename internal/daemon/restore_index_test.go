package daemon

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
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

func TestRestoreListEndpointReusesCachedLatestIndexWithinTTL(t *testing.T) {
	homeDir := t.TempDir()
	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)

	manifestPath := testManifestPath(t)
	manifest := &backup.Manifest{
		CreatedAt: time.Date(2026, time.January, 2, 3, 4, 5, 0, time.UTC),
		Entries: []backup.ManifestEntry{
			{Path: "/Users/me/Documents/alpha.txt"},
		},
	}
	if err := backup.SaveManifest(manifestPath, manifest); err != nil {
		t.Fatalf("save manifest: %v", err)
	}

	now := time.Date(2026, time.January, 2, 3, 4, 10, 0, time.UTC)
	d := New(config.DefaultConfig())
	d.clockNow = func() time.Time { return now }

	resp := performRestoreListRequest(t, d, "/v1/restore/list?contains=alpha")
	if !reflect.DeepEqual(resp.Paths, []string{"/Users/me/Documents/alpha.txt"}) {
		t.Fatalf("unexpected first response: %#v", resp.Paths)
	}

	corruptRestoreManifestPreservingStat(t, manifestPath)

	resp = performRestoreListRequest(t, d, "/v1/restore/list?contains=alpha")
	if !reflect.DeepEqual(resp.Paths, []string{"/Users/me/Documents/alpha.txt"}) {
		t.Fatalf("unexpected cached response: %#v", resp.Paths)
	}
}

func TestRestoreListEndpointExpiresLatestCacheTTL(t *testing.T) {
	homeDir := t.TempDir()
	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)

	manifestPath := testManifestPath(t)
	manifest := &backup.Manifest{
		CreatedAt: time.Date(2026, time.January, 2, 3, 4, 5, 0, time.UTC),
		Entries: []backup.ManifestEntry{
			{Path: "/Users/me/Documents/alpha.txt"},
		},
	}
	if err := backup.SaveManifest(manifestPath, manifest); err != nil {
		t.Fatalf("save manifest: %v", err)
	}

	now := time.Date(2026, time.January, 2, 3, 4, 10, 0, time.UTC)
	d := New(config.DefaultConfig())
	d.clockNow = func() time.Time { return now }

	performRestoreListRequest(t, d, "/v1/restore/list?contains=alpha")
	corruptRestoreManifestPreservingStat(t, manifestPath)

	d.clockNow = func() time.Time { return now.Add(restoreListLatestCacheTTL + time.Second) }

	req := httptest.NewRequest(http.MethodGet, "/v1/restore/list?contains=alpha", nil)
	rr := httptest.NewRecorder()
	d.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("status code: got %d want %d body=%s", rr.Code, http.StatusBadRequest, rr.Body.String())
	}

	var errResp errorResponse
	if err := json.Unmarshal(rr.Body.Bytes(), &errResp); err != nil {
		t.Fatalf("decode error response: %v", err)
	}
	if errResp.Code != "manifest_load_failed" {
		t.Fatalf("unexpected error code: %#v", errResp)
	}
}

func TestRestoreListEndpointReusesExplicitSnapshotIndexWithoutTTL(t *testing.T) {
	homeDir := t.TempDir()
	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)

	manifestPath := testManifestPath(t)
	if err := backup.SaveManifest(manifestPath, &backup.Manifest{
		CreatedAt: time.Now().UTC(),
		Entries:   []backup.ManifestEntry{},
	}); err != nil {
		t.Fatalf("save latest manifest: %v", err)
	}

	snapshotDir := testManifestSnapshotsDir(t)
	snapshot, err := backup.SaveSnapshotManifest(snapshotDir, &backup.Manifest{
		CreatedAt: time.Date(2026, time.January, 3, 4, 5, 6, 0, time.UTC),
		Entries: []backup.ManifestEntry{
			{Path: "/Users/me/Documents/snapshot.txt"},
		},
	})
	if err != nil {
		t.Fatalf("save snapshot manifest: %v", err)
	}

	now := time.Date(2026, time.January, 3, 4, 5, 10, 0, time.UTC)
	d := New(config.DefaultConfig())
	d.clockNow = func() time.Time { return now }

	resp := performRestoreListRequest(t, d, "/v1/restore/list?snapshot="+snapshot.ID+"&contains=snapshot")
	if !reflect.DeepEqual(resp.Paths, []string{"/Users/me/Documents/snapshot.txt"}) {
		t.Fatalf("unexpected first response: %#v", resp.Paths)
	}

	corruptRestoreManifestPreservingStat(t, snapshot.Path)
	d.clockNow = func() time.Time { return now.Add(24 * time.Hour) }

	resp = performRestoreListRequest(t, d, "/v1/restore/list?snapshot="+snapshot.ID+"&contains=snapshot")
	if !reflect.DeepEqual(resp.Paths, []string{"/Users/me/Documents/snapshot.txt"}) {
		t.Fatalf("unexpected cached response: %#v", resp.Paths)
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

func corruptRestoreManifestPreservingStat(t *testing.T, path string) {
	t.Helper()

	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat manifest: %v", err)
	}
	payload := strings.Repeat("{", int(info.Size()))
	if err := os.WriteFile(path, []byte(payload), 0o600); err != nil {
		t.Fatalf("overwrite manifest: %v", err)
	}
	if err := os.Chtimes(path, info.ModTime(), info.ModTime()); err != nil {
		t.Fatalf("restore manifest modtime: %v", err)
	}
}
