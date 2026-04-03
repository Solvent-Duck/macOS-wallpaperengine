# CI Plan

Generated: 2026-04-03

## Recommendation

Metal-backed screenshot validation should be enforced on macOS runners, not treated as a generic headless Linux CI problem. Local runs remain the fast inner loop, but promotion gates need at least one macOS execution path with real Metal access.

## Decisions

### 1. Where validation runs

- Mandatory local harness runs stay in place for day-to-day development.
- Merge-gating screenshot and benchmark validation should run on macOS CI.
- Linux CI can still run non-render checks such as schema validation, fixture generation, and parser-only tests.

Reason:
- Screenshot capture, black-frame detection, and frame-time baselines are all specific to the Apple renderer in this fork.
- Delaying this until "headless CI later" would make the harness informational instead of enforceable.

### 2. Promotion path

1. Local developer run:
   - Regenerate `CompatibilitySuite/fixtures.json` when the corpus changes.
   - Run the harness on the local fixture set before opening a PR.
2. PR validation:
   - macOS runner executes a reduced but representative fixture subset.
   - Fail the PR on crash, black-frame regression, or benchmark regression beyond thresholds.
3. Main-branch baseline refresh:
   - Manual or scheduled macOS job runs the full corpus and publishes updated reports and screenshots when deliberately approved.

### 3. Runner configuration

- GitHub-hosted macOS runners are acceptable for initial enforcement if the app build remains self-contained.
- If runner startup time or fixture corpus size becomes a bottleneck, move the screenshot and benchmark jobs to a self-hosted Apple Silicon runner.
- Required environment:
  - Metal-capable macOS host
  - Swift toolchain matching the package manifest
  - Native bridge dependencies already built or buildable in CI
  - Access to a checked-in fixture subset or a prepared wallpaper corpus artifact

## Thresholds

### Black-frame regression

- Any fixture previously marked renderable that now reports `black_frame: true` fails the job.
- New fixtures may be allowed to start as `untested`, but once baselined they should be enforced.

### Perceptual similarity

- Initial phase: do not gate on perceptual similarity yet.
- Store screenshots now so the harness and report format are ready.
- Add SSIM or pHash thresholds only after capture stability is demonstrated across several macOS runs.

### Frame-time regression

- Default benchmark gate:
  - `cpu_avg_ms` regression over baseline: fail above 20%
  - `cpu_p95_ms` regression over baseline: fail above 25%
  - `memory_peak_mb` regression over baseline: fail above 15%
- Regressions should be compared only against fixtures already marked stable enough for benchmarking.

## Near-Term Implementation Sequence

1. Land screenshot capture and benchmark JSON output in the app.
2. Land the compatibility runner and black-frame detection.
3. Start with local-only enforcement while reports stabilize.
4. Promote a reduced fixture subset to required macOS CI.
