package state

import (
	"path/filepath"
	"testing"
)

func TestAppDirUsesAppSupportOverride(t *testing.T) {
	t.Setenv("BAXTER_APP_SUPPORT_DIR", "/tmp/baxter-app-dir")
	t.Setenv("BAXTER_HOME_DIR", "/tmp/ignored-home")

	got, err := AppDir()
	if err != nil {
		t.Fatalf("AppDir() error = %v", err)
	}

	if got != "/tmp/baxter-app-dir" {
		t.Fatalf("AppDir() = %q, want %q", got, "/tmp/baxter-app-dir")
	}
}

func TestAppDirUsesHomeOverride(t *testing.T) {
	t.Setenv("BAXTER_APP_SUPPORT_DIR", "")
	t.Setenv("BAXTER_HOME_DIR", "/tmp/baxter-home")

	got, err := AppDir()
	if err != nil {
		t.Fatalf("AppDir() error = %v", err)
	}

	want := filepath.Join("/tmp/baxter-home", "Library", "Application Support", AppName)
	if got != want {
		t.Fatalf("AppDir() = %q, want %q", got, want)
	}
}

func TestConfigPathUsesExplicitOverride(t *testing.T) {
	t.Setenv("BAXTER_CONFIG_PATH", "/tmp/baxter-config.toml")
	t.Setenv("BAXTER_APP_SUPPORT_DIR", "/tmp/ignored-app-dir")

	got, err := ConfigPath()
	if err != nil {
		t.Fatalf("ConfigPath() error = %v", err)
	}

	if got != "/tmp/baxter-config.toml" {
		t.Fatalf("ConfigPath() = %q, want %q", got, "/tmp/baxter-config.toml")
	}
}

func TestDaemonStatusPathUsesAppDir(t *testing.T) {
	t.Setenv("BAXTER_APP_SUPPORT_DIR", "/tmp/baxter-app-dir")

	got, err := DaemonStatusPath()
	if err != nil {
		t.Fatalf("DaemonStatusPath() error = %v", err)
	}

	want := filepath.Join("/tmp/baxter-app-dir", "daemon_status.json")
	if got != want {
		t.Fatalf("DaemonStatusPath() = %q, want %q", got, want)
	}
}
