package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"baxter/internal/backup"
	"baxter/internal/state"
)

func TestRunOnceCreatesManifestAndObjects(t *testing.T) {
	homeDir := t.TempDir()
	sourceRoot := filepath.Join(t.TempDir(), "source")
	if err := os.MkdirAll(sourceRoot, 0o755); err != nil {
		t.Fatalf("mkdir source root: %v", err)
	}

	sourcePath := filepath.Join(sourceRoot, "doc.txt")
	sourceContent := []byte("baxterd once integration test payload")
	if err := os.WriteFile(sourcePath, sourceContent, 0o600); err != nil {
		t.Fatalf("write source file: %v", err)
	}

	configPath := filepath.Join(t.TempDir(), "config.toml")
	configText := fmt.Sprintf(`backup_roots = ["%s"]
schedule = "manual"

[s3]
endpoint = ""
region = ""
bucket = ""
prefix = "baxter/"

[encryption]
keychain_service = "baxter"
keychain_account = "default"
`, sourceRoot)
	if err := os.WriteFile(configPath, []byte(configText), 0o600); err != nil {
		t.Fatalf("write config file: %v", err)
	}

	goModCache := goEnv(t, "GOMODCACHE")
	goCache := goEnv(t, "GOCACHE")

	t.Setenv("HOME", homeDir)
	t.Setenv("XDG_CONFIG_HOME", homeDir)

	cmd := exec.Command("go", "run", ".", "--once", "--config", configPath)
	cmd.Env = append(os.Environ(),
		"HOME="+homeDir,
		"XDG_CONFIG_HOME="+homeDir,
		"BAXTER_PASSPHRASE=test-passphrase",
		"GOMODCACHE="+goModCache,
		"GOCACHE="+goCache,
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("run baxterd --once failed: %v\noutput:\n%s", err, string(out))
	}

	appDir, err := state.AppDir()
	if err != nil {
		t.Fatalf("resolve app dir: %v", err)
	}
	manifestPath := filepath.Join(appDir, "manifest.json")
	snapshotsDir := filepath.Join(appDir, "manifests")
	objectsDir := filepath.Join(appDir, "objects")

	manifest, err := backup.LoadManifest(manifestPath)
	if err != nil {
		t.Fatalf("load manifest: %v", err)
	}
	if len(manifest.Entries) != 1 {
		t.Fatalf("expected 1 manifest entry, got %d", len(manifest.Entries))
	}

	snapshots, err := os.ReadDir(snapshotsDir)
	if err != nil {
		t.Fatalf("read snapshots dir: %v", err)
	}
	if len(snapshots) == 0 {
		t.Fatal("expected manifest snapshots to be written")
	}

	objects, err := os.ReadDir(objectsDir)
	if err != nil {
		t.Fatalf("read objects dir: %v", err)
	}
	if len(objects) == 0 {
		t.Fatal("expected encrypted objects to be written")
	}
}

func TestAllowRemoteIPCRequiresToken(t *testing.T) {
	homeDir := t.TempDir()
	goModCache := goEnv(t, "GOMODCACHE")
	goCache := goEnv(t, "GOCACHE")

	cmd := exec.Command("go", "run", ".", "--allow-remote-ipc", "--ipc-addr", "0.0.0.0:41820")
	cmd.Env = append(os.Environ(),
		"HOME="+homeDir,
		"XDG_CONFIG_HOME="+homeDir,
		"GOMODCACHE="+goModCache,
		"GOCACHE="+goCache,
	)
	out, err := cmd.CombinedOutput()
	if err == nil {
		t.Fatalf("expected baxterd remote IPC startup without token to fail, output:\n%s", string(out))
	}
	if !strings.Contains(string(out), "ipc token error") {
		t.Fatalf("expected ipc token error, output:\n%s", string(out))
	}
}

func goEnv(t *testing.T, key string) string {
	t.Helper()

	cmd := exec.Command("go", "env", key)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("go env %s failed: %v\noutput:\n%s", key, err, string(out))
	}
	value := strings.TrimSpace(string(out))
	if value == "" {
		t.Fatalf("go env %s returned empty value", key)
	}
	return value
}
