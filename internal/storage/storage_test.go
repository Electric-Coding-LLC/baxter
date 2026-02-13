package storage

import (
	"path/filepath"
	"reflect"
	"testing"
)

func TestLocalClientPathSafety(t *testing.T) {
	c := NewLocalClient(t.TempDir())

	if _, err := c.objectPath("../escape"); err == nil {
		t.Fatal("expected error for parent traversal path")
	}
	if _, err := c.objectPath(filepath.Join(string(filepath.Separator), "abs")); err == nil {
		t.Fatal("expected error for absolute path")
	}
}

func TestLocalClientPutGetListDelete(t *testing.T) {
	c := NewLocalClient(t.TempDir())

	if err := c.PutObject("b/file2", []byte("2")); err != nil {
		t.Fatalf("put file2 failed: %v", err)
	}
	if err := c.PutObject("a/file1", []byte("1")); err != nil {
		t.Fatalf("put file1 failed: %v", err)
	}

	got, err := c.GetObject("a/file1")
	if err != nil {
		t.Fatalf("get failed: %v", err)
	}
	if string(got) != "1" {
		t.Fatalf("unexpected object body: %q", string(got))
	}

	keys, err := c.ListKeys()
	if err != nil {
		t.Fatalf("list failed: %v", err)
	}
	want := []string{"a/file1", "b/file2"}
	if !reflect.DeepEqual(keys, want) {
		t.Fatalf("keys mismatch: got %v want %v", keys, want)
	}

	if err := c.DeleteObject("a/file1"); err != nil {
		t.Fatalf("delete failed: %v", err)
	}
	keys, err = c.ListKeys()
	if err != nil {
		t.Fatalf("list after delete failed: %v", err)
	}
	want = []string{"b/file2"}
	if !reflect.DeepEqual(keys, want) {
		t.Fatalf("keys after delete mismatch: got %v want %v", keys, want)
	}
}
