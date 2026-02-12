package backup

import (
	"fmt"
	"os"
	"strings"

	"baxter/internal/crypto"
	"baxter/internal/storage"
)

type VerifyResult struct {
	Checked        int
	OK             int
	Missing        int
	ReadErrors     int
	DecryptErrors  int
	ChecksumErrors int
}

func (r VerifyResult) HasFailures() bool {
	return r.Missing > 0 || r.ReadErrors > 0 || r.DecryptErrors > 0 || r.ChecksumErrors > 0
}

func VerifyManifestEntries(entries []ManifestEntry, key []byte, store storage.ObjectStore) (VerifyResult, error) {
	return VerifyManifestEntriesWithKeys(entries, [][]byte{key}, store)
}

func VerifyManifestEntriesWithKeys(entries []ManifestEntry, keys [][]byte, store storage.ObjectStore) (VerifyResult, error) {
	if len(keys) == 0 {
		return VerifyResult{}, fmt.Errorf("at least one encryption key is required")
	}
	if store == nil {
		return VerifyResult{}, fmt.Errorf("object store is required")
	}

	validKeys := make([][]byte, 0, len(keys))
	for _, key := range keys {
		if len(key) == 0 {
			continue
		}
		validKeys = append(validKeys, key)
	}
	if len(validKeys) == 0 {
		return VerifyResult{}, fmt.Errorf("at least one non-empty encryption key is required")
	}

	result := VerifyResult{Checked: len(entries)}
	for _, entry := range entries {
		payload, err := store.GetObject(ObjectKeyForPath(entry.Path))
		if err != nil {
			if isMissingObjectError(err) {
				result.Missing++
			} else {
				result.ReadErrors++
			}
			continue
		}

		plain, err := crypto.DecryptBytesWithAnyKey(validKeys, payload)
		if err != nil {
			result.DecryptErrors++
			continue
		}
		if err := VerifyEntryContent(entry, plain); err != nil {
			result.ChecksumErrors++
			continue
		}
		result.OK++
	}

	return result, nil
}

func isMissingObjectError(err error) bool {
	if err == nil {
		return false
	}
	if os.IsNotExist(err) {
		return true
	}
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "no such key") ||
		strings.Contains(msg, "not found") ||
		strings.Contains(msg, "404")
}
