package storage

import (
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type Client struct {
	rootDir string
}

func NewLocalClient(rootDir string) *Client {
	return &Client{rootDir: rootDir}
}

func (c *Client) PutObject(key string, data []byte) error {
	fullPath, err := c.objectPath(key)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(fullPath), 0o755); err != nil {
		return err
	}
	return os.WriteFile(fullPath, data, 0o600)
}

func (c *Client) GetObject(key string) ([]byte, error) {
	fullPath, err := c.objectPath(key)
	if err != nil {
		return nil, err
	}
	return os.ReadFile(fullPath)
}

func (c *Client) DeleteObject(key string) error {
	fullPath, pathErr := c.objectPath(key)
	if pathErr != nil {
		return pathErr
	}
	err := os.Remove(fullPath)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

func (c *Client) ListKeys() ([]string, error) {
	if _, err := os.Stat(c.rootDir); err != nil {
		if os.IsNotExist(err) {
			return []string{}, nil
		}
		return nil, err
	}

	keys := make([]string, 0)
	err := filepath.WalkDir(c.rootDir, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}

		rel, err := filepath.Rel(c.rootDir, path)
		if err != nil {
			return err
		}
		keys = append(keys, filepath.ToSlash(rel))
		return nil
	})
	if err != nil {
		return nil, err
	}

	sort.Strings(keys)
	return keys, nil
}

func (c *Client) objectPath(key string) (string, error) {
	cleaned := filepath.Clean(filepath.FromSlash(key))
	if filepath.IsAbs(cleaned) || strings.HasPrefix(cleaned, "..") {
		return "", errors.New("invalid key path")
	}
	return filepath.Join(c.rootDir, cleaned), nil
}
