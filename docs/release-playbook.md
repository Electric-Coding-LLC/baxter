# Baxter Release Playbook

This playbook defines the supported distribution path for Baxter CLI + daemon + macOS app, along with upgrade and rollback procedures.

## Supported Install Path (macOS)

1. Download release artifacts (`Baxter-darwin-arm64.zip`, `SHA256SUMS`).
2. Verify checksums:
   - `shasum -a 256 -c SHA256SUMS`
3. Install the menu bar app:
   - `ditto -x -k Baxter-darwin-arm64.zip /Applications`
4. Launch `/Applications/Baxter.app`.
5. Save or update config in the app Settings UI (`~/Library/Application Support/baxter/config.toml`).
6. Use `Start Baxter` in the app. The packaged app now installs bundled `baxter`/`baxterd` helpers into `~/Library/Application Support/baxter/bin` and bootstraps the per-user launchd agent.
7. Run smoke validation:
   - open the app and confirm status transitions to `Running`, or
   - `curl -s http://127.0.0.1:41820/v1/status`

Notes:
- `Baxter-darwin-arm64.zip` is an unsigned developer artifact today and may require standard macOS confirmation steps when launched outside Xcode.
- CLI + daemon artifacts remain available for manual installs, RC validation, and rollback workflows.
- If you use a named AWS profile, set `aws_profile = "your-profile"` in `~/Library/Application Support/baxter/config.toml`. The app and launchd installer now propagate that saved profile name into the daemon install path, so Finder launches do not need shell-only `AWS_PROFILE` exports.

## Supported Upgrade Path

1. Stop daemon cleanly:
   - use `Stop Baxter` in the app, or
   - `launchctl bootout "gui/$(id -u)/com.electriccoding.baxterd"`
2. Snapshot current install for rollback:
   - `cp "$HOME/Library/Application Support/baxter/bin/baxter" "$HOME/Library/Application Support/baxter/bin/baxter.prev"`
   - `cp "$HOME/Library/Application Support/baxter/bin/baxterd" "$HOME/Library/Application Support/baxter/bin/baxterd.prev"`
3. Replace the menu bar app:
   - `ditto -x -k Baxter-darwin-arm64.zip /Applications`
4. Launch the new app and use `Start Baxter` to refresh the installed helpers and restart the daemon.
5. Run smoke validation:
   - `curl -s http://127.0.0.1:41820/v1/status`

Upgrade guarantees:
- `~/Library/Application Support/baxter/config.toml` is preserved.
- Manifest/object state under `~/Library/Application Support/baxter/` is preserved.

## Rollback Procedure

Use rollback when smoke checks fail after upgrade.

1. Stop daemon:
   - use `Stop Baxter` in the app, or
   - `launchctl bootout "gui/$(id -u)/com.electriccoding.baxterd"`
2. Restore previous binaries:
   - `install -m 0755 "$HOME/Library/Application Support/baxter/bin/baxter.prev" "$HOME/Library/Application Support/baxter/bin/baxter"`
   - `install -m 0755 "$HOME/Library/Application Support/baxter/bin/baxterd.prev" "$HOME/Library/Application Support/baxter/bin/baxterd"`
3. Reinstall the previous app bundle if needed from your saved copy.
4. Start daemon:
   - relaunch the restored app and use `Start Baxter`, or
   - `launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.electriccoding.baxterd.plist"`
5. Re-run smoke check:
   - `curl -s http://127.0.0.1:41820/v1/status`

## Release Checklist

1. Security + tests:
   - `go install golang.org/x/vuln/cmd/govulncheck@latest`
   - `govulncheck ./...`
   - `go test ./...`
2. Targeted smoke matrix:
   - `go test ./internal/cli -run TestRunBackupAndRestoreNestedPaths -v`
   - `go test ./internal/cli -run TestRunBackupAndRestoreEdgeFilenames -v`
   - `go test ./internal/daemon -run TestDaemonErrorContract -v`
   - `go test ./internal/daemon -run TestRestoreRunEndpoint -v`
   - `./scripts/upgrade-preservation-smoke.sh --before /path/to/baxter-before --after /path/to/baxter-after`
   - `./scripts/smoke-launchd-ipc.sh`
3. macOS app tests:
   - `xcodebuild -project apps/macos/BaxterApp.xcodeproj -scheme BaxterApp -destination 'platform=macOS' test`
4. Build artifacts locally:
   - `./scripts/release.sh vX.Y.Z`
   - on macOS, this now also produces `Baxter-darwin-arm64.zip` with bundled `baxter`/`baxterd` helpers
5. Tag and publish:
   - `git tag vX.Y.Z && git push origin vX.Y.Z`

## Release Candidate Cut

For RC builds without publishing a tag-based release, use the `Release Candidate` workflow.

1. Start the workflow:
   - `gh workflow run "Release Candidate" -f version=v0.4.0-rc1`
2. Wait for completion:
   - `gh run watch`
3. Download artifacts from the workflow run and run the install/upgrade smoke path above.
4. The workflow now also uploads `Baxter-darwin-arm64.zip` for manual app validation, and includes a macOS artifact-validation job that executes install, first backup, upgrade, and rollback using the CLI/daemon artifacts and uploads a `rc-validation-evidence-*` artifact.
5. Record decision status in:
   - `docs/v0.4.0-rc1-validation.md`
   - `docs/v0.4-rc-go-no-go-checklist.md`

## Stability Proving Run

To demonstrate required checks are consistently green, run:

- `gh workflow run "Required Checks Stability" -f iterations=10`
- `gh run watch`

Attach the resulting workflow URL in `docs/v0.4-rc-go-no-go-checklist.md`.
