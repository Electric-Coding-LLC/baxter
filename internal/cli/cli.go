package cli

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"baxter/internal/backup"
	"baxter/internal/config"
	"baxter/internal/crypto"
	"baxter/internal/state"
	"baxter/internal/storage"
)

const passphraseEnv = "BAXTER_PASSPHRASE"

type restoreOptions struct {
	DryRun     bool
	ToDir      string
	Overwrite  bool
	VerifyOnly bool
	Snapshot   string
}

type restoreListOptions struct {
	Prefix   string
	Contains string
	Snapshot string
}

type snapshotListOptions struct {
	Limit int
}

func Run(args []string) error {
	fs := flag.NewFlagSet("baxter", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)

	configPath, err := state.ConfigPath()
	if err != nil {
		return err
	}
	fs.StringVar(&configPath, "config", configPath, "path to config file")

	if err := fs.Parse(args); err != nil {
		return err
	}

	rest := fs.Args()
	if len(rest) == 0 {
		return usageError()
	}

	cfg, err := config.Load(configPath)
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}

	switch rest[0] {
	case "backup":
		if len(rest) < 2 {
			return errors.New("missing backup subcommand (run|status)")
		}
		switch rest[1] {
		case "run":
			return runBackup(cfg)
		case "status":
			return backupStatus(cfg)
		default:
			return errors.New("unknown backup subcommand")
		}
	case "restore":
		if len(rest) >= 2 && rest[1] == "list" {
			opts, err := parseRestoreListArgs(rest[2:])
			if err != nil {
				return err
			}
			return restoreList(opts)
		}

		opts, restorePathArg, err := parseRestoreArgs(rest[1:])
		if err != nil {
			return err
		}
		return restorePath(cfg, restorePathArg, opts)
	case "snapshot":
		if len(rest) < 2 || rest[1] != "list" {
			return errors.New("unknown snapshot subcommand")
		}
		opts, err := parseSnapshotListArgs(rest[2:])
		if err != nil {
			return err
		}
		return snapshotList(opts)
	default:
		return usageError()
	}
}

func usageError() error {
	return errors.New("usage: baxter [-config path] backup run|status | snapshot list [--limit n] | restore list [--snapshot latest|id|RFC3339] [--prefix path] [--contains text] | restore [--dry-run] [--verify-only] [--to dir] [--overwrite] [--snapshot latest|id|RFC3339] <path>")
}

func runBackup(cfg *config.Config) error {
	key, err := encryptionKey(cfg)
	if err != nil {
		return err
	}

	manifestPath, err := state.ManifestPath()
	if err != nil {
		return err
	}
	snapshotDir, err := state.ManifestSnapshotsDir()
	if err != nil {
		return err
	}

	store, err := objectStoreFromConfig(cfg)
	if err != nil {
		return err
	}

	result, err := backup.Run(cfg, backup.RunOptions{
		ManifestPath:      manifestPath,
		SnapshotDir:       snapshotDir,
		SnapshotRetention: cfg.Retention.ManifestSnapshots,
		EncryptionKey:     key,
		Store:             store,
	})
	if err != nil {
		return err
	}

	fmt.Printf("backup complete: uploaded=%d removed=%d total=%d\n", result.Uploaded, result.Removed, result.Total)
	return nil
}

func backupStatus(cfg *config.Config) error {
	manifestPath, err := state.ManifestPath()
	if err != nil {
		return err
	}

	m, err := backup.LoadManifest(manifestPath)
	if err != nil {
		return fmt.Errorf("load manifest: %w", err)
	}
	snapshotDir, err := state.ManifestSnapshotsDir()
	if err != nil {
		return err
	}
	snapshots, err := backup.ListSnapshotManifests(snapshotDir)
	if err != nil {
		return fmt.Errorf("list snapshots: %w", err)
	}

	store, err := objectStoreFromConfig(cfg)
	if err != nil {
		return err
	}
	keys, err := store.ListKeys()
	if err != nil {
		return fmt.Errorf("list objects: %w", err)
	}

	latestSnapshot := ""
	if len(snapshots) > 0 {
		latestSnapshot = snapshots[0].ID
	}
	fmt.Printf(
		"manifest entries=%d objects=%d snapshots=%d latest_snapshot=%s created_at=%s\n",
		len(m.Entries),
		len(keys),
		len(snapshots),
		latestSnapshot,
		m.CreatedAt.Format("2006-01-02 15:04:05Z07:00"),
	)
	return nil
}

