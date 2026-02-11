package cli

import (
	"io"
	"os"
	"testing"
)

func captureStdout(t *testing.T, fn func() error) (string, error) {
	t.Helper()

	original := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	os.Stdout = w

	runErr := fn()
	_ = w.Close()
	os.Stdout = original

	out, readErr := io.ReadAll(r)
	_ = r.Close()
	if readErr != nil {
		t.Fatalf("read stdout: %v", readErr)
	}
	return string(out), runErr
}
