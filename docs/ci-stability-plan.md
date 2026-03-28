# Baxter CI Stability Plan

Last updated: March 28, 2026

Purpose: make Baxter's required CI checks reliable enough for routine development, with failures that are fast to diagnose instead of intermittent mysteries.

## Target Outcome

Desired steady state:

1. Required checks on normal pull requests are consistently green when the underlying code is good.
2. When a check fails, the run makes the failure class obvious from logs or uploaded artifacts.
3. Required-check reruns become a confirmation tool, not a routine workaround.

## Current CI Surface

Primary workflow: `.github/workflows/ci.yml`

Current required or near-required checks in normal PR flow:

- `changes`
- `go-test`
- `macos-app-test`
- `swift-style` when Swift-related paths change
- `upgrade-preservation-smoke` when backup/CLI/state-sensitive paths change

Dedicated stability workflow: `.github/workflows/required-checks-stability.yml`

Current stability tooling already exists for:

- repeated `go-test` attempts
- repeated `macos-app-test` attempts
- failure artifact capture for macOS test bundles and launchd logs

## Problem Statement

The repo already has the right broad checks, but the remaining gap is operational confidence:

- repeated reruns are still needed often enough to be on the active worklist
- macOS CI has the highest environment sensitivity because it depends on a self-hosted runner, Xcode, DerivedData caching, and launchd smoke behavior
- path-gated checks reduce wasted runs, but they also make debugging harder when it is unclear whether the right work actually ran

## Candidate Failure Buckets

These are the first buckets to classify before changing workflow logic:

1. Runner environment drift
- self-hosted macOS label mismatch
- launchd GUI domain unavailability
- Homebrew/Xcode/toolchain drift

2. Cache-related instability
- stale or corrupted DerivedData reuse
- cache restore keys masking real invalidation needs

3. Test isolation problems
- launchd smoke leaving state behind between attempts
- tests sharing filesystem, keychain, or config paths unexpectedly

4. Workflow observability gaps
- failures that require downloading raw logs to understand
- skipped or path-gated jobs that are hard to interpret from the summary alone

## Plan

### Phase 1. Establish a Stability Baseline

Goal: measure the current failure rate and cluster failures before making fixes.

Actions:

- Run `Required Checks Stability` with `iterations=10` on the current `main` branch.
- Record pass/fail counts separately for `go-test` and `macos-app-test`.
- For every failure, capture:
  - check name
  - attempt number
  - first failing step
  - whether rerun passed without code changes
  - artifact/log URL
- Create a simple failure ledger in the workflow summary or follow-up doc.

Definition of done:

- We have at least one 10-attempt baseline run on `main`.
- Every failed attempt is categorized into one of the failure buckets above, or explicitly marked `unknown`.

Latest baseline evidence:

- `Required Checks Stability` run on `main`: https://github.com/Electric-Coding-LLC/baxter/actions/runs/23103066741
- Triggered March 15, 2026 04:09 UTC and completed March 15, 2026 04:12 UTC.
- `go-test`: 10/10 success, 0 failures, 0 skips.
- `macos-app-test`: 10/10 success, 0 failures, 0 skips.
- Failure buckets observed: none in this baseline run.

### Phase 2. Fix High-Frequency Flakes First

Goal: remove the smallest set of causes that account for most rerun pain.

Current chunk implemented locally:

- Add a path-gated pre-merge packaged-app smoke job in `.github/workflows/ci.yml`.
- The job packages `Baxter-darwin-arm64.zip`, launches the signed app, and verifies bundled-helper bootstrap through `/v1/status`.
- Local verification passed; next evidence needed is a normal PR run on the macOS runner.

Priority order:

1. `macos-app-test`
2. `swift-style`
3. `go-test`
4. `upgrade-preservation-smoke`

Expected work areas:

- `.github/workflows/ci.yml`
- `.github/workflows/required-checks-stability.yml`
- `scripts/smoke-launchd-ipc.sh`
- `scripts/install-launchd.sh`
- `scripts/uninstall-launchd.sh`
- `scripts/swift-style.sh`

Fix types that are in scope:

- stronger cleanup around launchd install/uninstall
- clearer timeout/deadline logging
- safer cache invalidation or narrower cache restore usage
- workflow summaries that surface skip reasons and failure context directly

Fix types that are out of scope for this pass:

- broad test rewrites with no proven CI signal
- new feature work unrelated to check reliability
- adding more required checks before current ones are stable

Definition of done:

- The top recurring failure class has a concrete fix merged.
- A fresh stability rerun shows fewer failures or better diagnostics than the baseline.

### Phase 3. Harden Diagnostics

Goal: make the next failure cheap to understand.

Actions:

- Ensure every flaky-prone job emits enough step summary detail to explain:
  - why it ran
  - why it skipped
  - what failed first
- Keep failure artifacts for:
  - macOS `.xcresult`
  - launchd logs
  - any future script-level debug output that materially shortens diagnosis time
- Prefer concise summaries in the GitHub UI over requiring artifact spelunking for basic triage.

Definition of done:

- A failing check can usually be triaged from the workflow summary plus the first linked artifact.

### Phase 4. Lock In the Reliability Bar

Goal: define when the active worklist item is actually finished.

Ship criteria:

- `Required Checks Stability` passes `iterations=10` on `main` without unexplained failures.
- A representative PR touching Go paths passes all required checks without manual reruns.
- A representative PR touching macOS app paths passes all required checks without manual reruns.
- Remaining failures, if any, are rare, classified, and have an owner plus mitigation.

## Verification Plan

Primary checks:

- `gh workflow run required-checks-stability.yml -f iterations=10`
- normal PR runs through `.github/workflows/ci.yml`

Secondary spot checks:

- one Go-heavy PR
- one Swift/macOS-heavy PR
- one PR that should path-skip `swift-style`
- one PR that should path-skip `upgrade-preservation-smoke`

## Evidence To Keep

- URL of the latest 10-attempt stability run
  Current baseline: https://github.com/Electric-Coding-LLC/baxter/actions/runs/23103066741
- summary of failures by bucket
  Current baseline: no failures observed across 20 total attempts
- links to the latest representative passing PR runs
- notes on any check still considered fragile

## Definition Of Done

This work is done when all of the following are true:

- required checks are consistently green across repeated reruns
- intermittent failures are either eliminated or reduced to a small, explained set
- failure logs make the root cause diagnosable without guesswork
- the `CI stability pass` item in `WORKLIST.md` can move out of `Now`

## Follow-Up Chunks

After CI stability is no longer the active gap:

1. Key management UX hardening
2. Retention profiles
3. Scheduled restore drills
