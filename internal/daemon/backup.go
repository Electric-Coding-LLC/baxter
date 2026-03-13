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
	"baxter/internal/recovery"
	"baxter/internal/state"
	"baxter/internal/storage"
)

var objectStoreFromConfig = storage.NewFromConfig

func (d *Daemon) objectStore(cfg *config.Config) (storage.ObjectStore, error) {
	objectsDir, err := state.ObjectStoreDir()
	if err != nil {
		return nil, err
	}
	return objectStoreFromConfig(cfg.S3, objectsDir)
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
	saltPath, err := state.KDFSaltPath()
	if err != nil {
		return err
	}
	allowCreateWrappedIfMissing, err := backup.AllowCreateWrappedKeyWithoutMetadata(manifestPath, snapshotDir, saltPath, store)
	if err != nil {
		return err
	}
	keys, err := backupEncryptionKeys(cfg, store, allowCreateWrappedIfMissing)
	if err != nil {
		return err
	}

	result, err := backup.Run(cfg, backup.RunOptions{
		ManifestPath:       manifestPath,
		SnapshotDir:        snapshotDir,
		SnapshotRetention:  cfg.Retention.ManifestSnapshots,
		SnapshotMaxAgeDays: cfg.Retention.ManifestMaxAgeDays,
		EncryptionKey:      keys.primary,
		KDFSalt:            keys.salt,
		WrappedMasterKey:   keys.wrapped,
		BackupSetID:        recovery.BackupSetID(cfg),
		Store:              store,
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
	salt       []byte
	wrapped    []byte
}

func encryptionPassphrase(cfg *config.Config) (string, error) {
	passphrase := os.Getenv(passphraseEnv)
	if passphrase != "" {
		return passphrase, nil
	}

	passphrase, err := crypto.PassphraseFromKeychain(cfg.Encryption.KeychainService, cfg.Encryption.KeychainAccount)
	if err != nil {
		return "", fmt.Errorf("no %s set and keychain lookup failed: %w", passphraseEnv, err)
	}
	return passphrase, nil
}

func encryptionKeys(cfg *config.Config) (encryptionKeySet, error) {
	passphrase, err := encryptionPassphrase(cfg)
	if err != nil {
		return encryptionKeySet{}, err
	}
	return deriveEncryptionKeys(passphrase)
}

func backupEncryptionKeys(cfg *config.Config, store storage.ObjectStore, allowCreateWrappedIfMissing bool) (encryptionKeySet, error) {
	return recoveryAwareEncryptionKeys(cfg, store, recovery.ResolveKeySetOptions{
		AllowCreateWrappedIfMissing: allowCreateWrappedIfMissing,
		AdoptWrappedKeyIfMissing:    true,
	})
}

func accessEncryptionKeys(cfg *config.Config, store storage.ObjectStore) (encryptionKeySet, error) {
	return recoveryAwareEncryptionKeys(cfg, store, recovery.ResolveKeySetOptions{
		AllowLegacyFallback: true,
	})
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
		salt:       salt,
	}, nil
}

func recoveryAwareEncryptionKeys(cfg *config.Config, store storage.ObjectStore, opts recovery.ResolveKeySetOptions) (encryptionKeySet, error) {
	passphrase, err := encryptionPassphrase(cfg)
	if err != nil {
		return encryptionKeySet{}, err
	}
	keySet, err := recovery.ResolveKeySet(recovery.ResolveKeySetOptions{
		Store:                       store,
		BackupSetID:                 recovery.BackupSetID(cfg),
		Passphrase:                  passphrase,
		ReadOrCreateKDFSalt:         readOrCreateKDFSalt,
		AllowCreateWrappedIfMissing: opts.AllowCreateWrappedIfMissing,
		AllowLegacyFallback:         opts.AllowLegacyFallback,
		AdoptWrappedKeyIfMissing:    opts.AdoptWrappedKeyIfMissing,
	})
	if err != nil {
		return encryptionKeySet{}, err
	}
	return encryptionKeySetFromRecoveryKeySet(keySet), nil
}

func encryptionKeySetFromRecoveryKeySet(keySet recovery.KeySet) encryptionKeySet {
	return encryptionKeySet{
		primary:    keySet.Primary,
		candidates: keySet.Candidates,
		salt:       keySet.KDFSalt,
		wrapped:    keySet.WrappedMasterKey,
	}
}

func readKDFSalt() ([]byte, error) {
	saltPath, err := state.KDFSaltPath()
	if err != nil {
		return nil, err
	}

	salt, err := os.ReadFile(saltPath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, err
		}
		return nil, fmt.Errorf("read KDF salt: %w", err)
	}
	if err := crypto.ValidateKDFSalt(salt); err != nil {
		return nil, fmt.Errorf("invalid KDF salt at %s: %w", saltPath, err)
	}
	return salt, nil
}

func readOrCreateKDFSalt() ([]byte, error) {
	saltPath, err := state.KDFSaltPath()
	if err != nil {
		return nil, err
	}

	if salt, err := readKDFSalt(); err == nil {
		return salt, nil
	} else if !os.IsNotExist(err) {
		return nil, err
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