func restorePath(cfg *config.Config, requestedPath string, opts restoreOptions) error {
	m, err := loadRestoreManifest(opts.Snapshot)
	if err != nil {
		return err
	}

	entry, err := backup.FindEntryByPath(m, requestedPath)
	if err != nil {
		absPath, absErr := filepath.Abs(requestedPath)
		if absErr != nil {
			return err
		}
		entry, err = backup.FindEntryByPath(m, absPath)
		if err != nil {
			return err
		}
	}

	store, err := objectStoreFromConfig(cfg)
	if err != nil {
		return err
	}

	targetPath, err := resolvedRestorePath(entry.Path, opts.ToDir)
	if err != nil {
		return err
	}

	if opts.DryRun {
		fmt.Printf("restore dry-run: source=%s target=%s overwrite=%t\n", entry.Path, targetPath, opts.Overwrite)
		return nil
	}

	key, err := encryptionKey(cfg)
	if err != nil {
		return err
	}

	payload, err := store.GetObject(backup.ObjectKeyForPath(entry.Path))
	if err != nil {
		return fmt.Errorf("read object: %w", err)
	}

	plain, err := crypto.DecryptBytes(key, payload)
	if err != nil {
		return fmt.Errorf("decrypt object: %w", err)
	}
	if err := backup.VerifyEntryContent(entry, plain); err != nil {
		return fmt.Errorf("verify restored content: %w", err)
	}

	if opts.VerifyOnly {
		fmt.Printf("restore verify-only complete: source=%s checksum=%s\n", entry.Path, entry.SHA256)
		return nil
	}

	if !opts.Overwrite {
		if _, err := os.Stat(targetPath); err == nil {
			return fmt.Errorf("target exists: %s (use --overwrite to replace)", targetPath)
		} else if !os.IsNotExist(err) {
			return err
		}
	}

	if err := os.MkdirAll(filepath.Dir(targetPath), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(targetPath, plain, entry.Mode.Perm()); err != nil {
		return err
	}

	fmt.Printf("restore complete: source=%s target=%s\n", entry.Path, targetPath)
	return nil
}

func parseRestoreArgs(args []string) (restoreOptions, string, error) {
	restoreFS := flag.NewFlagSet("restore", flag.ContinueOnError)
	restoreFS.SetOutput(os.Stderr)

	var opts restoreOptions
	restoreFS.BoolVar(&opts.DryRun, "dry-run", false, "show what would be restored without writing files")
	restoreFS.StringVar(&opts.ToDir, "to", "", "destination root directory for restore")
	restoreFS.BoolVar(&opts.Overwrite, "overwrite", false, "overwrite existing target files")
	restoreFS.BoolVar(&opts.VerifyOnly, "verify-only", false, "verify restore content checksum without writing files")
	restoreFS.StringVar(&opts.Snapshot, "snapshot", "", "restore from snapshot selector (latest, snapshot id, or RFC3339 timestamp)")

	if err := restoreFS.Parse(args); err != nil {
		return restoreOptions{}, "", err
	}

	rest := restoreFS.Args()
	if len(rest) != 1 {
		return restoreOptions{}, "", errors.New("usage: baxter restore [--dry-run] [--verify-only] [--to dir] [--overwrite] [--snapshot latest|id|RFC3339] <path>")
	}
	if opts.DryRun && opts.VerifyOnly {
		return restoreOptions{}, "", errors.New("restore --dry-run and --verify-only cannot be used together")
	}
	return opts, rest[0], nil
}

func parseRestoreListArgs(args []string) (restoreListOptions, error) {
	listFS := flag.NewFlagSet("restore list", flag.ContinueOnError)
	listFS.SetOutput(os.Stderr)

	var opts restoreListOptions
	listFS.StringVar(&opts.Prefix, "prefix", "", "filter restore paths by prefix")
	listFS.StringVar(&opts.Contains, "contains", "", "filter restore paths containing text")
	listFS.StringVar(&opts.Snapshot, "snapshot", "", "list paths from snapshot selector (latest, snapshot id, or RFC3339 timestamp)")

	if err := listFS.Parse(args); err != nil {
		return restoreListOptions{}, err
	}
	if len(listFS.Args()) != 0 {
		return restoreListOptions{}, errors.New("usage: baxter restore list [--snapshot latest|id|RFC3339] [--prefix path] [--contains text]")
	}
	return opts, nil
}

func restoreList(opts restoreListOptions) error {
	m, err := loadRestoreManifest(opts.Snapshot)
	if err != nil {
		return err
	}

	for _, path := range filterRestorePaths(m.Entries, opts) {
		fmt.Println(path)
	}
	return nil
}

func parseSnapshotListArgs(args []string) (snapshotListOptions, error) {
	listFS := flag.NewFlagSet("snapshot list", flag.ContinueOnError)
	listFS.SetOutput(os.Stderr)

	var opts snapshotListOptions
	listFS.IntVar(&opts.Limit, "limit", 20, "maximum number of snapshots to show (0 for all)")

	if err := listFS.Parse(args); err != nil {
		return snapshotListOptions{}, err
	}
	if len(listFS.Args()) != 0 {
		return snapshotListOptions{}, errors.New("usage: baxter snapshot list [--limit n]")
	}
	if opts.Limit < 0 {
		return snapshotListOptions{}, errors.New("limit must be >= 0")
	}
	return opts, nil
}

func snapshotList(opts snapshotListOptions) error {
	snapshotDir, err := state.ManifestSnapshotsDir()
	if err != nil {
		return err
	}
	snapshots, err := backup.ListSnapshotManifests(snapshotDir)
	if err != nil {
		return fmt.Errorf("list snapshots: %w", err)
	}

	limit := len(snapshots)
	if opts.Limit > 0 && opts.Limit < limit {
		limit = opts.Limit
	}
	for i := 0; i < limit; i++ {
		s := snapshots[i]
		fmt.Printf("%s %s entries=%d\n", s.ID, s.CreatedAt.Format(time.RFC3339), s.Entries)
	}
	return nil
}

func filterRestorePaths(entries []backup.ManifestEntry, opts restoreListOptions) []string {
	prefix := filepath.Clean(strings.TrimSpace(opts.Prefix))
	if prefix == "." {
		prefix = ""
	}
	contains := strings.TrimSpace(opts.Contains)

	paths := make([]string, 0, len(entries))
	for _, entry := range entries {
		path := entry.Path
		if prefix != "" && !strings.HasPrefix(filepath.Clean(path), prefix) {
			continue
		}
		if contains != "" && !strings.Contains(path, contains) {
			continue
		}
		paths = append(paths, path)
	}
	return paths
}

func resolvedRestorePath(sourcePath string, toDir string) (string, error) {
	if strings.TrimSpace(toDir) == "" {
		return sourcePath, nil
	}

	cleanToDir := filepath.Clean(toDir)
	cleanSource := filepath.Clean(sourcePath)
	if cleanSource == "." || cleanSource == "" {
		return "", errors.New("invalid restore source path")
	}

	relSource := cleanSource
	if filepath.IsAbs(cleanSource) {
		relSource = strings.TrimPrefix(cleanSource, string(filepath.Separator))
	}
	if relSource == "" || relSource == "." {
		return "", errors.New("invalid restore source path")
	}
	if relSource == ".." || strings.HasPrefix(relSource, ".."+string(filepath.Separator)) {
		return "", errors.New("restore path escapes destination root")
	}

	targetPath := filepath.Join(cleanToDir, relSource)
	targetPath = filepath.Clean(targetPath)

	relToRoot, err := filepath.Rel(cleanToDir, targetPath)
	if err != nil {
		return "", err
	}
	if relToRoot == ".." || strings.HasPrefix(relToRoot, ".."+string(filepath.Separator)) {
		return "", errors.New("restore path escapes destination root")
	}

	return targetPath, nil
}

func encryptionKey(cfg *config.Config) ([]byte, error) {
	passphrase := os.Getenv(passphraseEnv)
	if passphrase != "" {
		return crypto.KeyFromPassphrase(passphrase), nil
	}

	passphrase, err := crypto.PassphraseFromKeychain(cfg.Encryption.KeychainService, cfg.Encryption.KeychainAccount)
	if err != nil {
		return nil, fmt.Errorf("no %s set and keychain lookup failed: %w", passphraseEnv, err)
	}
	return crypto.KeyFromPassphrase(passphrase), nil
}

func objectStoreFromConfig(cfg *config.Config) (storage.ObjectStore, error) {
	objectsDir, err := state.ObjectStoreDir()
	if err != nil {
		return nil, err
	}
	store, err := storage.NewFromConfig(cfg.S3, objectsDir)
	if err != nil {
		return nil, fmt.Errorf("create object store: %w", err)
	}
	return store, nil
}

func loadRestoreManifest(snapshotSelector string) (*backup.Manifest, error) {
	manifestPath, err := state.ManifestPath()
	if err != nil {
		return nil, err
	}
	snapshotDir, err := state.ManifestSnapshotsDir()
	if err != nil {
		return nil, err
	}

	manifest, err := backup.LoadManifestForRestore(manifestPath, snapshotDir, snapshotSelector)
	if err != nil {
		return nil, fmt.Errorf("load manifest: %w", err)
	}
	return manifest, nil
}
