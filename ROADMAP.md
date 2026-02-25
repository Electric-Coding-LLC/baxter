# Baxter Product Roadmap

As of February 24, 2026.

## Planning Assumptions

- Team capacity: one primary engineer with part-time review/support.
- Estimates are engineering days and include implementation plus tests and docs.
- Priorities are based on user impact, risk reduction, and fit with current architecture.

## Milestone v0.2 (Target: March 2026)

Goal: make recovery and day-to-day operation noticeably easier for real users.

### 1) Snapshot Explorer in macOS App (Priority: P0, 3-4 days)

- Why now: daemon already exposes `GET /v1/snapshots`, but macOS UI does not surface snapshots yet.
- Scope:
  - Add snapshot list UI in the Restore window.
  - Show snapshot ID, created time, and entry count.
  - Add snapshot selection control that feeds existing restore list and restore run actions.
- Acceptance criteria:
  - User can choose `latest` or a specific snapshot without typing raw IDs.
  - Restore search and restore run operate against selected snapshot.
  - App tests cover fetch/decode and selection behavior.

### 2) Guided Restore Flow (Priority: P0, 4-5 days)

- Why now: restore requires manual path entry and is easy to misuse under stress.
- Scope:
  - Add selectable restore results (single-click to populate path).
  - Add native destination folder picker.
  - Add confirmation summary before `Run Restore` (source, target, overwrite, verify-only, snapshot).
- Acceptance criteria:
  - Restore can be completed end-to-end without manual path typing.
  - Dry-run and final restore use identical target resolution parameters.
  - Error states are user-facing and preserve daemon error codes/messages.

### 3) User Notifications for Failures (Priority: P1, 2-3 days)

- Why now: users can miss failed backups/verifies if menu bar app is not open.
- Scope:
  - macOS local notifications for backup/verify failures.
  - Optional success notification toggle in settings (default off).
- Acceptance criteria:
  - Failure notification fires once per failed run transition.
  - No duplicate notification spam during polling.
  - Settings persist and survive app restart.

### 4) Operational Diagnostics View (Priority: P1, 2-3 days)

- Why now: support/debug currently requires manual log and config digging.
- Scope:
  - Add read-only diagnostics panel in settings:
    - config path
    - daemon state
    - last error fields
    - launchd log file paths
  - Add “copy diagnostics summary” action.
- Acceptance criteria:
  - One-click copy exports actionable environment snapshot for bug reports.
  - No secrets included in copied output.

## Milestone v0.3 (Target: May 2026)

Goal: strengthen retention controls and backup reliability at larger scale.

### 1) Retention Policy v2 (Priority: P0, 4-6 days)

- Why now: current retention is count-only (`manifest_snapshots`), which is limited for long-term usage.
- Scope:
  - Add age-based retention (for example, keep daily for 30 days, weekly for 12 weeks).
  - Keep count cap as safety guardrail.
  - Update gc/snapshot logic and docs.
- Acceptance criteria:
  - Retention applies deterministically during backup and GC.
  - Dry-run mode reports what would be pruned.
  - Tests cover boundary dates and mixed policy behavior.

### 2) S3 Transfer Resilience Pass (Priority: P0, 4-5 days)

- Why now: larger datasets increase probability of transient network/provider failures.
- Scope:
  - Harden retry/backoff for upload/download paths.
  - Improve error classification in CLI and daemon responses.
  - Add integration tests with fault injection stubs.
- Acceptance criteria:
  - Transient failures recover within configured retry budget.
  - Non-retryable errors fail fast with clear messages.
  - Restore path reports failures with actionable error codes.

### 3) Setup Wizard / First-Run Onboarding (Priority: P1, 3-4 days)

- Why now: first backup setup still depends on manual runbook steps.
- Scope:
  - Guided first-run flow in macOS app for:
    - selecting backup roots
    - choosing schedule
    - validating encryption key source
    - validating local mode vs S3 mode
  - “Run first backup now” entry point.
- Acceptance criteria:
  - New user can complete first successful backup with no shell commands.
  - Validation blocks invalid config combinations.
  - Existing users can skip wizard and continue normal flow.

### 4) End-to-End Restore Drill Command (Priority: P2, 2 days)

- Why now: regular restore drills are a practical confidence check.
- Scope:
  - Add CLI command to verify a sampled set of restore paths to temp destination with checksum checks.
  - Output machine-readable summary.
- Acceptance criteria:
  - Command exits non-zero on any integrity mismatch.
  - Summary includes checked count, failures, and sampled paths.

## Sequenced Next Sprint (Start: February 24, 2026)

1. Build Snapshot Explorer (unblocks guided restore UX).
2. Build Guided Restore Flow (highest user-facing recovery value).
3. Add failure notifications.
4. Add diagnostics view and ship v0.2.

## Out of Scope for v0.2/v0.3

- Non-macOS clients.
- Cloud-hosted control plane or multi-device sync.
- Cross-account/team access management.
