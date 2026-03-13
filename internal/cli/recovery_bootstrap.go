package cli

import (
	"fmt"

	"baxter/internal/config"
	"baxter/internal/recoverycache"
	"baxter/internal/storage"
)

type recoveryBootstrapResult struct {
	SnapshotID string
	Entries    int
}

func runRecoveryBootstrap(cfg *config.Config) error {
	store, err := objectStoreFromConfig(cfg)
	if err != nil {
		return err
	}

	result, err := bootstrapRecoveryCache(cfg, store)
	if err != nil {
		return err
	}

	fmt.Printf(
		"recovery bootstrap complete: snapshot=%s entries=%d\n",
		result.SnapshotID,
		result.Entries,
	)
	return nil
}

func bootstrapRecoveryCache(cfg *config.Config, store storage.ObjectStore) (recoveryBootstrapResult, error) {
	if store == nil {
		return recoveryBootstrapResult{}, fmt.Errorf("object store is required")
	}

	result, err := recoverycache.HydrateLatest(cfg, store, func() (string, error) {
		return encryptionPassphrase(cfg)
	})
	if err != nil {
		return recoveryBootstrapResult{}, err
	}

	return recoveryBootstrapResult{
		SnapshotID: result.SnapshotID,
		Entries:    len(result.Manifest.Entries),
	}, nil
}
