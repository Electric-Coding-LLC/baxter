package crypto

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"testing"
)

func TestEncryptDecryptRoundTrip(t *testing.T) {
	key := KeyFromPassphrase("secret-passphrase")
	plain := []byte("backup payload")

	payload, err := EncryptBytes(key, plain)
	if err != nil {
		t.Fatalf("encrypt failed: %v", err)
	}
	if payload[0] != payloadVersionV3 {
		t.Fatalf("payload version mismatch: got %d want %d", payload[0], payloadVersionV3)
	}

	got, err := DecryptBytes(key, payload)
	if err != nil {
		t.Fatalf("decrypt failed: %v", err)
	}

	if string(got) != string(plain) {
		t.Fatalf("roundtrip mismatch: got %q want %q", string(got), string(plain))
	}
}

func TestDecryptWithWrongKeyFails(t *testing.T) {
	keyA := KeyFromPassphrase("a")
	keyB := KeyFromPassphrase("b")

	payload, err := EncryptBytes(keyA, []byte("x"))
	if err != nil {
		t.Fatalf("encrypt failed: %v", err)
	}

	if _, err := DecryptBytes(keyB, payload); err == nil {
		t.Fatal("expected decrypt failure with wrong key")
	}
}

func TestDecryptRejectsLegacyPayloadVersion(t *testing.T) {
	key := KeyFromPassphrase("secret-passphrase")
	plain := []byte("backup payload")

	payload, err := EncryptBytes(key, plain)
	if err != nil {
		t.Fatalf("encrypt failed: %v", err)
	}

	payload[0] = 1
	if _, err := DecryptBytes(key, payload); err == nil {
		t.Fatal("expected decrypt failure for legacy payload version")
	}
}

func TestDecryptSupportsV2Payloads(t *testing.T) {
	key := KeyFromPassphrase("secret-passphrase")
	plain := []byte("legacy backup payload")

	payload, err := encryptV2ForTest(key, plain)
	if err != nil {
		t.Fatalf("encrypt failed: %v", err)
	}

	got, err := DecryptBytes(key, payload)
	if err != nil {
		t.Fatalf("decrypt failed: %v", err)
	}
	if string(got) != string(plain) {
		t.Fatalf("roundtrip mismatch: got %q want %q", string(got), string(plain))
	}
}

func TestEncryptUsesGzipWhenBeneficial(t *testing.T) {
	key := KeyFromPassphrase("secret-passphrase")
	plain := bytes.Repeat([]byte("baxter-baxter-baxter-"), 256)

	payload, err := EncryptBytes(key, plain)
	if err != nil {
		t.Fatalf("encrypt failed: %v", err)
	}
	if payload[1] != compressionGzip {
		t.Fatalf("expected gzip compression metadata, got %d", payload[1])
	}

	got, err := DecryptBytes(key, payload)
	if err != nil {
		t.Fatalf("decrypt failed: %v", err)
	}
	if !bytes.Equal(got, plain) {
		t.Fatal("decrypted plaintext mismatch")
	}
}

func TestEncryptFallsBackToNoCompressionWhenNotBeneficial(t *testing.T) {
	key := KeyFromPassphrase("secret-passphrase")
	raw := bytes.Repeat([]byte("baxter-compression-check-"), 128)
	alreadyCompressed, err := gzipCompress(raw)
	if err != nil {
		t.Fatalf("compress fixture failed: %v", err)
	}

	payload, err := EncryptBytes(key, alreadyCompressed)
	if err != nil {
		t.Fatalf("encrypt failed: %v", err)
	}
	if payload[1] != compressionNone {
		t.Fatalf("expected no compression metadata, got %d", payload[1])
	}

	got, err := DecryptBytes(key, payload)
	if err != nil {
		t.Fatalf("decrypt failed: %v", err)
	}
	if !bytes.Equal(got, alreadyCompressed) {
		t.Fatal("decrypted plaintext mismatch")
	}
}

func TestDecryptRejectsUnknownCompressionAlgorithm(t *testing.T) {
	key := KeyFromPassphrase("secret-passphrase")
	payload, err := EncryptBytes(key, []byte("backup payload"))
	if err != nil {
		t.Fatalf("encrypt failed: %v", err)
	}

	payload[1] = 99
	if _, err := DecryptBytes(key, payload); err == nil {
		t.Fatal("expected decrypt failure for unsupported compression algorithm")
	}
}

func encryptV2ForTest(key []byte, plaintext []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}

	nonce := make([]byte, nonceSize)
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}

	ciphertext := gcm.Seal(nil, nonce, plaintext, nil)
	payload := make([]byte, 1+nonceSize+len(ciphertext))
	payload[0] = payloadVersionV2
	copy(payload[1:1+nonceSize], nonce)
	copy(payload[1+nonceSize:], ciphertext)
	return payload, nil
}
