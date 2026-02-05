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
- Security (current): passphrase-derived key from `BAXTER_PASSPHRASE` for CLI operations.
- IPC: local HTTP daemon API at `127.0.0.1:41820` for UI status and run triggers.

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
- Encryption key resolution order:
- `BAXTER_PASSPHRASE` (env override)
- macOS Keychain item from `[encryption]` (`keychain_service` + `keychain_account`)
- Storage backend selection:
- `s3.bucket` empty -> local object storage at `~/Library/Application Support/baxter/objects`
- `s3.bucket` set -> S3 object storage (requires `s3.region`)

## CLI (current)
- `baxter backup run`: scan configured roots, encrypt changed files, and store objects.
- `baxter backup status`: show manifest/object counts.
- `baxter restore [--dry-run] [--to dir] [--overwrite] <path>`: restore one path from the latest manifest/object store.
- Restore safety defaults:
- existing targets are not overwritten unless `--overwrite` is set
- `--dry-run` shows source and destination without writing files
- `--to` writes under a destination root instead of the original path
- Object storage uses local mode or S3 mode based on config.

## Daemon (current)
- `baxterd` runs IPC server on `127.0.0.1:41820` by default.
- `baxterd --once` runs a single backup pass and exits.
- Endpoints:
- `GET /v1/status`
- `POST /v1/backup/run`

## Daemon Autostart (macOS)
- Install and start launchd agent:
- `./scripts/install-launchd.sh`
- Uninstall launchd agent:
- `./scripts/uninstall-launchd.sh`
- Installed paths:
- LaunchAgent plist: `~/Library/LaunchAgents/com.electriccoding.baxterd.plist`
- Daemon binary: `~/Library/Application Support/baxter/bin/baxterd`
- Logs:
- `~/Library/Logs/baxterd.out.log`
- `~/Library/Logs/baxterd.err.log`

## First Week Plan
1. Implement config parsing + validation; design TOML schema.
2. Build file scanner + manifest format (hashing, change detection).
3. Implement encryption + compression pipeline.
4. Add S3 upload/download (multipart upload, retries).
5. Create a basic CLI for manual backup and restore.
6. Wire menu bar UI to daemon and show status.

## Repo Layout
- `cmd/baxter`: CLI entrypoint.
- `cmd/baxterd`: daemon entrypoint.
- `internal/cli`: command handlers.
- `internal/config`: config types and loading.
- `internal/backup`: scan + planning.
- `internal/crypto`: encryption + key handling.
- `internal/state`: app config/state paths.
- `internal/storage`: S3 integration.
- `apps/macos`: menu bar app.

## Status
- Planning.

## License
MIT.
