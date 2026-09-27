# Next Phase Audit

Audit date: 2026-04-04

Purpose: record what is actually validated after Phases 0-6, what hardening was required before Phase 7, what scope has intentionally not been completed yet, and whether the repo is ready to begin the text phase.

## Full Verification Snapshot

Passed:

- `swift build`
- `python3 CompatibilitySuite/run_shader_fixtures.py`
- `python3 CompatibilitySuite/run_script_host_fixtures.py`
- `python3 CompatibilitySuite/generate_script_compatibility.py`
- sample runtime suite, bridge lane:
  - report: `CompatibilitySuite/reports/run_2026-04-03T23-32-44-498421Z_f04710c5.json`
  - result: `3/3 pass`
- sample runtime suite, native-requested lane:
  - report: `CompatibilitySuite/reports/run_2026-04-03T23-33-14-891946Z_0ad680b3.json`
  - result: `3/3 pass`
  - observed backend split:
    - `deep_space`: native
    - `neon_sunset`, `shimmering_particles`: bridge fallback
- text-bearing canary lane:
  - source: `CompatibilitySuite/text_scene_canaries.json`
  - report: `CompatibilitySuite/reports/run_2026-04-03T23-18-57-553788Z_eb450b3b.json`
  - result: `2/2 pass`
- full 20-wallpaper canary suite, bridge lane:
  - report: `CompatibilitySuite/reports/run_2026-04-03T23-20-01-441720Z_79e2c34a.json`
  - result: `20/20 pass`
- full 20-wallpaper canary suite, native-requested lane:
  - report: `CompatibilitySuite/reports/run_2026-04-03T23-29-24-568733Z_07b62c60.json`
  - result: `20/20 pass`
  - current observed backend: all 20 fall back to bridge on this corpus

Conclusion:

- the repo is green on the current verification stack
- the pre-Phase-7 blockers identified in the previous audit have been closed
- the remaining gaps are scope boundaries for later work, not unresolved readiness regressions

## What Has Been Bit Off

These are the real migration slices now owned in-repo:

- native scene model extraction
- owned shader preprocessing/compilation pipeline
- owned runtime packet generation
- first native renderer slice for image/material scenes
- owned QuickJS-backed scripted dynamic-value host (`createScriptProperties()` + `update(value)`)

This is meaningful progress, but it is important to be precise about what that ownership means:

- the native renderer is not full scene parity yet
- the native script host is not full SceneScript parity yet
- the runtime harness now validates both bridge and native-requested startup paths, but most real wallpapers still legitimately fall back to the bridge

## Hardening Completed Before Phase 7

### 1. Shutdown and automation stability

The flaky teardown path was fixed by making shutdown idempotent and by removing automation-mode subscriptions to screen-change and sleep/wake notifications.

Files:

- `Sources/WallpaperEngine/AppDelegate.swift`
- `Sources/WallpaperEngine/DesktopWindowManager.swift`

Impact:

- `3035352006` no longer flakes in repeated isolated bridge runs
- full 20-wallpaper bridge canary rerun is green again
- native-requested automation no longer pauses or rebuilds windows mid-suite

### 2. Native-path harness coverage

`CompatibilitySuite/run_suite.py` now supports:

- `--backend bridge`
- `--backend native`
- report fields for both `requested_backend` and `observed_backend`

Impact:

- native-requested work is now testable without ad hoc one-off app launches
- fallback is visible in reports instead of being hidden inside a generic pass result

### 3. Text-bearing acceptance target

Added `CompatibilitySuite/text_scene_canaries.json` with two real workshop scenes that currently emit `Text objects are not supported yet` while still rendering correctly:

- `2232968607`
- `3368256253`

Impact:

- Phase 7 now has an explicit preexisting acceptance lane for text-bearing wallpapers
- text work can be validated as a real regression/improvement against known wallpapers instead of being built blind

## Confirmed Gaps By Area

### 1. Native renderer coverage is still narrow

Current Phase 5 support is intentionally limited to a subset of scenes:

- image nodes
- flat geometry
- direct material passes

Still not owned:

- particle rendering parity
- RTT/effect chains
- post-processing/light-pass parity
- mesh/model geometry
- text rendering

Current validated behavior:

- native-requested startup is stable
- unsupported scenes fall back cleanly
- only `deep_space` is currently observed to stay on the native path in the sample suite

Implication:

- this is no longer a readiness blocker, but it remains the main limitation on how much of Phase 7 can land natively in one step

### 2. Script host coverage is real, but corpus coverage is weak

Phase 6 correctly replaced the upstream `ScriptEngine.cpp` host model, but the current sample corpus does not meaningfully exercise that model.

The generated compatibility matrix shows:

- only one sample wallpaper with embedded script
- it uses `applyUserProperties` and `thisObject`
- coverage ratio is currently `0.0` for the observed sample-script API references

This is not a contradiction. It means:

- the implemented host matches the upstream scripted-dynamic-value path
- the sample corpus is exercising a different scene-level callback model that the extracted scene model does not yet export

Implication:

- dynamic text updates driven by scene callbacks are still blocked
- if the text phase expects runtime text mutation from top-level scene scripts, that work is not optional

### 3. Text objects remain intentionally unsupported

Current validated behavior:

- text-bearing bridge canaries render and benchmark successfully today
- they still log `Text objects are not supported yet`
- the native renderer does not currently own text rendering and would fall back for these scenes

Implication:

- this is the Phase 7 feature gap, not a pre-Phase-7 regression

## What Still Needs To Be Fixed

These items remain real work, but they do not block starting Phase 7:

1. Implement actual text-object parsing/rendering parity.
2. Decide whether Phase 7 includes only static text or also dynamic/script-driven text updates.
3. Expand the script compatibility corpus so scene-callback behavior is validated in context, not only through host fixtures.
4. Grow native renderer coverage beyond the current image/material subset so more real wallpapers stay native instead of falling back.

## Recommended Entry Criteria For Phase 7

Proceed if all of the following are true:

- the bridge canary lane is green
- the native-requested lane is green
- a text-bearing wallpaper fixture/canary is identified as the acceptance target
- the team is explicit about whether scene-callback-driven text updates are in scope now or deferred

Current status:

- satisfied

## Bottom Line

The codebase is fully ready for Phase 7 entry, without actually starting Phase 7 yet.

What is signed off:

- bridge runtime lane
- native-requested runtime lane
- text-bearing bridge acceptance lane
- shader fixture lane
- script-host fixture lane

What remains intentionally unbuilt:

- native text rendering
- scene-level callback scripting for dynamic text mutation
- broader native scene parity on real workshop content
