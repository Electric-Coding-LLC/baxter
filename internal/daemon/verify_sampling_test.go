package daemon

import (
	"context"
	"sort"
	"testing"
	"time"

	"baxter/internal/backup"
	"baxter/internal/config"
	"baxter/internal/crypto"
	"baxter/internal/state"
	"baxter/internal/storage"
)

func TestSampleManifestEntries(t *testing.T) {
	entries := []backup.ManifestEntry{
		{Path: "/a"},
		{Path: "/b"},
		{Path: "/c"},
		{Path: "/d"},
		{Path: "/e"},
	}

	tests := []struct {
		name      string
		sample    int
		wantPaths []string
	}{
		{name: "sample zero returns all", sample: 0, wantPaths: []string{"/a", "/b", "/c", "/d", "/e"}},
		{name: "sample larger than entries returns all", sample: 10, wantPaths: []string{"/a", "/b", "/c", "/d", "/e"}},
		{name: "sample one keeps first", sample: 1, wantPaths: []string{"/a"}},
		{name: "sample three spreads evenly", sample: 3, wantPaths: []string{"/a", "/c", "/e"}},
		{name: "sample four stays ordered", sample: 4, wantPaths: []string{"/a", "/b", "/c", "/e"}},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := sampleManifestEntries(entries, tc.sample)
			if len(got) != len(tc.wantPaths) {
				t.Fatalf("sample=%d: size=%d want=%d", tc.sample, len(got), len(tc.wantPaths))
			}
			for i, path := range tc.wantPaths {
				if got[i].Path != path {
					t.Fatalf("sample=%d idx=%d path=%q want=%q", tc.sample, i, got[i].Path, path)
				}
			}
		})
	}
}

func TestFilterManifestEntriesByPrefix(t *testing.T) {
	entries := []backup.ManifestEntry{
		{Path: "/Users/me/Documents/report.txt"},
		{Path: "/Users/me/Documents/notes/todo.md"},
		{Path: "/Users/me/Pictures/photo.jpg"},
	}

	all := filterManifestEntriesByPrefix(entries, "")
	if len(all) != len(entries) {
		t.Fatalf("empty prefix should return all entries: got=%d want=%d", len(all), len(entries))
	}
	all[0].Path = "/mutated"
	if entries[0].Path == "/mutated" {
		t.Fatal("expected empty-prefix filter to return a copy")
	}

	filtered := filterManifestEntriesByPrefix(entries, " /Users/me/Documents/../Documents ")
	if len(filtered) != 2 {
		t.Fatalf("filtered size=%d want=2", len(filtered))
	}
	if filtered[0].Path != "/Users/me/Documents/report.txt" || filtered[1].Path != "/Users/me/Documents/notes/todo.md" {
		t.Fatalf("unexpected filtered paths: %+v", filtered)
	}
}

func TestPerformVerifyAppliesPrefixSampleAndLimit(t *testing.T) {
	tests := []struct {
		name        string
		sample      int
		limit       int
		wantChecked int
	}{
		{name: "prefix excludes out-of-scope paths", sample: 0, limit: 0, wantChecked: 2},
		{name: "sample reduces verify set", sample: 1, limit: 0, wantChecked: 1},
		{name: "limit applies after sampling", sample: 2, limit: 1, wantChecked: 1},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			homeDir := t.TempDir()
			t.Setenv("HOME", homeDir)
			t.Setenv("XDG_CONFIG_HOME", homeDir)
			t.Setenv(passphraseEnv, "verify-sample-passphrase")

			cfg := config.DefaultConfig()
			cfg.Verify.Schedule = "manual"
			cfg.Verify.Prefix = "/Users/me/Documents"
			cfg.Verify.Sample = tc.sample
			cfg.Verify.Limit = tc.limit

			fixture := []struct {
				path     string
				payload  []byte
				storeObj bool
			}{
				{path: "/Users/me/Documents/a.txt", payload: []byte("alpha"), storeObj: true},
				{path: "/Users/me/Documents/b.txt", payload: []byte("beta"), storeObj: true},
				{path: "/Users/me/Pictures/c.txt", payload: []byte("charlie"), storeObj: false},
			}

			entries := make([]backup.ManifestEntry, 0, len(fixture))
			for _, item := range fixture {
				entries = append(entries, backup.ManifestEntry{
					Path:    item.path,
					Mode:    0o600,
					ModTime: time.Now().UTC(),
					Size:    int64(len(item.payload)),
					SHA256:  checksumHex(item.payload),
				})
			}
			sort.Slice(entries, func(i, j int) bool {
				return entries[i].Path < entries[j].Path
			})

			if err := backup.SaveManifest(testManifestPath(t), &backup.Manifest{
				CreatedAt: time.Now().UTC(),
				Entries:   entries,
			}); err != nil {
				t.Fatalf("save manifest: %v", err)
			}

			key, err := encryptionKey(cfg)
			if err != nil {
				t.Fatalf("encryption key: %v", err)
			}
			objectsDir, err := state.ObjectStoreDir()
			if err != nil {
				t.Fatalf("object store dir: %v", err)
			}
			store, err := storage.NewFromConfig(cfg.S3, objectsDir)
			if err != nil {
				t.Fatalf("create object store: %v", err)
			}

			for _, item := range fixture {
				if !item.storeObj {
					continue
				}
				payload, err := crypto.EncryptBytes(key, item.payload)
				if err != nil {
					t.Fatalf("encrypt payload for %s: %v", item.path, err)
				}
				if err := store.PutObject(backup.ObjectKeyForPath(item.path), payload); err != nil {
					t.Fatalf("put object for %s: %v", item.path, err)
				}
			}

			d := New(cfg)
			result, err := d.performVerify(context.Background(), cfg)
			if err != nil {
				t.Fatalf("perform verify: %v", err)
			}
			if result.Checked != tc.wantChecked {
				t.Fatalf("checked=%d want=%d", result.Checked, tc.wantChecked)
			}
			if result.OK != tc.wantChecked {
				t.Fatalf("ok=%d want=%d", result.OK, tc.wantChecked)
			}
			if result.HasFailures() {
				t.Fatalf("expected no failures, got %+v", result)
			}
		})
	}
}
