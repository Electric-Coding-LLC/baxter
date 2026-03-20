package state

import (
	"os"
	"path/filepath"
	"strings"
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
	return filepath.Join(dir, AppName), nil
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
