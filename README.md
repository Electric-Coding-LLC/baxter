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
- Security (current): passphrase-derived key via Argon2id (`BAXTER_PASSPHRASE` or Keychain passphrase).
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
- Initialize config with your real backup roots:
- `./scripts/init-config.sh "/Users/<you>/Documents" "/Users/<you>/Pictures"`
- `backup_roots` entries must be absolute, non-empty paths.
- Schedule fields:
- `schedule = "daily"` requires `daily_time` in `HH:MM` (24-hour local time)
- `schedule = "weekly"` requires `weekly_day` (`sunday`..`saturday`) and `weekly_time` in `HH:MM`
- `schedule = "manual"` disables automatic runs
- Encryption key resolution order:
- `BAXTER_PASSPHRASE` (env override)
- macOS Keychain item from `[encryption]` (`keychain_service` + `keychain_account`)
- Storage backend selection:
- `s3.bucket` empty -> local object storage at `~/Library/Application Support/baxter/objects`
- `s3.bucket` set -> S3 object storage (requires `s3.region`)

## CLI (current)
- `baxter backup run`: scan configured roots, encrypt changed files, and store objects.
- `baxter backup status`: show manifest/object counts.
- `baxter restore list [--prefix path] [--contains text]`: browse/search restoreable paths from the manifest.
- `baxter restore [--dry-run] [--to dir] [--overwrite] <path>`: restore one path from the latest manifest/object store.
- Restore safety defaults:
- existing targets are not overwritten unless `--overwrite` is set
- `--dry-run` shows source and destination without writing files
- `--to` writes under a destination root instead of the original path (escape/traversal outside destination root is rejected)
- Object storage uses local mode or S3 mode based on config.

## Daemon (current)
- `baxterd` runs IPC server on `127.0.0.1:41820` by default.
- Daemon scheduler behavior (from `schedule` in config):
- `manual`: no automatic runs
- `daily`: runs at the same local wall-clock time each day while daemon is running
- `weekly`: runs at the same local weekday/time each week while daemon is running
- `baxterd --once` runs a single backup pass and exits.
- Run once now example:
- `go run ./cmd/baxterd --once`
- Endpoints:
- `GET /v1/status`
  - includes `state`, `last_backup_at`, optional `next_scheduled_at`, and `last_error`
- `POST /v1/backup/run`
- Error responses use JSON: `{"code":"...", "message":"..."}`.

## Compatibility Note
- Encryption payload format is currently version 2 (Argon2id-derived key path).
- This is a breaking change from older payload version 1 data; old encrypted payloads are not decryptable on current `main`.

## Daemon Autostart (macOS)
- Install and start launchd agent:
- `./scripts/install-launchd.sh`
- Uninstall launchd agent:
- `./scripts/uninstall-launchd.sh`
- One-command smoke check:
- `./scripts/smoke-launchd-ipc.sh`
- Installed paths:
- LaunchAgent plist: `~/Library/LaunchAgents/com.electriccoding.baxterd.plist`
- Daemon binary: `~/Library/Application Support/baxter/bin/baxterd`
- Logs:
- `~/Library/Logs/baxterd.out.log`
- `~/Library/Logs/baxterd.err.log`

## First Backup Runbook
- Add key to Keychain (example):
- `security add-generic-password -U -a default -s baxter -w "<your-passphrase>"`
- Initialize config with your backup roots:
- `./scripts/init-config.sh "/Users/<you>/Documents" "/Users/<you>/Pictures"`
- Run a manual backup:
- `baxter backup run`
- Check backup status:
- `baxter backup status`
- Optional restore preview:
- `baxter restore --dry-run "/Users/<you>/Documents/example.txt"`
- If restoring to an alternate root and the target already exists, use:
- `baxter restore --to "/tmp/restore" --overwrite "/Users/<you>/Documents/example.txt"`

## Test Coverage Highlights
- `internal/backup`: manifest and change-plan behavior plus shared backup runner tests.
- `internal/cli`: backup+restore passphrase smoke test, restore path containment checks, and overwrite behavior checks.
- `internal/daemon`: `/v1/status` schedule visibility and `/v1/backup/run` state transition integration tests.
- `cmd/baxterd`: process-level `--once` integration test verifying manifest/object outputs.

## Release
- Local versioned build artifacts:
- `./scripts/release.sh v0.1.0`
- Artifacts are written to:
- `dist/v0.1.0/`
- Tag push triggers GitHub Release workflow:
- `git tag v0.1.0 && git push origin v0.1.0`

## Release Smoke Matrix
- CLI backup/restore:
- `go test ./internal/cli -run TestRunBackupAndRestoreNestedPaths -v`
- `go test ./internal/cli -run TestRunBackupAndRestoreEdgeFilenames -v`
- Daemon API + scheduling contract:
- `go test ./internal/daemon -run TestDaemonErrorContract -v`
- `go test ./internal/daemon -run TestReloadConfigEndpointUpdatesNextScheduledAtWithFixedClock -v`
- `go test ./internal/daemon -run TestDaemonEndToEndReloadScheduledTriggerAndStatus -v`
- `go test ./internal/daemon -run TestRestoreRunEndpoint -v`
- launchd/IPC runtime smoke:
- `./scripts/smoke-launchd-ipc.sh`
- macOS app settings:
- `xcodebuild -project apps/macos/BaxterMenuBarApp.xcodeproj -scheme BaxterMenuBarApp -destination 'platform=macOS' test`
- Manual verification checklist:
- Save settings with `daily_time`/`weekly_day`/`weekly_time` from the Settings UI.
- Verify invalid schedule entries show inline validation and cannot be saved.
- Confirm daemon error alerts display server-provided error messages.

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
- Active development; core backup/restore, daemon IPC/scheduling, macOS menu UI, and integration tests are in place.

## License
MIT.
