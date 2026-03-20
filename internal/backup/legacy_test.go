package backup

import (
	"os"
	"path/filepath"
	"testing"

	"baxter/internal/storage"
)

func TestAllowCreateWrappedKeyWithoutMetadataTreatsSaltOnlyStateAsFresh(t *testing.T) {
	rootDir := t.TempDir()
	manifestPath := filepath.Join(rootDir, "manifest.json")
	snapshotDir := filepath.Join(rootDir, "manifests")
	saltPath := filepath.Join(rootDir, "kdf_salt.bin")

	if err := os.WriteFile(saltPath, []byte("0123456789abcdef"), 0o600); err != nil {
		t.Fatalf("write salt: %v", err)
	}

	allowed, err := AllowCreateWrappedKeyWithoutMetadata(
		manifestPath,
		snapshotDir,
		saltPath,
		storage.NewLocalClient(filepath.Join(rootDir, "objects")),
	)
	if err != nil {
		t.Fatalf("AllowCreateWrappedKeyWithoutMetadata() error = %v", err)
	}
	if !allowed {
		t.Fatal("expected salt-only state to allow fresh wrapped key creation")
	}
}

func TestAllowCreateWrappedKeyWithoutMetadataRejectsExistingStoreKeysWithoutMetadata(t *testing.T) {
	rootDir := t.TempDir()
	manifestPath := filepath.Join(rootDir, "manifest.json")
	snapshotDir := filepath.Join(rootDir, "manifests")
	saltPath := filepath.Join(rootDir, "kdf_salt.bin")
	store := storage.NewLocalClient(filepath.Join(rootDir, "objects"))

	if err := os.WriteFile(saltPath, []byte("0123456789abcdef"), 0o600); err != nil {
		t.Fatalf("write salt: %v", err)
	}
	if err := store.PutObject("system/recovery.json", []byte("metadata")); err != nil {
		t.Fatalf("put object: %v", err)
	}

	allowed, err := AllowCreateWrappedKeyWithoutMetadata(manifestPath, snapshotDir, saltPath, store)
	if err != nil {
		t.Fatalf("AllowCreateWrappedKeyWithoutMetadata() error = %v", err)
	}
	if allowed {
		t.Fatal("expected existing store keys to require recovery metadata")
	}
}
