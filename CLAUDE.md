# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Baxter is a macOS backup utility with an S3 backend, built in Go (CLI/daemon) and Swift (menu bar app).

## Build & Test Commands

```bash
# Go tests (all)
go test ./...

# Single test
go test ./internal/backup -run TestManifestRoundTrip -v

# Benchmarks
go test ./internal/backup -bench BenchmarkUploadPipelineCompressionImpact -benchmem

# Vulnerability check
govulncheck ./...

# Run CLI
go run ./cmd/baxter <subcommand>

# Run daemon (single pass)
go run ./cmd/baxterd --once

# Swift style checks
./scripts/swift-style.sh lint-check
./scripts/swift-style.sh format-check
./scripts/swift-style.sh format-apply

# Swift style (changed files only, faster)
./scripts/swift-style.sh lint-check --changed
./scripts/swift-style.sh format-apply --changed

# macOS app build & test
xcodebuild -project apps/macos/BaxterApp.xcodeproj -scheme BaxterApp -configuration Debug build
xcodebuild -project apps/macos/BaxterApp.xcodeproj -scheme BaxterApp -destination 'platform=macOS' test

# Install Swift tooling
brew bundle --file Brewfile --no-upgrade
```

## Architecture

**Two binaries + one macOS app:**
- `cmd/baxter` — CLI (thin wrapper calling `internal/cli`)
- `cmd/baxterd` — daemon with scheduler + IPC HTTP server on `127.0.0.1:41820`
- `apps/macos/BaxterApp` — SwiftUI menu bar app that talks to the daemon via IPC

**Core packages (`internal/`):**
- `backup` — manifest, change-plan diffing, backup runner, snapshot management
- `cli` — command handlers for backup, restore, verify, gc, snapshot
- `config` — TOML config parsing/validation
- `crypto` — AES-256-GCM encryption with Argon2id KDF, per-install salt
- `daemon` — HTTP IPC server, scheduling, state machine, restore endpoints
- `recovery` — recovery metadata and key resolution
- `recoverycache` — restore list index caching
- `state` — app directory path resolution (`~/Library/Application Support/baxter`)
- `storage` — S3 backend + local object storage fallback

**Data flow:** Config (TOML) → file scan → change-plan diff against manifest → encrypt (AES-256-GCM) → compress → store (S3 or local objects). Manifest snapshots are timestamped and immutable under `~/Library/Application Support/baxter/manifests`.

**Encryption:** Payload version 3 (current). Decryption supports v2 and v3. v1 is unsupported.

**IPC security:** Loopback-only by default. Optional token auth (`X-Baxter-Token`) with comma-separated rotation support.

## Code Conventions

- Keep files around 500 lines; split if they grow beyond that.
- Small, focused commits with imperative messages (e.g., "Add config parsing").
- PR squash merge unless preserving individual commit history.
- Swift files are linted by SwiftLint and formatted by SwiftFormat (rules in `.swiftlint.yml`).
- Swift scope: only `apps/macos/BaxterApp/**/*.swift` and `apps/macos/BaxterAppTests/**/*.swift`.

## CI

Main CI (`ci.yml`) runs four jobs: `go-test` (Ubuntu, 20min timeout), `swift-style` (macOS, SwiftLint+SwiftFormat), `macos-app-test` (Xcode tests + launchd smoke), `upgrade-preservation-smoke` (before/after binary upgrade validation).

## Key Scripts

- `scripts/release.sh <version>` — build multi-platform release artifacts to `dist/`
- `scripts/install-launchd.sh` / `scripts/uninstall-launchd.sh` — manage launchd agent
- `scripts/smoke-launchd-ipc.sh` — daemon launch + IPC smoke test
- `scripts/upgrade-preservation-smoke.sh` — before/after upgrade validation
- `scripts/init-config.sh <paths...>` — initialize config with backup roots
