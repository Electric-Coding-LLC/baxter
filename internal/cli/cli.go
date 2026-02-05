package cli

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"baxter/internal/backup"
	"baxter/internal/config"
	"baxter/internal/crypto"
	"baxter/internal/state"
	"baxter/internal/storage"
)

const passphraseEnv = "BAXTER_PASSPHRASE"

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
			return backupStatus()
		default:
			return errors.New("unknown backup subcommand")
		}
	case "restore":
		if len(rest) != 2 {
			return errors.New("usage: baxter restore <path>")
		}
		return restorePath(rest[1])
	default:
		return usageError()
	}
}

func usageError() error {
	return errors.New("usage: baxter [-config path] backup run|status | restore <path>")
}

func runBackup(cfg *config.Config) error {
	if len(cfg.BackupRoots) == 0 {
		return errors.New("no backup_roots configured")
	}

	key, err := encryptionKeyFromEnv()
	if err != nil {
		return err
	}

	manifestPath, err := state.ManifestPath()
	if err != nil {
		return err
	}

	objectsDir, err := state.ObjectStoreDir()
	if err != nil {
		return err
	}
	store := storage.NewLocalClient(objectsDir)

	previous, err := backup.LoadManifest(manifestPath)
	if err != nil {
		return fmt.Errorf("load manifest: %w", err)
	}

	current, err := backup.BuildManifest(cfg.BackupRoots)
	if err != nil {
		return fmt.Errorf("build manifest: %w", err)
	}

	plan := backup.PlanChanges(previous, current)
	for _, entry := range plan.NewOrChanged {
		plain, err := os.ReadFile(entry.Path)
		if err != nil {
			return fmt.Errorf("read file %s: %w", entry.Path, err)
		}
		encrypted, err := crypto.EncryptBytes(key, plain)
		if err != nil {
			return fmt.Errorf("encrypt file %s: %w", entry.Path, err)
		}
		if err := store.PutObject(backup.ObjectKeyForPath(entry.Path), encrypted); err != nil {
			return fmt.Errorf("store object %s: %w", entry.Path, err)
		}
	}

	for _, path := range plan.RemovedPaths {
		if err := store.DeleteObject(backup.ObjectKeyForPath(path)); err != nil {
			return fmt.Errorf("delete object %s: %w", path, err)
		}
	}

	if err := backup.SaveManifest(manifestPath, current); err != nil {
		return fmt.Errorf("save manifest: %w", err)
	}

	fmt.Printf("backup complete: uploaded=%d removed=%d total=%d\n", len(plan.NewOrChanged), len(plan.RemovedPaths), len(current.Entries))
	return nil
}

func backupStatus() error {
	manifestPath, err := state.ManifestPath()
	if err != nil {
		return err
	}

	m, err := backup.LoadManifest(manifestPath)
	if err != nil {
		return fmt.Errorf("load manifest: %w", err)
	}

	objectsDir, err := state.ObjectStoreDir()
	if err != nil {
		return err
	}
	store := storage.NewLocalClient(objectsDir)
	keys, err := store.ListKeys()
	if err != nil {
		return fmt.Errorf("list objects: %w", err)
	}

	fmt.Printf("manifest entries=%d objects=%d created_at=%s\n", len(m.Entries), len(keys), m.CreatedAt.Format("2006-01-02 15:04:05Z07:00"))
	return nil
}

func restorePath(requestedPath string) error {
	key, err := encryptionKeyFromEnv()
	if err != nil {
		return err
	}

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

	objectsDir, err := state.ObjectStoreDir()
	if err != nil {
		return err
	}
	store := storage.NewLocalClient(objectsDir)

	payload, err := store.GetObject(backup.ObjectKeyForPath(entry.Path))
	if err != nil {
		return fmt.Errorf("read object: %w", err)
	}

	plain, err := crypto.DecryptBytes(key, payload)
	if err != nil {
		return fmt.Errorf("decrypt object: %w", err)
	}

	if err := os.MkdirAll(filepath.Dir(entry.Path), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(entry.Path, plain, entry.Mode.Perm()); err != nil {
		return err
	}

	fmt.Printf("restore complete: %s\n", entry.Path)
	return nil
}

func encryptionKeyFromEnv() ([]byte, error) {
	passphrase := os.Getenv(passphraseEnv)
	if passphrase == "" {
		return nil, fmt.Errorf("%s is required", passphraseEnv)
	}
	return crypto.KeyFromPassphrase(passphrase), nil
}
