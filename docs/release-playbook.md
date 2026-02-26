# Baxter Release Playbook

This playbook defines the supported distribution path for Baxter CLI + daemon + macOS app, along with upgrade and rollback procedures.

## Supported Install Path (macOS)

1. Download release artifacts (`baxter-darwin-arm64`, `baxterd-darwin-arm64`, `SHA256SUMS`).
2. Verify checksums:
   - `shasum -a 256 -c SHA256SUMS`
3. Install binaries:
   - `mkdir -p "$HOME/Library/Application Support/baxter/bin"`
   - `install -m 0755 baxter-darwin-arm64 "$HOME/Library/Application Support/baxter/bin/baxter"`
   - `install -m 0755 baxterd-darwin-arm64 "$HOME/Library/Application Support/baxter/bin/baxterd"`
4. Ensure config exists (`~/Library/Application Support/baxter/config.toml`).
5. Install/start launchd agent:
   - `./scripts/install-launchd.sh`
6. Run smoke validation:
   - `./scripts/smoke-launchd-ipc.sh`

## Supported Upgrade Path

1. Stop daemon cleanly:
   - `./scripts/uninstall-launchd.sh`
2. Snapshot current install for rollback:
   - `cp "$HOME/Library/Application Support/baxter/bin/baxter" "$HOME/Library/Application Support/baxter/bin/baxter.prev"`
   - `cp "$HOME/Library/Application Support/baxter/bin/baxterd" "$HOME/Library/Application Support/baxter/bin/baxterd.prev"`
3. Install new binaries using the same `install -m 0755 ...` commands from the install path.
4. Reinstall/start launchd:
   - `./scripts/install-launchd.sh`
5. Run smoke validation:
   - `./scripts/smoke-launchd-ipc.sh`

Upgrade guarantees:
- `~/Library/Application Support/baxter/config.toml` is preserved.
- Manifest/object state under `~/Library/Application Support/baxter/` is preserved.

## Rollback Procedure

Use rollback when smoke checks fail after upgrade.

1. Stop daemon:
   - `./scripts/uninstall-launchd.sh`
2. Restore previous binaries:
   - `install -m 0755 "$HOME/Library/Application Support/baxter/bin/baxter.prev" "$HOME/Library/Application Support/baxter/bin/baxter"`
   - `install -m 0755 "$HOME/Library/Application Support/baxter/bin/baxterd.prev" "$HOME/Library/Application Support/baxter/bin/baxterd"`
3. Start daemon:
   - `./scripts/install-launchd.sh`
4. Re-run smoke check:
   - `./scripts/smoke-launchd-ipc.sh`

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
5. Tag and publish:
   - `git tag vX.Y.Z && git push origin vX.Y.Z`

## Release Candidate Cut

For RC builds without publishing a tag-based release, use the `Release Candidate` workflow.

1. Start the workflow:
   - `gh workflow run "Release Candidate" -f version=v0.4.0-rc1`
2. Wait for completion:
   - `gh run watch`
3. Download artifacts from the workflow run and run the install/upgrade smoke path above.
4. The workflow now includes a macOS artifact-validation job that executes install, first backup, upgrade, and rollback using the built artifacts and uploads a `rc-validation-evidence-*` artifact.
5. Record decision status in:
   - `docs/v0.4.0-rc1-validation.md`
   - `docs/v0.4-rc-go-no-go-checklist.md`

## Stability Proving Run

To demonstrate required checks are consistently green, run:

- `gh workflow run "Required Checks Stability" -f iterations=10`
- `gh run watch`

Attach the resulting workflow URL in `docs/v0.4-rc-go-no-go-checklist.md`.
