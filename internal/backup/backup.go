package backup

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"time"
)

type ManifestEntry struct {
	Path    string      `json:"path"`
	Size    int64       `json:"size"`
	Mode    fs.FileMode `json:"mode"`
	ModTime time.Time   `json:"mod_time"`
	SHA256  string      `json:"sha256"`
}

type Manifest struct {
	CreatedAt time.Time       `json:"created_at"`
	Entries   []ManifestEntry `json:"entries"`
}

type Plan struct {
	NewOrChanged []ManifestEntry
	RemovedPaths []string
}

func LoadManifest(path string) (*Manifest, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return &Manifest{CreatedAt: time.Now().UTC(), Entries: []ManifestEntry{}}, nil
		}
		return nil, err
	}

	var m Manifest
	if err := json.Unmarshal(data, &m); err != nil {
		return nil, err
	}
	if m.Entries == nil {
		m.Entries = []ManifestEntry{}
	}
	return &m, nil
}

func SaveManifest(path string, m *Manifest) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}

	data, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o600)
}

func BuildManifest(roots []string) (*Manifest, error) {
	entries := make([]ManifestEntry, 0)

	for _, root := range roots {
		walkErr := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if d.IsDir() {
				return nil
			}

			info, err := d.Info()
			if err != nil {
				return err
			}

			hash, err := fileSHA256(path)
			if err != nil {
				return err
			}

			entries = append(entries, ManifestEntry{
				Path:    filepath.Clean(path),
				Size:    info.Size(),
				Mode:    info.Mode(),
				ModTime: info.ModTime().UTC(),
				SHA256:  hash,
			})
			return nil
		})
		if walkErr != nil {
			return nil, walkErr
		}
	}

	sort.Slice(entries, func(i, j int) bool {
		return entries[i].Path < entries[j].Path
	})

	return &Manifest{CreatedAt: time.Now().UTC(), Entries: entries}, nil
}

func PlanChanges(previous, current *Manifest) Plan {
	prevMap := make(map[string]ManifestEntry, len(previous.Entries))
	for _, e := range previous.Entries {
		prevMap[e.Path] = e
	}

	currMap := make(map[string]ManifestEntry, len(current.Entries))
	newOrChanged := make([]ManifestEntry, 0)
	for _, e := range current.Entries {
		currMap[e.Path] = e
		prev, ok := prevMap[e.Path]
		if !ok || prev.SHA256 != e.SHA256 || prev.Size != e.Size {
			newOrChanged = append(newOrChanged, e)
		}
	}

	sort.Slice(newOrChanged, func(i, j int) bool {
		return newOrChanged[i].Path < newOrChanged[j].Path
	})

	removed := make([]string, 0)
	for path := range prevMap {
		if _, ok := currMap[path]; !ok {
			removed = append(removed, path)
		}
	}
	sort.Strings(removed)

	return Plan{NewOrChanged: newOrChanged, RemovedPaths: removed}
}

func fileSHA256(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()

	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func ObjectKeyForPath(path string) string {
	sum := sha256.Sum256([]byte(filepath.Clean(path)))
	return hex.EncodeToString(sum[:]) + ".enc"
}

func FindEntryByPath(m *Manifest, requestedPath string) (ManifestEntry, error) {
	cleanPath := filepath.Clean(requestedPath)
	for _, entry := range m.Entries {
		if filepath.Clean(entry.Path) == cleanPath {
			return entry, nil
		}
	}
	return ManifestEntry{}, errors.New("path not found in manifest")
}

func VerifyEntryContent(entry ManifestEntry, content []byte) error {
	sum := sha256.Sum256(content)
	got := hex.EncodeToString(sum[:])
	if got != entry.SHA256 {
		return fmt.Errorf("checksum mismatch for %s: got %s want %s", entry.Path, got, entry.SHA256)
	}
	return nil
}
