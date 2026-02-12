# Security Best Practices Report

## Executive Summary
This review covered the Go backend/daemon code and CI configuration in `/Users/iamce/dev/electric/baxter` using the `security-best-practices` guidance for Go. The highest risks are around daemon API exposure and HTTP hardening gaps: privileged daemon endpoints are unauthenticated, and the daemon HTTP server lacks defensive timeout/header settings. I also found medium-risk issues in request-size handling, key-derivation salt design, and CI vulnerability hygiene.

## Scope
- Language/framework reviewed: Go + `net/http` backend code.
- Key evidence:
  - `/Users/iamce/dev/electric/baxter/go.mod`
  - `/Users/iamce/dev/electric/baxter/cmd/baxterd/main.go`
  - `/Users/iamce/dev/electric/baxter/internal/daemon/daemon.go`
  - `/Users/iamce/dev/electric/baxter/internal/daemon/handlers.go`
  - `/Users/iamce/dev/electric/baxter/internal/crypto/crypto.go`
  - `/Users/iamce/dev/electric/baxter/.github/workflows/ci.yml`
  - `/Users/iamce/dev/electric/baxter/.github/workflows/release.yml`

## High Severity

### [SBP-001] Unauthenticated privileged daemon API + remotely configurable listen address
- Rule ID: GO-HTTP-SECURE-BOUNDARY (derived from GO-HTTP hardening and auth boundary requirements)
- Severity: High
- Location:
  - `/Users/iamce/dev/electric/baxter/cmd/baxterd/main.go:26`
  - `/Users/iamce/dev/electric/baxter/cmd/baxterd/main.go:36`
  - `/Users/iamce/dev/electric/baxter/internal/daemon/handlers.go:19`
  - `/Users/iamce/dev/electric/baxter/internal/daemon/handlers.go:39`
  - `/Users/iamce/dev/electric/baxter/internal/daemon/handlers.go:57`
  - `/Users/iamce/dev/electric/baxter/internal/daemon/handlers.go:168`
- Evidence:
  - The daemon can be bound to arbitrary addresses via `--ipc-addr`.
  - Sensitive endpoints (`/v1/backup/run`, `/v1/config/reload`, `/v1/restore/run`) do not require any authentication.
- Impact:
  - If bound beyond loopback (accidentally or by deployment drift), unauthorized callers can trigger backups, reload config, and write restored files.
- Fix:
  - Enforce loopback-only binding unless an explicit `--allow-remote-ipc` (or equivalent) is set.
  - Add authentication/authorization for all state-changing endpoints (token/mTLS/Unix socket ACL model).
- Mitigation:
  - Firewall-restrict daemon port to localhost and trusted admin hosts only.
- False positive notes:
  - If infrastructure guarantees strict localhost-only access in every environment, impact is reduced but still fragile under misconfiguration.

### [SBP-002] HTTP server missing timeout and header-size hardening
- Rule ID: GO-HTTP-001
- Severity: High
- Location:
  - `/Users/iamce/dev/electric/baxter/internal/daemon/daemon.go:67`
- Evidence:
  - `http.Server` is created without `ReadHeaderTimeout`, `ReadTimeout`, `WriteTimeout`, `IdleTimeout`, and `MaxHeaderBytes`.
- Impact:
  - Increases exposure to slowloris/resource-exhaustion style DoS attacks.
- Fix:
  - Set explicit `http.Server` limits suitable for IPC/API traffic.
- Mitigation:
  - Add strict reverse-proxy limits if fronted by a proxy, but keep app-level limits too.
- False positive notes:
  - None; this is directly observable in code.

## Medium Severity

### [SBP-003] No request-body size limits on JSON restore endpoints
- Rule ID: GO-HTTP-002
- Severity: Medium
- Location:
  - `/Users/iamce/dev/electric/baxter/internal/daemon/handlers.go:145`
  - `/Users/iamce/dev/electric/baxter/internal/daemon/handlers.go:175`
- Evidence:
  - `json.NewDecoder(r.Body).Decode(...)` is used without `http.MaxBytesReader` limits.
- Impact:
  - Large request bodies can consume memory/CPU and degrade service availability.
- Fix:
  - Wrap request bodies with `http.MaxBytesReader` (e.g., 1 MiB for these JSON payloads) before decode.
- Mitigation:
  - Add ingress/proxy body size limits.
- False positive notes:
  - Lower impact in strictly trusted localhost-only environments, but still a robustness/security gap.

### [SBP-004] Passphrase KDF uses a static global salt
- Rule ID: GO-CRYPTO-KDF-UNIQUE-SALT (derived crypto best-practice)
- Severity: Medium
- Location:
  - `/Users/iamce/dev/electric/baxter/internal/crypto/crypto.go:20`
  - `/Users/iamce/dev/electric/baxter/internal/crypto/crypto.go:27`
- Evidence:
  - `kdfSalt` is a fixed constant for all users/installations.
- Impact:
  - Enables shared precomputation across deployments and weakens resistance to offline guessing at scale.
- Fix:
  - Use a random per-install/per-key salt and persist KDF metadata alongside encrypted data or in protected config.
- Mitigation:
  - Require long high-entropy passphrases until KDF salt design is improved.
- False positive notes:
  - AES-GCM nonce handling is correct; this finding is specifically about passphrase-to-key derivation hardening.

### [SBP-005] CI toolchain lag and missing automated vuln scan
- Rule ID: GO-DEPLOY-001
- Severity: Medium
- Location:
  - `/Users/iamce/dev/electric/baxter/go.mod:3`
  - `/Users/iamce/dev/electric/baxter/.github/workflows/ci.yml:14`
  - `/Users/iamce/dev/electric/baxter/.github/workflows/release.yml:17`
- Evidence:
  - `go.mod` declares `go 1.24.0`, but CI/release workflows run Go `1.22`.
  - No `govulncheck` step is present in CI/release pipelines.
- Impact:
  - Security fixes in newer toolchain/library versions may be missed, and known vulns may ship unnoticed.
- Fix:
  - Align CI/release Go version with a supported up-to-date baseline and add `govulncheck ./...` in CI.
- Mitigation:
  - Run `govulncheck` manually as part of release checklist until CI is updated.
- False positive notes:
  - Exact required Go minor/patch depends on release policy; verify against your support matrix.

## Positive Controls Observed
- Local object and manifest files are written with restrictive file modes (`0o600`) in:
  - `/Users/iamce/dev/electric/baxter/internal/storage/local.go:27`
  - `/Users/iamce/dev/electric/baxter/internal/backup/backup.go:63`
- Restore target path validation includes containment checks to block traversal in:
  - `/Users/iamce/dev/electric/baxter/internal/daemon/restore.go`
  - `/Users/iamce/dev/electric/baxter/internal/cli/helpers.go`

## Recommended Remediation Order
1. SBP-001 (auth/binding hardening on daemon API)
2. SBP-002 (HTTP server timeout/header hardening)
3. SBP-003 (request body limits)
4. SBP-005 (CI/go version + `govulncheck`)
5. SBP-004 (KDF salt design)
