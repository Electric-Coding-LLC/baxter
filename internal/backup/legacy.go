package backup

import (
	"os"

	"baxter/internal/storage"
)

func AllowCreateWrappedKeyWithoutMetadata(manifestPath, snapshotDir, saltPath string, store storage.ObjectStore) (bool, error) {
	snapshots, err := ListSnapshotManifests(snapshotDir)
	if err != nil {
		return false, err
	}
	keys, err := store.ListKeys()
	if err != nil {
		return false, err
	}

	hasManifest := fileExists(manifestPath)
	hasSnapshots := len(snapshots) > 0
	hasSalt := fileExists(saltPath)
	hasRemoteData := len(FilterDataObjectKeys(keys)) > 0

	isFresh := !hasManifest && !hasSnapshots && len(keys) == 0
	canMigrateLegacy := hasManifest && hasSalt && hasRemoteData
	return isFresh || canMigrateLegacy, nil
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
