package backup

import (
	"crypto/sha256"
	"encoding/hex"
	"path/filepath"
	"testing"

	"baxter/internal/crypto"
	"baxter/internal/storage"
)

func TestVerifyManifestEntriesSuccess(t *testing.T) {
	key := []byte("01234567890123456789012345678901")
	store := storage.NewLocalClient(filepath.Join(t.TempDir(), "objects"))

	entry := ManifestEntry{Path: "/Users/me/Documents/doc.txt"}
	plain := []byte("verify payload")
	sum := sha256.Sum256(plain)
	entry.SHA256 = hex.EncodeToString(sum[:])

	encrypted, err := crypto.EncryptBytes(key, plain)
	if err != nil {
		t.Fatalf("encrypt payload: %v", err)
	}
	if err := store.PutObject(ObjectKeyForPath(entry.Path), encrypted); err != nil {
		t.Fatalf("put object: %v", err)
	}

	result, err := VerifyManifestEntries([]ManifestEntry{entry}, key, store)
	if err != nil {
		t.Fatalf("verify manifest entries: %v", err)
	}
	if result.Checked != 1 || result.OK != 1 || result.HasFailures() {
		t.Fatalf("unexpected result: %+v", result)
	}
}

func TestVerifyManifestEntriesMissingObject(t *testing.T) {
	key := []byte("01234567890123456789012345678901")
	store := storage.NewLocalClient(filepath.Join(t.TempDir(), "objects"))
	entry := ManifestEntry{
		Path:   "/Users/me/Documents/missing.txt",
		SHA256: "does-not-matter",
	}

	result, err := VerifyManifestEntries([]ManifestEntry{entry}, key, store)
	if err != nil {
		t.Fatalf("verify manifest entries: %v", err)
	}
	if result.Missing != 1 || !result.HasFailures() {
		t.Fatalf("expected missing object failure, got %+v", result)
	}
}

func TestVerifyManifestEntriesDecryptAndChecksumFailure(t *testing.T) {
	key := []byte("01234567890123456789012345678901")
	store := storage.NewLocalClient(filepath.Join(t.TempDir(), "objects"))

	decryptFailEntry := ManifestEntry{
		Path:   "/Users/me/Documents/decrypt-fail.txt",
		SHA256: "x",
	}
	if err := store.PutObject(ObjectKeyForPath(decryptFailEntry.Path), []byte("not-encrypted")); err != nil {
		t.Fatalf("put decrypt-fail object: %v", err)
	}

	checksumEntry := ManifestEntry{Path: "/Users/me/Documents/checksum-fail.txt"}
	checksumPlain := []byte("checksum payload")
	checksumEncrypted, err := crypto.EncryptBytes(key, checksumPlain)
	if err != nil {
		t.Fatalf("encrypt checksum payload: %v", err)
	}
	if err := store.PutObject(ObjectKeyForPath(checksumEntry.Path), checksumEncrypted); err != nil {
		t.Fatalf("put checksum object: %v", err)
	}
	checksumEntry.SHA256 = "0000000000000000000000000000000000000000000000000000000000000000"

	result, err := VerifyManifestEntries([]ManifestEntry{decryptFailEntry, checksumEntry}, key, store)
	if err != nil {
		t.Fatalf("verify manifest entries: %v", err)
	}
	if result.DecryptErrors != 1 || result.ChecksumErrors != 1 || !result.HasFailures() {
		t.Fatalf("unexpected failure result: %+v", result)
	}
}
