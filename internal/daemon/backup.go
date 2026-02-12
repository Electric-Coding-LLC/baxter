package daemon

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"baxter/internal/backup"
	"baxter/internal/config"
	"baxter/internal/crypto"
	"baxter/internal/state"
	"baxter/internal/storage"
)

func (d *Daemon) objectStore(cfg *config.Config) (storage.ObjectStore, error) {
	objectsDir, err := state.ObjectStoreDir()
	if err != nil {
		return nil, err
	}
	return storage.NewFromConfig(cfg.S3, objectsDir)
}

var errBackupAlreadyRunning = errors.New("backup already running")

func (d *Daemon) triggerBackup() error {
	cfg := d.currentConfig()

	d.mu.Lock()
	if d.running {
		d.mu.Unlock()
		return errBackupAlreadyRunning
	}
	d.running = true
	d.status.State = "running"
	d.status.LastError = ""
	d.mu.Unlock()

	go func() {
		err := d.backupRunner(context.Background(), cfg)
		if err != nil {
			d.setFailed(err)
			return
		}
		d.setIdleSuccess()
	}()
	return nil
}

func (d *Daemon) performBackup(ctx context.Context, cfg *config.Config) error {
	_ = ctx
	manifestPath, err := state.ManifestPath()
	if err != nil {
		return err
	}
	snapshotDir, err := state.ManifestSnapshotsDir()
	if err != nil {
		return err
	}

	store, err := d.objectStore(cfg)
	if err != nil {
		return fmt.Errorf("create object store: %w", err)
	}
	keys, err := encryptionKeys(cfg)
	if err != nil {
		return err
	}

	result, err := backup.Run(cfg, backup.RunOptions{
		ManifestPath:      manifestPath,
		SnapshotDir:       snapshotDir,
		SnapshotRetention: cfg.Retention.ManifestSnapshots,
		EncryptionKey:     keys.primary,
		Store:             store,
	})
	if err != nil {
		return err
	}
	fmt.Printf("backup complete: uploaded=%d removed=%d total=%d\n", result.Uploaded, result.Removed, result.Total)
	return nil
}

func encryptionKey(cfg *config.Config) ([]byte, error) {
	keys, err := encryptionKeys(cfg)
	if err != nil {
		return nil, err
	}
	return keys.primary, nil
}

type encryptionKeySet struct {
	primary    []byte
	candidates [][]byte
}

func encryptionKeys(cfg *config.Config) (encryptionKeySet, error) {
	passphrase := os.Getenv(passphraseEnv)
	if passphrase != "" {
		return deriveEncryptionKeys(passphrase)
	}

	passphrase, err := crypto.PassphraseFromKeychain(cfg.Encryption.KeychainService, cfg.Encryption.KeychainAccount)
	if err != nil {
		return encryptionKeySet{}, fmt.Errorf("no %s set and keychain lookup failed: %w", passphraseEnv, err)
	}
	return deriveEncryptionKeys(passphrase)
}

func deriveEncryptionKeys(passphrase string) (encryptionKeySet, error) {
	salt, err := readOrCreateKDFSalt()
	if err != nil {
		return encryptionKeySet{}, err
	}

	primary := crypto.KeyFromPassphraseWithSalt(passphrase, salt)
	legacy := crypto.KeyFromPassphrase(passphrase)
	candidates := [][]byte{primary}
	if !bytes.Equal(primary, legacy) {
		candidates = append(candidates, legacy)
	}

	return encryptionKeySet{
		primary:    primary,
		candidates: candidates,
	}, nil
}

func readOrCreateKDFSalt() ([]byte, error) {
	saltPath, err := state.KDFSaltPath()
	if err != nil {
		return nil, err
	}

	if salt, err := os.ReadFile(saltPath); err == nil {
		if err := crypto.ValidateKDFSalt(salt); err != nil {
			return nil, fmt.Errorf("invalid KDF salt at %s: %w", saltPath, err)
		}
		return salt, nil
	} else if !os.IsNotExist(err) {
		return nil, fmt.Errorf("read KDF salt: %w", err)
	}

	salt, err := crypto.NewKDFSalt()
	if err != nil {
		return nil, fmt.Errorf("generate KDF salt: %w", err)
	}

	if err := os.MkdirAll(filepath.Dir(saltPath), 0o755); err != nil {
		return nil, fmt.Errorf("create state dir: %w", err)
	}
	tmpPath := saltPath + ".tmp"
	if err := os.WriteFile(tmpPath, salt, 0o600); err != nil {
		return nil, fmt.Errorf("write KDF salt: %w", err)
	}
	if err := os.Rename(tmpPath, saltPath); err != nil {
		return nil, fmt.Errorf("persist KDF salt: %w", err)
	}
	return salt, nil
}
