package crypto

import (
	"bytes"
	"compress/gzip"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"errors"
	"io"

	"golang.org/x/crypto/argon2"
)

const (
	payloadVersionV2 byte = 2
	payloadVersionV3 byte = 3
	compressionNone  byte = 0
	compressionGzip  byte = 1
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
	prepared, compression, err := maybeCompressForEncryption(plaintext)
	if err != nil {
		return nil, err
	}

	nonce, ciphertext, err := encryptPayload(key, prepared)
	if err != nil {
		return nil, err
	}

	payload := make([]byte, 2+nonceSize+len(ciphertext))
	payload[0] = payloadVersionV3
	payload[1] = compression
	copy(payload[2:2+nonceSize], nonce)
	copy(payload[2+nonceSize:], ciphertext)
	return payload, nil
}

func DecryptBytes(key []byte, payload []byte) ([]byte, error) {
	if len(payload) < 1 {
		return nil, errors.New("payload too short")
	}

	switch payload[0] {
	case payloadVersionV2:
		if len(payload) < 1+nonceSize {
			return nil, errors.New("payload too short")
		}
		return decryptPayload(key, payload[1:1+nonceSize], payload[1+nonceSize:])
	case payloadVersionV3:
		if len(payload) < 2+nonceSize {
			return nil, errors.New("payload too short")
		}
		plain, err := decryptPayload(key, payload[2:2+nonceSize], payload[2+nonceSize:])
		if err != nil {
			return nil, err
		}
		return decompressAfterDecryption(payload[1], plain)
	default:
		return nil, errors.New("unsupported payload version")
	}
}

func maybeCompressForEncryption(plaintext []byte) ([]byte, byte, error) {
	compressed, err := gzipCompress(plaintext)
	if err != nil {
		return nil, 0, err
	}
	if len(compressed) >= len(plaintext) {
		return plaintext, compressionNone, nil
	}
	return compressed, compressionGzip, nil
}

func decompressAfterDecryption(compression byte, plaintext []byte) ([]byte, error) {
	switch compression {
	case compressionNone:
		return plaintext, nil
	case compressionGzip:
		return gzipDecompress(plaintext)
	default:
		return nil, errors.New("unsupported compression algorithm")
	}
}

func gzipCompress(plaintext []byte) ([]byte, error) {
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	if _, err := gz.Write(plaintext); err != nil {
		_ = gz.Close()
		return nil, err
	}
	if err := gz.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func gzipDecompress(compressed []byte) ([]byte, error) {
	gz, err := gzip.NewReader(bytes.NewReader(compressed))
	if err != nil {
		return nil, err
	}
	defer gz.Close()
	return io.ReadAll(gz)
}

func encryptPayload(key []byte, plaintext []byte) ([]byte, []byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, nil, err
	}

	nonce := make([]byte, nonceSize)
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, nil, err
	}

	ciphertext := gcm.Seal(nil, nonce, plaintext, nil)
	return nonce, ciphertext, nil
}

func decryptPayload(key []byte, nonce []byte, ciphertext []byte) ([]byte, error) {
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
