# Security Best Practices Report

Updated: 2026-02-13

## Executive Summary
The previously reported daemon/API hardening gaps are now addressed. Based on current code and CI configuration, I did not identify any active Critical, High, or Medium findings in the reviewed scope.

## Scope
- Language/framework reviewed: Go (`net/http`) backend/daemon + GitHub Actions CI.
- Key evidence files:
  - `/Users/iamce/dev/electric/baxter/cmd/baxterd/main.go`
  - `/Users/iamce/dev/electric/baxter/internal/daemon/ipc.go`
  - `/Users/iamce/dev/electric/baxter/internal/daemon/auth.go`
  - `/Users/iamce/dev/electric/baxter/internal/daemon/handlers.go`
  - `/Users/iamce/dev/electric/baxter/internal/daemon/status.go`
  - `/Users/iamce/dev/electric/baxter/internal/daemon/daemon.go`
  - `/Users/iamce/dev/electric/baxter/internal/crypto/crypto.go`
  - `/Users/iamce/dev/electric/baxter/.github/workflows/ci.yml`
  - `/Users/iamce/dev/electric/baxter/.github/workflows/release.yml`
  - `/Users/iamce/dev/electric/baxter/go.mod`

## Active Findings
No active findings in this pass.

## Resolved Findings

### [SBP-001] Privileged daemon API unauthenticated + unsafe remote binding
Status: Resolved
- Evidence:
  - Loopback-only by default with explicit remote opt-in: `/Users/iamce/dev/electric/baxter/internal/daemon/ipc.go:11`
  - Remote mode requires token: `/Users/iamce/dev/electric/baxter/cmd/baxterd/main.go:43`

### [SBP-002] HTTP server missing timeout/header-size hardening
Status: Resolved
- Evidence:
  - Explicit timeout/header limits configured: `/Users/iamce/dev/electric/baxter/internal/daemon/daemon.go:109`, `/Users/iamce/dev/electric/baxter/internal/daemon/daemon.go:110`, `/Users/iamce/dev/electric/baxter/internal/daemon/daemon.go:111`, `/Users/iamce/dev/electric/baxter/internal/daemon/daemon.go:112`, `/Users/iamce/dev/electric/baxter/internal/daemon/daemon.go:113`

### [SBP-003] No request-body size limits on restore JSON endpoints
Status: Resolved
- Evidence:
  - Request body limit constant and `http.MaxBytesReader` usage: `/Users/iamce/dev/electric/baxter/internal/daemon/handlers.go:19`, `/Users/iamce/dev/electric/baxter/internal/daemon/handlers.go:292`

### [SBP-004] Static global passphrase KDF salt
Status: Resolved (legacy compatibility retained)
- Evidence:
  - Random per-install KDF salt generation and validation: `/Users/iamce/dev/electric/baxter/internal/crypto/crypto.go:40`, `/Users/iamce/dev/electric/baxter/internal/crypto/crypto.go:48`
  - Persisted/loaded install salt in daemon and CLI derivation paths: `/Users/iamce/dev/electric/baxter/internal/daemon/backup.go:131`, `/Users/iamce/dev/electric/baxter/internal/cli/helpers.go:163`

### [SBP-005] CI toolchain lag and missing vulnerability scan
Status: Resolved
- Evidence:
  - Toolchain aligned to `1.24.x` in CI/release: `/Users/iamce/dev/electric/baxter/.github/workflows/ci.yml:19`, `/Users/iamce/dev/electric/baxter/.github/workflows/release.yml:17`
  - `govulncheck` added to CI/release: `/Users/iamce/dev/electric/baxter/.github/workflows/ci.yml:22`, `/Users/iamce/dev/electric/baxter/.github/workflows/release.yml:20`
  - Module Go version aligned: `/Users/iamce/dev/electric/baxter/go.mod:3`

### [SBP-006] Read endpoints unauthenticated in remote IPC mode
Status: Resolved
- Evidence:
  - Shared IPC auth middleware now gates all `/v1/*` routes when a token is configured: `/Users/iamce/dev/electric/baxter/internal/daemon/auth.go:11`, `/Users/iamce/dev/electric/baxter/internal/daemon/handlers.go:23`, `/Users/iamce/dev/electric/baxter/internal/daemon/handlers.go:27`, `/Users/iamce/dev/electric/baxter/internal/daemon/handlers.go:28`, `/Users/iamce/dev/electric/baxter/internal/daemon/handlers.go:29`

## Validation Performed
- `go test ./...` (pass)
- `go run golang.org/x/vuln/cmd/govulncheck@latest ./...` (no vulnerabilities found)
