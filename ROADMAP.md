# Baxter Product Roadmap

As of February 25, 2026.

## Vision

- Be the simplest trustworthy macOS backup tool for personal data.
- Keep recovery fast, predictable, and safe under stress.
- Ship secure-by-default behavior without forcing users through complex setup.

## Current State

- Core product is in place:
  - CLI backup/restore, daemon scheduling, and menu bar UI are implemented.
  - Snapshot-based restore, diagnostics view, first-run setup, verify, and restore-drill are available.
  - Local mode and S3 mode are both supported with encryption and retention controls.
- Current gap:
  - v0.4 release foundations are in place, but they still need end-to-end RC validation on clean install/upgrade/rollback paths.
  - Required checks need repeatability evidence across reruns before v0.4 can be considered stable.

## Milestones

### v0.4 Release Candidate

- Goal: make Baxter stable and supportable for day-to-day personal use.
- Scope:
  - Distribution and upgrades:
    - Define one supported install/upgrade path for CLI, daemon, and macOS app.
    - Add release checklist, rollback notes, and reproducible smoke steps.
  - Restore confidence pass:
    - Expand restore integration coverage for missing objects, overwrite collisions, and transient storage errors.
    - Improve UI messages for each daemon restore error class and preserve actionable codes.
  - Diagnostics bundle v2:
    - Export sanitized status/config/log bundle for support and bug reports.
    - Add explicit redaction checks to prevent secret/token leakage.
  - CI/runtime guardrails:
    - Harden macOS and daemon smoke reliability.
    - Fail fast on flaky or hanging smoke paths with clearer failure output.
- Acceptance criteria:
  - A new user can install from release artifacts and complete first backup without source checkout.
  - Upgrade path preserves config and state between versions without manual migration.
  - Restore failure classes are user-visible with actionable remediation text.
  - Diagnostics export contains useful context and no sensitive material.
  - Required CI checks are consistently green across reruns.

### v0.5 Reliability and Operability

- Goal: improve long-term trust and reduce user/operator footguns.
- Scope:
  - Retention profiles:
    - Add preset profiles (light, balanced, archive) for safer defaults.
    - Keep advanced override path for manual retention tuning.
  - Key management UX hardening:
    - Improve key resolution health checks and keychain/env fallback messaging.
    - Add guided remediation for common key configuration failures.
  - Scheduled confidence checks:
    - Add optional recurring restore-drill scheduling.
    - Show last drill outcome in status/diagnostics.
- Acceptance criteria:
  - Users can choose sensible retention behavior without editing raw TOML.
  - Key resolution failures are explicit and recoverable with guided steps.
  - Restore-drill can run on a configured cadence and report summary outcomes in UI.

### Post-v0.5 Exploration

- Goal: evaluate higher-scale and multi-device readiness without committing to a control plane.
- Scope:
  - Measure performance bottlenecks on larger datasets.
  - Assess metadata/indexing changes needed for faster restore browsing at scale.
  - Prototype optional health reporting format suitable for local-only support tooling.
- Acceptance criteria:
  - Decision memo exists for each exploration area with go/no-go recommendation.
  - Any approved work is broken into scoped deliverables for a future milestone.

## Recently Completed

- Added a supported install/upgrade/rollback release playbook and linked it from README.
- Added a manual `Release Candidate` workflow with RC version validation, vuln/test gates, and artifact publishing.
- Hardened CI and launchd smoke guardrails with explicit timeouts, bounded retries/deadlines, and failure log artifact upload.
- Expanded daemon restore failure-path coverage to include transient storage read failures.
- Mapped daemon restore error codes to actionable macOS UI guidance and added tests for key restore error states.
- Added diagnostics bundle export in the macOS app with config/log redaction and test coverage for sensitive-value sanitization.

## Next Sprint

1. Restore Workspace MVP (macOS app)
   - Goal: replace restore/settings/diagnostics dialogs with an app-first workflow and a faster, lower-error file-browser experience.
   - Scope: ship a dedicated restore screen with snapshot selector, searchable/expandable file tree, destination folder picker, and run/dry-run actions using existing daemon IPC endpoints; route menu actions (`Restore`, `Settings`, `Diagnostics`) to open the app window at the matching section.
   - Acceptance criteria: users can select snapshot + source paths and complete restore without manual path typing; restore/dry-run failures surface actionable inline errors with daemon error codes preserved; menu actions deep-link to in-app sections and dialog entry points are removed after parity.
2. RC artifact validation run
   - Goal: prove release artifacts install and run without source checkout.
   - Scope: run `Release Candidate` for `v0.4.0-rc1`; execute install, first backup, upgrade, and rollback from the playbook on a clean macOS host.
   - Acceptance criteria: all playbook steps pass without ad hoc fixes; evidence is captured in release notes/checklist.
3. Upgrade preservation regression automation
   - Goal: prevent config/state loss across upgrades.
   - Scope: add an automated smoke check that seeds config + manifest/object state, upgrades binaries, and verifies state is unchanged.
   - Acceptance criteria: check runs in CI and fails on any config/state drift.
4. CI rerun stability proving pass
   - Goal: demonstrate required checks are consistently green.
   - Scope: run repeated reruns of required macOS and Go checks; fix remaining flaky points and improve diagnostics where needed.
   - Acceptance criteria: 10 consecutive reruns on `main` pass for required checks.
5. v0.4 RC go/no-go checklist
   - Goal: make release sign-off explicit.
   - Scope: track each v0.4 acceptance criterion as pass/fail with owner notes and blocker status.
   - Acceptance criteria: checklist is complete and all blockers are either resolved or explicitly deferred.

## Out of Scope

- Non-macOS clients.
- Cloud-hosted control plane or account sync service.
- Team/multi-user access management.
- Mobile restore clients.
