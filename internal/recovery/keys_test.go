package recovery

import (
	"bytes"
	"testing"
	"time"

	"baxter/internal/crypto"
)

func TestKeySetFromMetadataUsesWrappedMasterKey(t *testing.T) {
	salt, err := crypto.NewKDFSalt()
	if err != nil {
		t.Fatalf("generate salt: %v", err)
	}

	created, err := NewWrappedKeySet("wrapped-passphrase", salt)
	if err != nil {
		t.Fatalf("create wrapped key set: %v", err)
	}
	metadata, err := NewMetadata("primary", salt, "snapshot-1", created.WrappedMasterKey, time.Date(2026, time.March, 13, 1, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatalf("new metadata: %v", err)
	}

	resolved, err := KeySetFromMetadata(metadata, "wrapped-passphrase")
	if err != nil {
		t.Fatalf("resolve key set: %v", err)
	}
	if !bytes.Equal(resolved.Primary, created.Primary) {
		t.Fatal("primary key mismatch")
	}
	if len(resolved.Candidates) < 2 {
		t.Fatalf("expected wrapped and fallback candidates, got %d", len(resolved.Candidates))
	}
	if !bytes.Equal(resolved.Candidates[0], created.Primary) {
		t.Fatal("wrapped master key should be first decrypt candidate")
	}
}

func TestKeySetFromMetadataFallsBackToDirectKey(t *testing.T) {
	salt, err := crypto.NewKDFSalt()
	if err != nil {
		t.Fatalf("generate salt: %v", err)
	}

	metadata, err := NewMetadata("primary", salt, "snapshot-1", nil, time.Date(2026, time.March, 13, 1, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatalf("new metadata: %v", err)
	}

	resolved, err := KeySetFromMetadata(metadata, "wrapped-passphrase")
	if err != nil {
		t.Fatalf("resolve key set: %v", err)
	}
	direct := crypto.KeyFromPassphraseWithSalt("wrapped-passphrase", salt)
	if !bytes.Equal(resolved.Primary, direct) {
		t.Fatal("expected direct passphrase-derived key")
	}
}
