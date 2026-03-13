package recovery

import (
	"errors"
	"fmt"
	"strings"

	"baxter/internal/storage"
)

type ResolveKeySetOptions struct {
	Store                       storage.ObjectStore
	BackupSetID                 string
	Passphrase                  string
	ReadOrCreateKDFSalt         func() ([]byte, error)
	AllowCreateWrappedIfMissing bool
	AllowLegacyFallback         bool
	AdoptWrappedKeyIfMissing    bool
}

func ResolveKeySet(opts ResolveKeySetOptions) (KeySet, error) {
	if strings.TrimSpace(opts.Passphrase) == "" {
		return KeySet{}, errors.New("passphrase is required")
	}

	if opts.Store != nil {
		metadata, err := ReadMetadata(opts.Store)
		switch {
		case err == nil:
			expectedBackupSetID := strings.TrimSpace(opts.BackupSetID)
			if expectedBackupSetID != "" && strings.TrimSpace(metadata.BackupSetID) != expectedBackupSetID {
				return KeySet{}, fmt.Errorf(
					"recovery metadata backup set mismatch: got %q want %q",
					metadata.BackupSetID,
					expectedBackupSetID,
				)
			}
			if opts.AdoptWrappedKeyIfMissing && !metadata.HasWrappedMasterKey() {
				salt, err := metadata.KDFSalt()
				if err != nil {
					return KeySet{}, err
				}
				return NewWrappedKeySet(opts.Passphrase, salt)
			}
			return KeySetFromMetadata(metadata, opts.Passphrase)
		case !errors.Is(err, ErrMetadataNotFound):
			if opts.AllowCreateWrappedIfMissing {
				return KeySet{}, fmt.Errorf("read recovery metadata: %w", err)
			}
		}
	}

	if opts.ReadOrCreateKDFSalt == nil {
		return KeySet{}, errors.New("kdf salt resolver is required")
	}

	salt, err := opts.ReadOrCreateKDFSalt()
	if err != nil {
		return KeySet{}, err
	}
	if opts.AllowCreateWrappedIfMissing {
		return NewWrappedKeySet(opts.Passphrase, salt)
	}
	if !opts.AllowLegacyFallback {
		return KeySet{}, fmt.Errorf("recovery metadata not found for existing backup set")
	}
	return LegacyKeySet(opts.Passphrase, salt)
}
