# Baxter Recovery Progress

Last updated: March 12, 2026

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
| R1 | Remote recovery metadata foundation | in progress | Recovery metadata schema and remote read/write helpers are in place; backup-path integration is still pending. |
| R2 | Remote encrypted manifest snapshots | not started | Upload encrypted snapshot manifests to storage after successful backups. |
| R3 | CLI recovery bootstrap | not started | Fresh machine can reconnect to storage, fetch metadata, and rebuild local cache. |
| R4 | Restore fallback to remote metadata | not started | Restore works when local manifests are missing. |
| R5 | Backup master key wrapping | not started | New backup sets use wrapped master keys instead of direct passphrase-derived object encryption. |
| R6 | Legacy backup-set migration | not started | Existing S3-backed sets gain remote recovery metadata without full reupload. |
| R7 | App recovery UX | not started | Add a first-run `Connect Existing Backup` flow after CLI path is proven. |

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

Current recommended next chunk: `R1 finish + R2`

Why:

- Highest impact on disaster recovery.
- Keeps scope mostly in storage, backup, and metadata code paths.
- Does not require app UX or full crypto migration in the first pass.

## Validation Checklist

- [x] Remote recovery metadata can be written and read.
- [ ] Remote manifest snapshots are encrypted.
- [ ] Successful backup updates remote metadata.
- [ ] Recovery works with missing local manifests.
- [ ] Wrong-passphrase failures are distinguishable from missing-storage failures.
- [ ] Existing legacy backups remain restorable.
