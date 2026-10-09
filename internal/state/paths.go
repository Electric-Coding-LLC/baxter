package state

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const AppName = "baxter"

func AppDir() (string, error) {
	if dir := strings.TrimSpace(os.Getenv("BAXTER_APP_SUPPORT_DIR")); dir != "" {
		return dir, nil
	}
	if home := strings.TrimSpace(os.Getenv("BAXTER_HOME_DIR")); home != "" {
		return filepath.Join(home, "Library", "Application Support", AppName), nil
	}

	dir, err := os.UserConfigDir()
	if err != nil || dir == "" {
		home, homeErr := os.UserHomeDir()
		if homeErr != nil {
			return "", homeErr
		}
		dir = filepath.Join(home, "Library", "Application Support")
	}
	appDir := filepath.Join(dir, AppName)
	if err := rejectRealAppDirUnderTest(appDir); err != nil {
		return "", err
	}
	return appDir, nil
}

// rejectRealAppDirUnderTest stops a test binary from resolving the app
// directory of the machine it runs on. Tests must point HOME at a temporary
// directory or set an explicit override.
func rejectRealAppDirUnderTest(appDir string) error {
	if !testing.Testing() {
		return nil
	}
	tempDir := os.TempDir()
	if pathWithin(appDir, tempDir) {
		return nil
	}
	if resolved, err := filepath.EvalSymlinks(tempDir); err == nil && pathWithin(appDir, resolved) {
		return nil
	}
	return fmt.Errorf("refusing to use app directory %s during go test: point HOME at a temporary directory", appDir)
}

func pathWithin(path, parent string) bool {
	rel, err := filepath.Rel(filepath.Clean(parent), filepath.Clean(path))
	if err != nil {
		return false
	}
	return rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

func ConfigPath() (string, error) {
	if path := strings.TrimSpace(os.Getenv("BAXTER_CONFIG_PATH")); path != "" {
		return path, nil
	}

	dir, err := AppDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "config.toml"), nil
}

func ManifestPath() (string, error) {
	dir, err := AppDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "manifest.json"), nil
}

func ManifestSnapshotsDir() (string, error) {
	dir, err := AppDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "manifests"), nil
}

func ObjectStoreDir() (string, error) {
	dir, err := AppDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "objects"), nil
}

func KDFSaltPath() (string, error) {
	dir, err := AppDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "kdf_salt.bin"), nil
}

func DaemonStatusPath() (string, error) {
	dir, err := AppDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "daemon_status.json"), nil
}
