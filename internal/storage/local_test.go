package storage

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestLocalListKeysWithPrefix(t *testing.T) {
	rootDir := t.TempDir()
	client := NewLocalClient(rootDir)

	for key, value := range map[string]string{
		"system/manifests/a.json.enc": "a",
		"system/manifests/b.json.enc": "b",
		"sha256/file.enc":             "c",
	} {
		fullPath := filepath.Join(rootDir, filepath.FromSlash(key))
		if err := os.MkdirAll(filepath.Dir(fullPath), 0o755); err != nil {
			t.Fatalf("mkdir parent: %v", err)
		}
		if err := os.WriteFile(fullPath, []byte(value), 0o600); err != nil {
			t.Fatalf("write object: %v", err)
		}
	}

	keys, err := client.ListKeysWithPrefix("system/manifests/")
	if err != nil {
		t.Fatalf("list keys with prefix failed: %v", err)
	}

	want := []string{
		"system/manifests/a.json.enc",
		"system/manifests/b.json.enc",
	}
	if !reflect.DeepEqual(keys, want) {
		t.Fatalf("keys mismatch: got %v want %v", keys, want)
	}
}
