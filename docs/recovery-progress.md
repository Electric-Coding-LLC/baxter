# Baxter Recovery Progress

Last updated: March 13, 2026

Purpose: track the work needed to make Baxter recoverable on a new machine using storage access + passphrase, without depending on machine-local state.

## Target Outcome

Desired recovery flow:

1. Install Baxter on a new machine.
2. Connect Baxter to the backup storage.
3. Enter the encryption passphrase.
4. Download recovery metadata and manifests from storage.
5. Browse and restore files.

## Current Gap

Today recovery depends on local-only state under `~/Library/Application Support/baxter/`, especially:

- `config.toml`
- `kdf_salt.bin`
- `manifest.json`
- `manifests/`

That means losing the machine can also mean losing the metadata needed to restore from S3-backed objects.

## Work Streams

| ID | Work Stream | Status | Notes |
| --- | --- | --- | --- |
| R1 | Remote recovery metadata foundation | done | Recovery metadata schema, storage key, tests, and backup-path updates are in place. |
| R2 | Remote encrypted manifest snapshots | done | Successful backups now upload encrypted snapshot manifests and update remote recovery metadata with the latest snapshot ID. |
| R3 | CLI recovery bootstrap | done | `baxter recovery bootstrap` now fetches remote recovery metadata, derives keys from the remote salt, downloads the latest encrypted snapshot manifest, and rebuilds local cache state. |
| R4 | Restore fallback to remote metadata | done | Shared manifest loading now falls back to remote recovery metadata and rehydrates local cache when local restore state is missing or stale. |
| R5 | Backup master key wrapping | done | New backups now generate wrapped master keys, encrypt objects/manifests with them, and resolve them through recovery metadata with legacy decrypt fallback. |
| R6 | Legacy backup-set migration | done | Existing S3-backed sets now adopt recovery metadata and wrapped keys on the next backup without reuploading unchanged objects, while keeping legacy decrypt fallback. |
| R7 | App recovery UX | done | The macOS app now offers `Connect Existing Backup`, saves the passphrase to the configured keychain item, bootstraps recovery metadata through the CLI helper, and lands in Restore. |

Status values:

- `not started`
- `in progress`
- `blocked`
- `done`

## Execution Order

### R1. Remote Recovery Metadata Foundation

Goal: storage can describe a backup set without relying on local Baxter state.

Expected scope:

- Add a recovery metadata schema.
- Store it under a deterministic storage key.
- Include backup set ID, format version, KDF salt, KDF params, and latest snapshot ID.
- Add read/write helpers and tests.

Definition of done:

- Baxter can write and read a recovery metadata document from configured object storage.
- Metadata round-trip has automated coverage.

### R2. Remote Encrypted Manifest Snapshots

Goal: restore metadata survives machine loss.

Expected scope:

- Upload encrypted snapshot manifests after successful backups.
- Update remote recovery metadata with latest snapshot pointer.
- Keep local manifests as cache, not sole source of truth.

Definition of done:

- Every successful S3-backed backup writes remote encrypted snapshot metadata.
- Deleting local manifests does not destroy the only copy of restore metadata.

### R3. CLI Recovery Bootstrap

Goal: a fresh machine can reconstruct enough local state to restore.

Expected scope:

- Add a CLI recovery command.
- Validate storage access.
- Fetch remote recovery metadata.
- Derive keys from passphrase + remote salt.
- Download latest manifest metadata and rebuild local cache.

Definition of done:

- A clean machine with empty Baxter state can run recovery bootstrap and then restore.

### R4. Restore Fallback To Remote Metadata

Goal: restore succeeds even if local cache is absent or stale.

Expected scope:

- Shared manifest loader tries local state first, then remote metadata.
- Successful remote fetch hydrates local cache.

Definition of done:

- CLI and daemon restore paths both work with missing local manifest files.

### R5. Backup Master Key Wrapping

Goal: new backup sets do not depend on machine-local salt files for future recovery.

Expected scope:

- Introduce a random backup master key.
- Derive a KEK from passphrase + remote salt.
- Store wrapped master key in recovery metadata.
- Encrypt new objects/manifests with the master key.

Definition of done:

- New backup sets are recoverable using storage config + passphrase only.

### R6. Legacy Backup-Set Migration

Goal: current dogfood data does not get stranded.

Expected scope:

- Detect legacy local-only backup sets.
- On next backup, upload remote recovery metadata using the existing salt.
- Upload remote encrypted manifests for old sets.
- Preserve legacy decrypt support.

Definition of done:

- Existing S3-backed backup sets can recover without copying local manifests by hand.

### R7. App Recovery UX

Goal: the app can onboard a new machine into an existing backup set.

Expected scope:

- Add `Connect Existing Backup`.
- Prompt for storage config and passphrase.
- Validate access and unlock the backup set.
- Open restore UI after metadata sync.

Definition of done:

- New-machine recovery is possible from the app without CLI-only steps.

## Risks And Open Questions

- Manifest privacy: remote manifests must be encrypted because they reveal filenames and paths.
- Storage API shape: `ObjectStore` likely needs prefix-aware listing helpers.
- Migration boundary: legacy objects should remain readable during and after migration.
- Passphrase handling: passphrase should never be stored in recovery metadata.
- Local mode: local-only storage will still not protect against machine loss.

## Decision Log

| Date | Decision | Notes |
| --- | --- | --- |
| 2026-03-10 | Recovery direction is storage access + passphrase, not local-state copy | Local manifests and `kdf_salt.bin` should no longer be mandatory for disaster recovery. |
| 2026-03-10 | CLI recovery path should come before app recovery UX | Easier to validate end-to-end before building UI. |
| 2026-03-10 | Start with remote encrypted manifests before master-key migration | Highest-value reduction in recovery risk with lower implementation blast radius. |

## Next Chunk

Current recommended next chunk: `none`

Why:

- R7 is now complete.
- The app can onboard an existing backup set without CLI-only recovery steps.
- The recovery roadmap items in this document are complete.

## Validation Checklist

- [x] Remote recovery metadata can be written and read.
- [x] Remote manifest snapshots are encrypted.
- [x] Successful backup updates remote metadata.
- [x] Recovery bootstrap can rebuild local manifests and salt from storage metadata.
- [x] Wrong-passphrase failures are distinguishable from missing-storage failures during bootstrap.
- [x] Restore paths self-heal from remote recovery metadata when local manifest cache is missing or stale.
- [x] New backups write wrapped master keys to recovery metadata and use them for object + remote manifest encryption.
- [x] Existing legacy backups remain restorable.
