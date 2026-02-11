package daemon

import (
	"context"
	"errors"
	"fmt"
	"os"

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
	key, err := encryptionKey(cfg)
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
