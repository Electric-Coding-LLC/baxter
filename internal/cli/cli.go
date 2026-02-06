package cli

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"baxter/internal/backup"
	"baxter/internal/config"
	"baxter/internal/crypto"
	"baxter/internal/state"
	"baxter/internal/storage"
)

const passphraseEnv = "BAXTER_PASSPHRASE"

type restoreOptions struct {
	DryRun    bool
	ToDir     string
	Overwrite bool
}

type restoreListOptions struct {
	Prefix   string
	Contains string
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
	default:
		return usageError()
	}
}

func usageError() error {
	return errors.New("usage: baxter [-config path] backup run|status | restore list [--prefix path] [--contains text] | restore [--dry-run] [--to dir] [--overwrite] <path>")
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

	store, err := objectStoreFromConfig(cfg)
	if err != nil {
		return err
	}

	result, err := backup.Run(cfg, backup.RunOptions{
		ManifestPath:  manifestPath,
		EncryptionKey: key,
		Store:         store,
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

	store, err := objectStoreFromConfig(cfg)
	if err != nil {
		return err
	}
	keys, err := store.ListKeys()
	if err != nil {
		return fmt.Errorf("list objects: %w", err)
	}

	fmt.Printf("manifest entries=%d objects=%d created_at=%s\n", len(m.Entries), len(keys), m.CreatedAt.Format("2006-01-02 15:04:05Z07:00"))
	return nil
}

func restorePath(cfg *config.Config, requestedPath string, opts restoreOptions) error {
	manifestPath, err := state.ManifestPath()
	if err != nil {
		return err
	}

	m, err := backup.LoadManifest(manifestPath)
	if err != nil {
		return fmt.Errorf("load manifest: %w", err)
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

	if err := restoreFS.Parse(args); err != nil {
		return restoreOptions{}, "", err
	}

	rest := restoreFS.Args()
	if len(rest) != 1 {
		return restoreOptions{}, "", errors.New("usage: baxter restore [--dry-run] [--to dir] [--overwrite] <path>")
	}
	return opts, rest[0], nil
}

func parseRestoreListArgs(args []string) (restoreListOptions, error) {
	listFS := flag.NewFlagSet("restore list", flag.ContinueOnError)
	listFS.SetOutput(os.Stderr)

	var opts restoreListOptions
	listFS.StringVar(&opts.Prefix, "prefix", "", "filter restore paths by prefix")
	listFS.StringVar(&opts.Contains, "contains", "", "filter restore paths containing text")

	if err := listFS.Parse(args); err != nil {
		return restoreListOptions{}, err
	}
	if len(listFS.Args()) != 0 {
		return restoreListOptions{}, errors.New("usage: baxter restore list [--prefix path] [--contains text]")
	}
	return opts, nil
}

func restoreList(opts restoreListOptions) error {
	manifestPath, err := state.ManifestPath()
	if err != nil {
		return err
	}

	m, err := backup.LoadManifest(manifestPath)
	if err != nil {
		return fmt.Errorf("load manifest: %w", err)
	}

	for _, path := range filterRestorePaths(m.Entries, opts) {
		fmt.Println(path)
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
