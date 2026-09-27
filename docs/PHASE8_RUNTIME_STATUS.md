# Phase 8 Runtime Status

Audit date: 2026-04-04

Purpose: record the final native-only compatibility state after the Phase 8 runtime cutover, including the blocker fixes required to bring the owned runtime to green on the current sample and local real-scene canary corpus.

## Acceptance Result

Phase 8 runtime acceptance is now met.

The app runtime path remains fully cut over from the upstream runtime, and the owned native path now passes the current acceptance lanes:

- shader fixtures:
  - `python3 CompatibilitySuite/run_shader_fixtures.py`
  - result: `3/3` verified
- script host fixtures:
  - `python3 CompatibilitySuite/run_script_host_fixtures.py`
  - result: `3/3` verified
- native sample suite:
  - report: [`run_2026-04-04T09-52-26-350451Z_0a85a880.json`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/reports/run_2026-04-04T09-52-26-350451Z_0a85a880.json)
  - result: `3/3 pass`
- native text canary lane:
  - report: [`run_2026-04-04T09-55-25-551828Z_96bbb478.json`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/reports/run_2026-04-04T09-55-25-551828Z_96bbb478.json)
  - result: `3/3 pass`
- native 20-scene local canary lane:
  - report: [`run_2026-04-04T09-52-26-350480Z_23e3d82a.json`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/reports/run_2026-04-04T09-52-26-350480Z_23e3d82a.json)
  - result: `20/20 pass`

Focused blocker reruns that are now green:

- `shimmering_particles`:
  - [`run_2026-04-04T09-51-57-010788Z_bc3d94e1.json`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/reports/run_2026-04-04T09-51-57-010788Z_bc3d94e1.json)
- `3153305636`:
  - [`run_2026-04-04T09-51-57-010834Z_f5b27e6a.json`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/reports/run_2026-04-04T09-51-57-010834Z_f5b27e6a.json)
- `3613126158`:
  - [`run_2026-04-04T09-51-57-010819Z_4d870f0e.json`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/reports/run_2026-04-04T09-51-57-010819Z_4d870f0e.json)

## Blocker Fixes

### 1. Conditional user-setting export now preserves authored values

Problem:

- the upstream parser was connecting condition-bound settings directly to the referenced property
- that overwrote authored literal values during export
- native decoding then saw the property's current value instead of the setting's intended literal gated by a condition
- `shimmering_particles` was the clearest failure: particle visibility exported incorrectly, producing a black frame

Fix:

- [`UserSettingParser.cpp`](../linux-wallpaperengine/src/WallpaperEngine/Data/Parsers/UserSettingParser.cpp) now distinguishes:
  - direct property bindings: still connected to the property
  - condition-bound settings: retain their authored literal/scripted value and only carry the property name for condition evaluation
- [`PropertyEvaluator.swift`](../Sources/NativeSceneRuntime/PropertyEvaluator.swift) now resolves conditional settings from their own literal/scripted value first and applies the exported condition as a gate

Result:

- `shimmering_particles` renders visible native output again and no longer classifies as black.

### 2. Scalar parser paths now tolerate nested user-setting payloads

Problem:

- some real workshop scenes encode scalar-looking fields such as text `pointsize` as user-setting objects
- the upstream parser still had numeric reads that assumed a raw number
- this caused helper export crashes with `json.exception.type_error.302`

Fix:

- [`Object.h`](../linux-wallpaperengine/src/WallpaperEngine/Data/Model/Object.h) and [`ObjectParser.cpp`](../linux-wallpaperengine/src/WallpaperEngine/Data/Parsers/ObjectParser.cpp) now treat text `pointSize` as a user setting instead of a raw float
- [`JSON.h`](../linux-wallpaperengine/src/WallpaperEngine/Data/JSON.h) now unwraps nested `value` payloads when a parser requests a scalar
- the scene-export bridge and native text model/runtime were updated to carry text point size as a user-setting descriptor through export and evaluation

Result:

- helper export succeeds for `3153305636` and `3613126158`
- the long native canary run no longer fails on those scenes before playback begins

## Remaining Notes

These are not blocking Phase 8 acceptance:

- some real wallpapers still emit upstream parser/script warnings during helper export, including:
  - unsupported script API references
  - unknown `solid` object forms
  - special/system texture references
- those warnings no longer abort export or prevent native playback for the current canary corpus

## Exit-Criterion Assessment

Phase 8 is complete for the current acceptance corpus:

- dependency-cut goal: met
- build goal: met
- app playback path no longer depends on the upstream runtime: met
- native compatibility goal for the current sample, text, and 20-scene local canary lanes: met

What remains after Phase 8 is parity expansion work, not blocker debt:

- reducing parser/export warning noise
- broadening native feature coverage beyond the current canary subset
