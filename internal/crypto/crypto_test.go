package crypto

import "testing"

func TestEncryptDecryptRoundTrip(t *testing.T) {
	key := KeyFromPassphrase("secret-passphrase")
	plain := []byte("backup payload")

	payload, err := EncryptBytes(key, plain)
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
