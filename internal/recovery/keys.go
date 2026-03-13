package recovery

import (
	"bytes"
	"fmt"

	"baxter/internal/crypto"
)

type KeySet struct {
	Primary          []byte
	Candidates       [][]byte
	KDFSalt          []byte
	WrappedMasterKey []byte
}

func KeySetFromMetadata(metadata Metadata, passphrase string) (KeySet, error) {
	salt, err := metadata.KDFSalt()
	if err != nil {
		return KeySet{}, err
	}

	directKey := crypto.KeyFromPassphraseWithSalt(passphrase, salt)
	keySet := legacyKeySet(passphrase, salt)
	wrappedMasterKey, err := metadata.WrappedMasterKeyBytes()
	if err != nil {
		return KeySet{}, err
	}
	if len(wrappedMasterKey) == 0 {
		return keySet, nil
	}

	masterKey, err := crypto.UnwrapKey(directKey, wrappedMasterKey)
	if err != nil {
		return KeySet{}, fmt.Errorf("unwrap master key: %w", err)
	}
	keySet.Primary = masterKey
	keySet.Candidates = appendUniqueKeys([][]byte{masterKey}, keySet.Candidates...)
	keySet.WrappedMasterKey = wrappedMasterKey
	return keySet, nil
}

func LegacyKeySet(passphrase string, salt []byte) (KeySet, error) {
	if err := crypto.ValidateKDFSalt(salt); err != nil {
		return KeySet{}, fmt.Errorf("invalid KDF salt: %w", err)
	}
	return legacyKeySet(passphrase, salt), nil
}

func NewWrappedKeySet(passphrase string, salt []byte) (KeySet, error) {
	if err := crypto.ValidateKDFSalt(salt); err != nil {
		return KeySet{}, fmt.Errorf("invalid KDF salt: %w", err)
	}

	keySet := legacyKeySet(passphrase, salt)
	masterKey, err := crypto.NewMasterKey()
	if err != nil {
		return KeySet{}, fmt.Errorf("generate master key: %w", err)
	}

	wrappedMasterKey, err := crypto.WrapKey(keySet.Primary, masterKey)
	if err != nil {
		return KeySet{}, fmt.Errorf("wrap master key: %w", err)
	}
	keySet.Primary = masterKey
	keySet.Candidates = appendUniqueKeys([][]byte{masterKey}, keySet.Candidates...)
	keySet.WrappedMasterKey = wrappedMasterKey
	return keySet, nil
}

func legacyKeySet(passphrase string, salt []byte) KeySet {
	primary := crypto.KeyFromPassphraseWithSalt(passphrase, salt)
	legacy := crypto.KeyFromPassphrase(passphrase)
	return KeySet{
		Primary:    primary,
		Candidates: appendUniqueKeys([][]byte{primary}, legacy),
		KDFSalt:    append([]byte(nil), salt...),
	}
}

func appendUniqueKeys(keys [][]byte, extra ...[]byte) [][]byte {
	out := make([][]byte, 0, len(keys)+len(extra))
	for _, key := range keys {
		if len(key) == 0 || containsKey(out, key) {
			continue
		}
		out = append(out, append([]byte(nil), key...))
	}
	for _, key := range extra {
		if len(key) == 0 || containsKey(out, key) {
			continue
		}
		out = append(out, append([]byte(nil), key...))
	}
	return out
}

func containsKey(keys [][]byte, candidate []byte) bool {
	for _, key := range keys {
		if bytes.Equal(key, candidate) {
			return true
		}
	}
	return false
}
