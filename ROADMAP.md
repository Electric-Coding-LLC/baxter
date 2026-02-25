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
  - Release/distribution experience and support workflows still need to be polished for wider adoption.
  - Restore confidence can be improved with deeper failure-path coverage and clearer recovery UX.

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

## Next Sprint

1. Complete distribution + upgrade checklist and wire it into release docs.
2. Land restore failure-path tests and map error classes to UI copy.
3. Implement diagnostics bundle export with redaction tests.
4. Tighten CI smoke guardrails and cut v0.4 RC build.

## Out of Scope

- Non-macOS clients.
- Cloud-hosted control plane or account sync service.
- Team/multi-user access management.
- Mobile restore clients.
