package recovery

import (
	"bytes"
	"testing"
	"time"

	"baxter/internal/crypto"
	"baxter/internal/storage"
)

func TestResolveKeySetAdoptsWrappedKeyForLegacyMetadata(t *testing.T) {
	salt, err := crypto.NewKDFSalt()
	if err != nil {
		t.Fatalf("generate salt: %v", err)
	}

	metadata, err := NewMetadata("primary", salt, "snapshot-1", nil, time.Date(2026, time.March, 13, 2, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatalf("new metadata: %v", err)
	}

	store := storage.NewLocalClient(t.TempDir())
	if err := WriteMetadata(store, metadata); err != nil {
		t.Fatalf("write metadata: %v", err)
	}

	keySet, err := ResolveKeySet(ResolveKeySetOptions{
		Store:                    store,
		BackupSetID:              "primary",
		Passphrase:               "legacy-passphrase",
		AdoptWrappedKeyIfMissing: true,
	})
	if err != nil {
		t.Fatalf("resolve key set: %v", err)
	}
	if len(keySet.WrappedMasterKey) == 0 {
		t.Fatal("expected wrapped master key for adopted legacy metadata")
	}
	if !bytes.Equal(keySet.KDFSalt, salt) {
		t.Fatal("kdf salt mismatch")
	}

	direct := crypto.KeyFromPassphraseWithSalt("legacy-passphrase", salt)
	if bytes.Equal(keySet.Primary, direct) {
		t.Fatal("expected adopted primary key to differ from direct legacy key")
	}

	foundDirect := false
	for _, candidate := range keySet.Candidates {
		if bytes.Equal(candidate, direct) {
			foundDirect = true
			break
		}
	}
	if !foundDirect {
		t.Fatal("expected legacy direct key in decrypt candidates")
	}
}
