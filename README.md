# baxter

A simple, secure macOS backup utility with an S3 backend.

## Goals
- Simple, low-friction backups for personal use.
- Client-side encryption before upload.
- Incremental backups with a local manifest.
- Native macOS experience (menu bar UI + background service).

## Architecture (proposed)
- Service (daemon): schedules backups, scans files, encrypts, compresses, and uploads to S3.
- Menu bar app: shows status, last backup, errors, and lets you trigger/configure backups.
- Storage: S3-compatible backend (AWS S3 or compatible providers).
- Security: passphrase-derived key stored in macOS Keychain.

## Initial Scope (MVP)
- Configure backup roots.
- Run manual backup.
- Scheduled backups (daily/weekly).
- Incremental upload using a local manifest.
- End-to-end encryption.
- Restore a file or folder.

## Defaults
- Minimum macOS: Tahoe 26.2.
- Config format: TOML.
- Config + state: `~/Library/Application Support/baxter`.

## Config
- Default path: `~/Library/Application Support/baxter/config.toml`
- Example: `config.example.toml`

## First Week Plan
1. Implement config parsing + validation; design TOML schema.
2. Build file scanner + manifest format (hashing, change detection).
3. Implement encryption + compression pipeline.
4. Add S3 upload/download (multipart upload, retries).
5. Create a basic CLI for manual backup and restore.
6. Wire menu bar UI to daemon and show status.

## Repo Layout
- `cmd/baxterd`: daemon entrypoint.
- `internal/config`: config types and loading.
- `internal/backup`: scan + planning.
- `internal/crypto`: encryption + key handling.
- `internal/storage`: S3 integration.
- `apps/macos`: menu bar app.

## Status
- Planning.

## License
MIT.
