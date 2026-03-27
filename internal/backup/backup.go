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
	"strings"
	"time"
)

type ManifestEntry struct {
	Path      string      `json:"path"`
	Size      int64       `json:"size"`
	Mode      fs.FileMode `json:"mode"`
	ModTime   time.Time   `json:"mod_time"`
	SHA256    string      `json:"sha256"`
	ObjectKey string      `json:"object_key,omitempty"`
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
	return BuildManifestWithOptions(roots, BuildOptions{})
}

func BuildManifestWithOptions(roots []string, opts BuildOptions) (*Manifest, error) {
	entries := make([]ManifestEntry, 0)
	matcher := newExclusionMatcher(opts)

	for _, root := range roots {
		cleanRoot := filepath.Clean(root)
		if matcher.isExcluded(cleanRoot) {
			continue
		}

		walkErr := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				if shouldIgnoreManifestError(path, err) {
					return nil
				}
				return err
			}
			cleanPath := filepath.Clean(path)
			if matcher.isExcluded(cleanPath) {
				if d.IsDir() {
					return fs.SkipDir
				}
				return nil
			}
			if d.IsDir() {
				return nil
			}
			if shouldSkipManifestPath(cleanPath) {
				return nil
			}

			info, err := d.Info()
			if err != nil {
				if shouldIgnoreManifestError(cleanPath, err) {
					return nil
				}
				return err
			}
			if !info.Mode().IsRegular() {
				// Skip non-regular entries (for example symlinked framework dirs).
				return nil
			}

			hash, err := fileSHA256(path)
			if err != nil {
				if shouldIgnoreManifestError(cleanPath, err) {
					return nil
				}
				return err
			}

			entries = append(entries, ManifestEntry{
				Path:    cleanPath,
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

func shouldSkipManifestPath(path string) bool {
	return strings.EqualFold(filepath.Base(filepath.Clean(path)), ".localized")
}

func shouldIgnoreManifestError(path string, err error) bool {
	if !shouldSkipManifestPath(path) || err == nil {
		return false
	}
	return strings.Contains(strings.ToLower(err.Error()), "resource deadlock avoided")
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

func ObjectKeyForContentSHA256(sha string) string {
	return "sha256/" + strings.ToLower(strings.TrimSpace(sha)) + ".enc"
}

func ResolveObjectKey(entry ManifestEntry) string {
	if key := strings.TrimSpace(entry.ObjectKey); key != "" {
		return key
	}
	return ObjectKeyForPath(entry.Path)
}

func AssignObjectKeys(previous, current *Manifest) {
	if current == nil {
		return
	}

	prevMap := make(map[string]ManifestEntry, len(previous.Entries))
	if previous != nil {
		for _, entry := range previous.Entries {
			prevMap[filepath.Clean(entry.Path)] = entry
		}
	}

	for i := range current.Entries {
		entry := &current.Entries[i]
		prev, ok := prevMap[filepath.Clean(entry.Path)]
		if ok && prev.SHA256 == entry.SHA256 && prev.Size == entry.Size {
			entry.ObjectKey = ResolveObjectKey(prev)
			continue
		}
		entry.ObjectKey = ObjectKeyForContentSHA256(entry.SHA256)
	}
}

func PathHasPrefix(path string, prefix string) bool {
	cleanPrefix := filepath.Clean(strings.TrimSpace(prefix))
	if cleanPrefix == "." {
		cleanPrefix = ""
	}
	if cleanPrefix == "" {
		return true
	}

	relPath, err := filepath.Rel(cleanPrefix, filepath.Clean(path))
	if err != nil {
		return false
	}
	if relPath == "." {
		return true
	}
	if relPath == ".." || strings.HasPrefix(relPath, ".."+string(filepath.Separator)) {
		return false
	}
	return true
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
