package crypto

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"errors"
	"io"

	"golang.org/x/crypto/argon2"
)

const (
	payloadVersion   byte = 2
	nonceSize             = 12
	derivedKeyLength      = 32
	kdfSaltLength         = 16
)

var (
	legacyKDFSalt        = []byte("baxter/argon2id/v1")
	kdfIterations uint32 = 3
	kdfMemoryKiB  uint32 = 64 * 1024
	kdfThreads    uint8  = 4
)

func KeyFromPassphrase(passphrase string) []byte {
	return KeyFromPassphraseWithSalt(passphrase, legacyKDFSalt)
}

func KeyFromPassphraseWithSalt(passphrase string, salt []byte) []byte {
	return argon2.IDKey([]byte(passphrase), salt, kdfIterations, kdfMemoryKiB, kdfThreads, derivedKeyLength)
}

func NewKDFSalt() ([]byte, error) {
	salt := make([]byte, kdfSaltLength)
	if _, err := io.ReadFull(rand.Reader, salt); err != nil {
		return nil, err
	}
	return salt, nil
}

func ValidateKDFSalt(salt []byte) error {
	if len(salt) != kdfSaltLength {
		return errors.New("invalid KDF salt length")
	}
	return nil
}

func DecryptBytesWithAnyKey(keys [][]byte, payload []byte) ([]byte, error) {
	var lastErr error
	for _, key := range keys {
		if len(key) == 0 {
			continue
		}
		plain, err := DecryptBytes(key, payload)
		if err == nil {
			return plain, nil
		}
		lastErr = err
	}
	if lastErr != nil {
		return nil, lastErr
	}
	return nil, errors.New("no encryption keys provided")
}

func EncryptBytes(key []byte, plaintext []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}

	nonce := make([]byte, nonceSize)
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, err
	}

	ciphertext := gcm.Seal(nil, nonce, plaintext, nil)
	payload := make([]byte, 1+nonceSize+len(ciphertext))
	payload[0] = payloadVersion
	copy(payload[1:1+nonceSize], nonce)
	copy(payload[1+nonceSize:], ciphertext)
	return payload, nil
}

func DecryptBytes(key []byte, payload []byte) ([]byte, error) {
	if len(payload) < 1+nonceSize {
		return nil, errors.New("payload too short")
	}
	if payload[0] != payloadVersion {
		return nil, errors.New("unsupported payload version")
	}

	nonce := payload[1 : 1+nonceSize]
	ciphertext := payload[1+nonceSize:]

	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}

	plaintext, err := gcm.Open(nil, nonce, ciphertext, nil)
	if err != nil {
		return nil, err
	}
	return plaintext, nil
}
