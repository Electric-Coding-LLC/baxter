# Baxter Worklist

As of March 2, 2026.

This is a personal project worklist, not a formal release roadmap.

## Focus

- Keep Baxter simple, trustworthy, and low-friction for personal backups on macOS.
- Prioritize restore confidence and reliability over feature breadth.

## Now (active)

1. CI stability pass
   - Goal: make required checks reliable enough for normal day-to-day work.
   - Plan doc: `docs/ci-stability-plan.md`
   - Next actions:
     - Run repeated required-check reruns.
     - Capture which checks fail most often.
     - Remove or harden flaky paths and improve failure logs.
   - Done when:
     - Reruns are consistently green and failures are diagnosable.

## Next (queued)

1. Retention profiles
   - Add simple presets: `light`, `balanced`, `archive`.
   - Keep advanced manual override path.

2. Key management UX hardening
   - Improve key resolution checks and fallback messaging.
   - Add guided remediation for common config mistakes.

3. Scheduled restore drills
   - Add optional recurring restore-drill scheduling.
   - Show latest drill result in status/diagnostics.

## Later (nice to have)

1. Performance exploration for larger datasets.
2. Faster restore browsing via metadata/indexing improvements.
3. Optional local-only health reporting format for support workflows.

## Recently Finished

- Restore Workspace MVP in macOS app.
- RC artifact validation automation in `Release Candidate` workflow.
- Upgrade preservation regression automation.
- CI/launchd smoke guardrails with better timeout/retry/deadline behavior.
- Swift style tooling and CI checks (`swiftlint` + `swiftformat`).
- Path-based CI gating to reduce unnecessary checks on pull requests.
- Restore-path error handling improvements and actionable macOS UI error guidance.
- Diagnostics export with config/log redaction and tests.
- v0.4 go/no-go checklist and evidence record in `docs/`.

## Parking Lot

- Non-macOS clients.
- Cloud control plane/account sync.
- Team/multi-user access management.
- Mobile restore clients.
