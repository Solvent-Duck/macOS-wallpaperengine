# CI and validation

The repository now has a portable [repository-checks workflow](../.github/workflows/repository-checks.yml):
Git inventory hygiene, Python harness/build-script unit tests, and shell syntax checks.
These checks need neither workshop content nor a Metal device.

Native build and playback validation remains local on macOS 26+ with the matching Swift
toolchain and Metal access. Follow [Development procedure](DEVELOPMENT_PROCEDURE.md) for
dependency builds, serial debug/release tests, shader/script fixtures and representative
canaries. The app has one native runtime; there is no separate bridge lane.

A future required macOS job must first verify runner OS/toolchain and GPU capability, use
portable authored fixtures, and report crashes, blank-frame failures and declared partial
compatibility separately. Do not claim native CI coverage until that job actually runs.
Installed workshop media and optional audio/media probes remain separate opt-in validation.
Compare performance only with matching build flags and controlled serial measurements.

Preserve compact logs, hashes and summaries. Capture images only in bounded diagnostic
batches with a cleanup step; do not upload entire local report trees or private workshop
assets. The [original CI proposal](archive/CI_PLAN_2026-04.md) is historical context, not
current acceptance policy.
