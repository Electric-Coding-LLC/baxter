package cli

import (
	"strings"
	"testing"
	"time"

	"baxter/internal/backup"
	"baxter/internal/config"
	"baxter/internal/state"
)

func TestRunRequiresCommand(t *testing.T) {
	setCLIHome(t)

	err := Run(nil)
	if err == nil {
		t.Fatal("expected usage error for missing command")
	}
	if !strings.Contains(err.Error(), "usage: baxter") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestRunRejectsUnknownCommands(t *testing.T) {
	setCLIHome(t)

	tests := []struct {
		name string
		args []string
		want string
	}{
		{name: "unknown top-level", args: []string{"nope"}, want: "usage: baxter"},
		{name: "missing backup subcommand", args: []string{"backup"}, want: "missing backup subcommand"},
		{name: "unknown backup subcommand", args: []string{"backup", "nope"}, want: "unknown backup subcommand"},
		{name: "unknown snapshot subcommand", args: []string{"snapshot", "nope"}, want: "unknown snapshot subcommand"},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			err := Run(tc.args)
			if err == nil {
				t.Fatalf("expected error for args=%v", tc.args)
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("unexpected error for args=%v: got %q want substring %q", tc.args, err.Error(), tc.want)
			}
		})
	}
}

func TestRunBackupStatusPrintsManifestObjectAndSnapshotCounts(t *testing.T) {
	setCLIHome(t)

	manifestPath, err := state.ManifestPath()
	if err != nil {
		t.Fatalf("manifest path: %v", err)
	}
	snapshotDir, err := state.ManifestSnapshotsDir()
	if err != nil {
		t.Fatalf("snapshot dir: %v", err)
	}

	createdAt := time.Date(2026, time.February, 13, 12, 30, 0, 0, time.UTC)
	entryPath := "/Users/me/Documents/report.txt"
	manifest := &backup.Manifest{
		CreatedAt: createdAt,
		Entries: []backup.ManifestEntry{{
			Path: entryPath,
		}},
	}
	if err := backup.SaveManifest(manifestPath, manifest); err != nil {
		t.Fatalf("save manifest: %v", err)
	}

	if _, err := backup.SaveSnapshotManifest(snapshotDir, &backup.Manifest{CreatedAt: createdAt.Add(-time.Hour), Entries: manifest.Entries}); err != nil {
		t.Fatalf("save older snapshot: %v", err)
	}
	latestSnapshot, err := backup.SaveSnapshotManifest(snapshotDir, &backup.Manifest{CreatedAt: createdAt, Entries: manifest.Entries})
	if err != nil {
		t.Fatalf("save latest snapshot: %v", err)
	}

	cfg := config.DefaultConfig()
	store, err := objectStoreFromConfig(cfg)
	if err != nil {
		t.Fatalf("object store: %v", err)
	}
	if err := store.PutObject(backup.ObjectKeyForPath(entryPath), []byte("payload")); err != nil {
		t.Fatalf("put object: %v", err)
	}

	out, err := captureStdout(t, func() error {
		return Run([]string{"backup", "status"})
	})
	if err != nil {
		t.Fatalf("run backup status: %v", err)
	}

	if !strings.Contains(out, "manifest entries=1") {
		t.Fatalf("status output missing manifest count: %q", out)
	}
	if !strings.Contains(out, "objects=1") {
		t.Fatalf("status output missing object count: %q", out)
	}
	if !strings.Contains(out, "snapshots=2") {
		t.Fatalf("status output missing snapshot count: %q", out)
	}
	if !strings.Contains(out, "latest_snapshot="+latestSnapshot.ID) {
		t.Fatalf("status output missing latest snapshot id: %q", out)
	}
	if !strings.Contains(out, "created_at="+createdAt.Format("2006-01-02 15:04:05Z07:00")) {
		t.Fatalf("status output missing created_at: %q", out)
	}
}

func TestRunSnapshotListRespectsLimitAndSortOrder(t *testing.T) {
	setCLIHome(t)

	snapshotDir, err := state.ManifestSnapshotsDir()
	if err != nil {
		t.Fatalf("snapshot dir: %v", err)
	}

	oldest, err := backup.SaveSnapshotManifest(snapshotDir, &backup.Manifest{
		CreatedAt: time.Date(2026, time.February, 10, 9, 0, 0, 0, time.UTC),
		Entries:   []backup.ManifestEntry{},
	})
	if err != nil {
		t.Fatalf("save oldest snapshot: %v", err)
	}
	middle, err := backup.SaveSnapshotManifest(snapshotDir, &backup.Manifest{
		CreatedAt: time.Date(2026, time.February, 11, 9, 0, 0, 0, time.UTC),
		Entries:   []backup.ManifestEntry{},
	})
	if err != nil {
		t.Fatalf("save middle snapshot: %v", err)
	}
	newest, err := backup.SaveSnapshotManifest(snapshotDir, &backup.Manifest{
		CreatedAt: time.Date(2026, time.February, 12, 9, 0, 0, 0, time.UTC),
		Entries:   []backup.ManifestEntry{},
	})
	if err != nil {
		t.Fatalf("save newest snapshot: %v", err)
	}

	out, err := captureStdout(t, func() error {
		return Run([]string{"snapshot", "list", "--limit", "2"})
	})
	if err != nil {
		t.Fatalf("run snapshot list: %v", err)
	}

	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) != 2 {
		t.Fatalf("expected 2 lines from snapshot list, got %d output=%q", len(lines), out)
	}
	if !strings.HasPrefix(lines[0], newest.ID+" ") {
		t.Fatalf("expected newest snapshot first, got %q", lines[0])
	}
	if !strings.HasPrefix(lines[1], middle.ID+" ") {
		t.Fatalf("expected middle snapshot second, got %q", lines[1])
	}
	if strings.Contains(out, oldest.ID) {
		t.Fatalf("did not expect oldest snapshot due to limit, output=%q", out)
	}
}

func setCLIHome(t *testing.T) {
	t.Helper()

	homeDir := t.TempDir()
	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)
}
