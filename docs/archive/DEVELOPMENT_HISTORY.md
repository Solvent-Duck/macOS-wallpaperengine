# Development Procedure

Generated: 2026-04-03

## Goal

Keep compatibility work anchored to real wallpapers while preserving a fast local loop. Do not postpone real-workshop failures until the end of a phase.

## Wallpapers excluded from testing

Per the user's request on 2026-09-11, the following four wallpapers marked
`contentrating: Mature` are kept in `/Users/isaiahbergstrom/Nsfw - non-testing/`,
outside the Steam workshop corpus and all test roots:

- `2114290843` — 莲华
- `3340296712` — [VORE / X-RAY] Voraisha BIG meal DEBUT OFFICIAL ART
- `3626081043` — [VORE] Voraisha 丸呑み COZY OFFICIAL ART [3K]
- `3626090712` — [VORE] Voraisha 丸呑み DEBUT OFFICIAL ART [4K]

Do not use these IDs or the `Nsfw - non-testing` folder in test runs, benchmarks,
screenshots, canary selection, or full-corpus sweeps. Keep them excluded when
refreshing fixture catalogs, including if Steam downloads another copy into
`431960`. The three scene entries were removed from `full_scene_corpus.json`;
`2114290843` was not in an active fixture catalog.

## Fixture Tiers

### Tier 1: Fast regression set

- Source: [fixtures.json](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/fixtures.json)
- Size: 3 local loose-scene fixtures
- Purpose:
  - fast inner-loop validation
  - catch obvious launch, black-frame, and benchmark regressions quickly
- When to run:
  - before committing renderer, parser, model, or bridge changes
  - after any fix that changes screenshot or benchmark behavior

Command:

```bash
python3 CompatibilitySuite/run_suite.py \
  --fixtures CompatibilitySuite/fixtures.json \
  --binary .build/debug/WallpaperEngine \
  --timeout 60 \
  --frames 60 \
  --benchmark-duration 5
```

### Tier 2: Real workshop scene canary set

- Source: [local_scene_canaries.json](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/local_scene_canaries.json)
- Size: 20 reproducibly sampled local Steam workshop `scene` wallpapers
- Selection method:
  - scan `/Users/isaiahbergstrom/Library/Application Support/Steam/steamapps/workshop/content/431960`
  - keep items whose `project.json` has `type == "scene"` ignoring case
  - sample 20 entries with seed `431960`
- Purpose:
  - catch real packaging and parser drift
  - validate package-backed scene wallpapers, not only loose JSON test assets
  - expose workshop-only breakages early in the phase
- When to run:
  - before closing any roadmap phase that touches scene parsing, scene model extraction, shaders, scripting, textures, or runtime behavior
  - before merging broad renderer refactors
  - immediately after any failure found in Tier 1 is fixed if the change touches shared scene code

Command:

```bash
python3 CompatibilitySuite/run_suite.py \
  --fixtures CompatibilitySuite/local_scene_canaries.json \
  --binary .build/debug/WallpaperEngine \
  --timeout 60 \
  --frames 60 \
  --benchmark-duration 5
```

Native-requested lane:

```bash
python3 CompatibilitySuite/run_suite.py \
  --fixtures CompatibilitySuite/local_scene_canaries.json \
  --binary .build/debug/WallpaperEngine \
  --backend native \
  --timeout 60 \
  --frames 60 \
  --benchmark-duration 5
```

### Tier 2b: Text-bearing canary set

- Source: [text_scene_canaries.json](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/text_scene_canaries.json)
- Size: 3 real workshop scenes currently known to contain text objects
- Purpose:
  - keep Phase 7 text work attached to real acceptance targets
  - verify that text-bearing wallpapers continue to launch, render, and benchmark during pre-Phase-7 hardening
- When to run:
  - before starting Phase 7
  - after any parser/runtime change that touches text-object handling, object fallback, or scene export

Command:

```bash
python3 CompatibilitySuite/run_suite.py \
  --fixtures CompatibilitySuite/text_scene_canaries.json \
  --binary .build/debug/WallpaperEngine \
  --timeout 60 \
  --frames 60 \
  --benchmark-duration 5
```

### Tier 3: Full local workshop scene sweep

- Source root: `/Users/isaiahbergstrom/Library/Application Support/Steam/steamapps/workshop/content/431960`
- Purpose:
  - broader discovery run
  - identify new incompatibilities not represented in the canary sample
- When to run:
  - before milestone or release candidates
  - after large parser/runtime rewrites
  - when the 20-canary set starts passing but new user reports still appear

Use [generate_local_scene_canaries.py](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/generate_local_scene_canaries.py) as the refresh pattern and expand the same logic to the whole scene corpus when needed.

## Required Order of Operations

1. Build the native bridge and app. After changing public scene-model layouts or C bridge structs, run `swift package clean` before rebuilding; stale incremental output produced an inconsistent initialization fault during the September 12 migration.

```bash
./build-bridge.sh
swift build
```

2. Run Tier 1.
3. If the change touched shared scene code, run Tier 2 in the same development cycle.
4. If the change touched native renderer/runtime selection or fallback behavior, run the Tier 2 native-requested lane in the same cycle.
5. If the change touched text-object handling or readiness for Phase 7, run Tier 2b in the same cycle.
6. Fix any regressions immediately.
7. Re-run the failing tier after the fix.
8. Only move to the next roadmap phase once the relevant lanes are green:
   - Tier 1 + Tier 2 for shared scene work
   - Tier 2 native-requested for native path changes
   - Tier 2b for text work

## Failure Handling Rules

- `crash`, missing screenshot, or missing benchmark output is phase-blocking.
- Any previously renderable wallpaper that flips to `black_frame: true` is phase-blocking.
- New warnings in stdout/stderr are not automatically blocking, but they must be triaged if they correlate with render output changes.
- Real workshop failures found by Tier 2 should not be deferred to “after the build.” If a shared subsystem caused the failure, fix it while the context is local.

## Canary Catalog

The current local scene canary set is:

1. `1672387064` — Rising Sun
2. `2021551537` — Tenkinoko 天気の子
3. `2147092453` — Beside you {4K} - By lluluchwan
4. `2232968607` — 天空之镜 4K
5. `2598818790` — Wind girl
6. `2987678283` — Firekeeper
7. `2987771245` — 麻匪 Wlop鬼刀画作 雨儿
8. `3035352006` — 余霞成绮4K(有声)
9. `3073496639` — Girl with headphones | Sea berth | [4k]
10. `3096086835` — Floating Dream
11. `3131975619` — Shore (Night)
12. `3153305636` — Melancholic Lofi Girl by robokoboto [4K]
13. `3368256253` — Shimmering Pond | きらめく池
14. `3371510853` — Ekko and Powder HD Wallpaper | Powder and Ekko | Ekko and Jinx | Jinx and Ekko | Arcane | 双城之战第二季 艾克x金克丝
15. `3381294645` — 宗庙丘墟4K(有声)
16. `3421423611` — Cyberpunk: Edgerunners [4K]
17. `3497615251` — Summer Palette
18. `3527811827` — 【GrandBlue】碧蓝之海
19. `3573378561` — 𝙉𝙒  ─  BLUE  ARCHIVE (ArtWork By ﾍﾅﾁｮｺ)
20. `3613126158` — Mount Fuji (Shortcut, Day/Night Cycle, Media Info.) | 𝙎𝙚𝙮𝙪𝙡.𝙎𝙖𝙡𝙩𝙯

## Refresh Procedure

Refresh the canary catalog only deliberately, not opportunistically.

Command:

```bash
python3 CompatibilitySuite/generate_local_scene_canaries.py
```

Refresh when:

- the local Steam workshop corpus changes substantially
- a canary item is deleted locally
- the team wants a new random sample

If the set is refreshed:

1. Regenerate [local_scene_canaries.json](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/local_scene_canaries.json)
2. Record the new seed and date in this document
3. Run Tier 2 once to establish the new baseline
4. Update the execution log with the new canary set


## Script regression canaries

[script_scene_canaries.json](../CompatibilitySuite/script_scene_canaries.json) retains
five real scenes found during the September 12 parity work: the QuickJS mapped
arguments/auto-sway regression, a corpus timeout, Mount Fuji's group/layer and
day/night controls, authored locals shadowing host initialization, and the heavy shared-library/Vec4/lifecycle scene. Run this lane after changes to script ownership, property
bindings, or the QuickJS dependency. Successful rendering is separate from complete
SceneScript API or Windows visual parity.

```bash
python3 CompatibilitySuite/run_suite.py \
  --fixtures CompatibilitySuite/script_scene_canaries.json \
  --binary .build/debug/WallpaperEngine \
  --timeout 90 --frames 60 --benchmark-duration 5
```

## Material instance regression catalog

`CompatibilitySuite/instance_scene_canaries.json` contains the 85 eligible scenes
with per-image material overrides. Run it after instance or named-texture changes
alongside samples, workshop, models, lighting and text catalogs. System media and
shortcut-icon partials remain visible until their host providers work. Treat
flat frames and script/render errors as failures even when a known partial is
also present. Compare before/after pixels for ordinary textures, missing media
and custom lighting variants; a successful capture alone does not prove quality.

```sh
python3 CompatibilitySuite/run_suite.py \
  --fixtures CompatibilitySuite/instance_scene_canaries.json \
  --binary /tmp/wallpaper-parity-pass53-release-bin/WallpaperEngine \
  --timeout 90 --frames 60 --benchmark-duration 5
```

## Shader regression canaries

[shader_scene_canaries.json](../CompatibilitySuite/shader_scene_canaries.json)
retains nine full-sweep failures: runtime local constants, compound vector
arithmetic with macros, optional normal-map definedness, authored logarithm
helpers, conditional terminators, continued shader expressions, sampler helper
macros, scalar broadcasts, inactive empty helpers, and mismatched varying widths. Run it after shader
translation/repair changes.
Its render success does not certify the SceneScript APIs used by those scenes.

```bash
python3 CompatibilitySuite/run_suite.py \
  --fixtures CompatibilitySuite/shader_scene_canaries.json \
  --binary .build/debug/WallpaperEngine \
  --timeout 90 --frames 60 --benchmark-duration 5
```


## Video decoding lane

`video_corpus.json` contains all 45 eligible local MP4 wallpapers. The standalone
AVFoundation probe checks playable metadata and decodes frames at the start and
near one second. It applies the same testing exclusions. This is decoder
coverage; native app playback, looping, audio, pause/resume, and controls require
separate validation. The scene screenshot/benchmark automation currently rejects
video and web renderers.

```bash
swiftc -parse-as-library CompatibilitySuite/VideoDecodeProbe.swift -o /tmp/VideoDecodeProbe
/tmp/VideoDecodeProbe CompatibilitySuite/video_corpus.json CompatibilitySuite/reports/video-decode.json
```


## Material and image-compositing canaries

`material_scene_canaries.json` retains four black/flat-frame regressions covering
material masks, particle atlases, image alignment, and layer color blend modes.
Run this lane after changing image geometry or compositing, following the sample,
workshop, and text tiers. A smoke pass still requires visual inspection for
orientation, blending, and missing effects.

```bash
python3 CompatibilitySuite/run_suite.py \
  --fixtures CompatibilitySuite/material_scene_canaries.json \
  --binary .build/debug/WallpaperEngine \
  --timeout 90 --frames 60 --benchmark-duration 5
```


## Published scene preset canaries

`preset_scene_canaries.json` contains the two eligible local published presets
whose base wallpapers are installed. Run after the normal scene lanes when
changing preset resolution, property defaults, or imported texture loading.
Reports retain `preset-options` partial status while host alignment, color, and
playback options are unapplied. Preset `2984368737` is not in the rendering lane
because dependency `884307090` is absent; verify its missing-dependency error.

```bash
python3 CompatibilitySuite/run_suite.py \
  --fixtures CompatibilitySuite/preset_scene_canaries.json \
  --binary .build/debug/WallpaperEngine \
  --timeout 90 --frames 60 --benchmark-duration 5
```


## Live web corpus probe

This opt-in WKWebView test loads only eligible web project `860265906`, captures
its output, checks all property defaults reach the page, and verifies a timer
pauses/resumes. Its no-script-errors assertion currently fails on a malformed
inline property listener in the original local wallpaper (also rejected by Node).
Keep that authored failure visible; do not modify workshop content to make the
probe pass. The normal Swift suite leaves this local-corpus probe disabled.

```bash
WE_WEB_CORPUS_ROOT="$HOME/Library/Application Support/Steam/steamapps/workshop/content/431960" \
WE_WEB_CORPUS_REPORT_DIR="$PWD/CompatibilitySuite/reports/web-playback" \
swift test --disable-sandbox --filter WebCorpusTests
```


## Direct 3D model canaries

`direct_model_scene_canaries.json` contains the three eligible local scenes with
direct MDL models: Falling Deeper, Interactive Boat, and Miku StarryRiver. Together
they contain ten distinct MDLV0019/0021/0023 assets and thirteen material sections,
including a skinned shark and a boat with four materials. Run this lane after
model decoding, camera, material, depth, or skeletal rendering changes.

```bash
python3 CompatibilitySuite/run_suite.py \
  --fixtures CompatibilitySuite/direct_model_scene_canaries.json \
  --binary .build/debug/WallpaperEngine \
  --timeout 90 --frames 60 --benchmark-duration 5
```

These scenes retain `3d-models` partial status. A successful screenshot and
benchmark do not establish complete model effects, reflection targets, camera
controls, or visual parity. Inspect model stages as well as final output: in
Interactive Boat the sharks can render correctly before a later water
composition hides them. Application wallpapers remain outside the parity goal.


## Scene reflection canaries

`CompatibilitySuite/reflection_scene_canaries.json` retains the six eligible
local scenes that exposed `_rt_MipMappedFrameBuffer` and mip-information fallback
warnings during the pass-forty discovery sweep. Run this catalog after changing
scene snapshots, mip generation, shader coordinate adaptation, or texture binding:

```bash
python3 CompatibilitySuite/run_suite.py \
  --fixtures CompatibilitySuite/reflection_scene_canaries.json \
  --binary /tmp/wallpaper-parity-pass45-release-bin/WallpaperEngine \
  --frames 60 --benchmark-duration 5 --timeout 90
```

The frozen pass-forty-five path identifies this validation baseline; use the
current verified executable when testing later changes. `3061226599` and
`3229704729` retain `3d-models` partial status. All six require visual review in
addition to launch, screenshot and benchmark checks. Missing reflection-target
and mip-information warnings should not recur.

## Scene lighting canaries

`CompatibilitySuite/lighting_scene_canaries.json` contains the 25 eligible local
scenes with point, spot, tube or directional lights. Run it after changing light
parsing, shader light counts, uniform packing, or world/normal matrices:

```bash
python3 CompatibilitySuite/run_suite.py \
  --fixtures CompatibilitySuite/lighting_scene_canaries.json \
  --binary /tmp/wallpaper-parity-pass51-release-bin/WallpaperEngine \
  --frames 60 --benchmark-duration 5 --timeout 90
```

Use the current verified executable for later changes. Inspect stdout as well
as stderr: shader compilation failures and skipped layers can appear on stdout
even when a snapshot process exits successfully. Compare images, including lit
layers with effects and changing light visibility. The current baseline retains
two `3d-models` partials. From pass fifty-four, authored shadow-casting lights
also report `light-shadows` until shadow maps are implemented. This is a known
missing feature, not grounds to waive an accompanying render/script failure.
Scene `3162163215` has an authored dark intro, so its
catalog entry now waits for seven scene seconds. Do not reclassify these scenes
as full parity from a successful launch or benchmark.

## Capturing authored intros

An optional fixture `screenshot_time` sets the minimum elapsed scene time before
the app takes its motion-reference frame. The final screenshot follows 24 frames
later. The frame-count threshold still applies, and the benchmark runs after
the screenshot. Increasing benchmark duration alone does not delay capture.
Use a threshold supported by the authored timeline; black/flat-frame failures
are still failures after that threshold. The default remains zero for existing
fixtures. Capture sidecars record `scene_elapsed_time`,
`reference_scene_elapsed_time`, and `rendered_frames` to make timing reviewable.

The equivalent direct app option is `--screenshot-time 7`. Use an executable
built after pass fifty; older executables do not implement this option.

## Camera projection regression catalog

`CompatibilitySuite/camera_scene_canaries.json` contains the 46 eligible scenes
with nonunit or bound `general.zoom`: 36 static values, five animated values and
five user-property links. Run it after camera projection/property changes,
alongside the samples, workshop, direct-model, lighting and text catalogs.
Nonblack captures are smoke checks; inspect geometry, exposed canvas edges,
media overlays and active animation frames before asserting visual quality.

```sh
python3 CompatibilitySuite/run_suite.py \
  --fixtures CompatibilitySuite/camera_scene_canaries.json \
  --binary /tmp/wallpaper-parity-pass52-release-bin/WallpaperEngine \
  --timeout 90 --frames 60 --benchmark-duration 5
```


`CompatibilitySuite/camera_view_scene_canaries.json` adds 171 eligible static
2D camera configurations with nonzero eye coordinates, including 133 with X/Y
offsets. Run it after view/projection changes, alongside the direct-model and
text lanes. Pass 56 pairs the orthographic eye translation with its look-at
view and shares that convention with embedded models. This removes accidental
canvas offsets; it does not establish camera-path or Windows visual parity.

```sh
python3 CompatibilitySuite/run_suite.py \
  --fixtures CompatibilitySuite/camera_view_scene_canaries.json \
  --binary /tmp/wallpaper-parity-pass56-release-bin/WallpaperEngine \
  --timeout 90 --frames 60 --benchmark-duration 5
```

### Particle instance regression catalog

`CompatibilitySuite/particle_instance_scene_canaries.json` retains the 323
eligible scenes with authored non-default/dynamic count or simulation-rate
modifiers. Run it through the release app after shader/script fixtures and Swift
tests pass. Check both capture results and script/fallback diagnostics. A working
`layer.instance` object does not imply every member, particularly control points
and playback functions, is implemented. The pass 57 report records that limit.

### Particle control-point catalog

`CompatibilitySuite/particle_control_point_scene_canaries.json` contains 201
eligible scenes using pointer-linked, world-space or animated control points.
Pair the release app catalog with ParticleControlPointTests: ordinary snapshot
tools do not inject cursor movement. Do not equate a successful write to an
instance property with correct downstream operators or child inheritance.


## Pass 59 — layer world transforms and attachment queries

Added SceneScript Mat3/Mat4 math and live world/attachment queries, including
parent transforms and sampled puppet attachments. Same-callback property writes,
seeks and blend changes are reflected immediately. The safe scene-JSON audit
found 95 API uses in 49 eligible scenes; a dedicated canary catalog is included.
Eleven new tests bring debug/release totals to 275 tests in 42 suites, all passing.
Both frozen builds pass three shader and three script fixtures; eight Python
checks pass. All eight new native snapshots complete without skipped layers or
binder fallbacks. The boat's three attachment errors are gone and detached white
wake patches are removed; debug/release images match exactly. VHS goes from eight
script errors to six but still has a clipped clock and media/texture issues.

Seven app catalogs (108 checks) are queued after pass 58; completion is pending.
Full Windows equivalency remains unverified and incomplete. Multi-layer skeletal
blending, other layer mutation APIs, texture animation controls, media integration,
remaining render gaps and QoL remain open. Details, frozen hashes, reproducible
commands, scoped diff and visual evidence are in
CompatibilitySuite/reports/pass59-layer-transforms/REPRODUCTION.md.


## Pass 60 — animated image textures and playback controls

Added TEXS frame selection, uneven durations, rotated rectangles, multiple image
pages and SceneScript texture playback controls with independent/shared clocks.
The decoder preserves the atlas and selects the proper page; the binder supplies
frame UV transforms through image effect chains. Fixed valid same-line varying
and uniform declarations exposed by the pixel tests. No dependencies were added.

The audit found 316 animated image nodes in 73 eligible scenes. Six new tests
bring debug/release totals to 281 tests in 44 suites; both configurations pass.
Both frozen builds pass three shader and three script fixtures; eight Python
checks pass. Twelve new snapshots plus two additional baselines complete without
skipped layers or binder fallbacks. A tiled sphere atlas now renders one animated
sphere; tiled fireworks render individual bursts and lose four script errors.
VHS loses four texture errors, leaving a first-frame background-color dependency
and the missing media-event API. Date/clock clipping and other artifacts remain.

Seven app catalogs (132 checks) are queued behind pass 59. Full equivalency
remains incomplete: media and cursor events, video texture controls, dynamic
texture metadata rebinding, remaining rendering gaps and QoL still need work.
Reproduction steps, source hashes, frozen builds, scoped diff and visual evidence
are in CompatibilitySuite/reports/pass60-texture-animations/REPRODUCTION.md.


### Script component ordering regression lane (pass 61)

Use CompatibilitySuite/script_owner_scene_canaries.json for changes to script
scheduling. It selects 147 eligible scenes with inline effect, skeletal animation
or particle-instance scripts. It is not an exhaustive asset-script inventory.
Retain authored layer/component order and verify first-frame and same-frame shared
dependencies; numeric component indices must not be sorted as strings. Pass 61's
four regression tests reproduce the old scheduling failures. Both full suites
pass 285 tests, with twelve new debug/release snapshots complete. The seven app
catalogs (206 overlapping checks) are queued after pass 60. Reproduction and
frozen manifests: CompatibilitySuite/reports/pass61-script-owner-order/REPRODUCTION.md.


### Dynamic text layout regression lane (pass 62)

Use CompatibilitySuite/text_layout_scene_canaries.json for text layout/rendering
changes. It covers all 240 eligible text-bearing scenes (1,621 text nodes) found
in the local scene corpus. Measure current strings at their font size; saved size
values must not clip script/user content. Check explicit width/row limits,
ellipsis, blank lines, padding, alignment pivots and direct/effect pixel parity.
Use actual texture dimensions in pixel tests instead of indexing a fixed saved
rectangle. Keep texture caches bounded per layer for continuously changing clocks.
Pass 62 has 290 passing tests in each build and sixteen new native snapshots;
the seven release app catalogs (299 checks) are queued after pass 61. Commands,
frozen builds, source hashes and visual evidence are in
CompatibilitySuite/reports/pass62-text-layout/REPRODUCTION.md.

Pass 63 adds live text style bindings and a shared Core Text layout engine for
SceneScript's read-only size property, FrameText dimensions and Metal rendering.
The C host and public text model changed, so debug/release use fresh pass63
scratch directories. Both complete suites pass 298 tests in 45 suites; eight
Python tests and both sets of shader/script fixtures pass. Ten prior-build,
ten debug and ten release local snapshots complete without new diagnostics.
Source hashes, frozen binary hashes, scoped patch, exact commands and limitations
are in CompatibilitySuite/reports/pass63-live-text/REPRODUCTION.md. The 299-check
app-catalog run is serialized after pass 62. Windows metrics, screen anchors,
perspective/MSDF text, asset registration, media and other parity gaps remain.
Pass 58's 260 app checks are complete with zero unexpected capture failures;
script/fallback gaps are retained separately in its completed catalog summary.


Pass 64 adds scene-owned asset handles and packaged font selection through
SceneScript. Seven regression tests verify live/paused font changes, cross-script
handles, path handling and actual font pixels; both full suites pass 305 tests in
46 suites. Both builds pass shader/script fixtures and eight Python tests pass.
The audit finds 73 registration calls in three scripts across two scenes. The Wlop
font-choice fixture visibly selects Jost and matches exactly between debug/release;
its two registration errors disappear. Mount Fuji loses one registration error.
Twenty-one new snapshots complete without skipped layers or renderer fallbacks.
Seven app catalogs (61 overlapping checks) are queued after pass 63. Material
precaching, dynamic layer/model creation, media and other parity gaps remain open.
Evidence: CompatibilitySuite/reports/pass64-asset-handles/REPRODUCTION.md.

Pass 59's seven app catalogs also completed: 108 checks, 39 render passes,
69 declared partials and zero unexpected capture failures. Script diagnostics
remain in 58 checks and renderer fallbacks in three. These are overlapping checks,
not unique-scene coverage or a full quality certificate.


Pass 65 adds all five SceneScript media event classes and change delivery in each
script's layer context. Playback, metadata, timeline and thumbnail-color snapshots
reach native properties; disabled integration clears stale data. Eleven new tests
include actual Metal text/color/visibility changes. Both complete Swift suites
pass 316 tests in 47 suites; both shader/script fixture sets and eight Python tests
pass. The audit identifies media references in 110 scenes (1,300 packaged scripts).
Twenty-two new native snapshots finish with no skipped layers or renderer fallbacks.
VHS loses its last script error, Mount Fuji drops from nine to zero, and the
initialization canary drops from 23 to 21. Those remaining errors are preserved.
The OS media source and actual album-cover texture integration remain open; this
pass does not claim that external player metadata is already connected. Seven
app catalogs (169 overlapping checks) are queued after pass64. Evidence and exact
commands: CompatibilitySuite/reports/pass65-media-events/REPRODUCTION.md.

Pass 60's app catalogs completed: 132 checks, 56 render passes, 76 declared partials
and zero unexpected capture failures. Script errors remain in 70 checks and renderer
fallbacks in four. These overlapping checks are not a full-parity certificate.


## Playback acceptance and queue reconciliation (September 13)

The user's revised goal covers scene/video/web playback, interaction and authored
controls. Creation tools and unrelated library, playlist, scheduling and cloud-sync
features are outside scope. The current summary is
[PLAYBACK_COMPATIBILITY_MATRIX.md](PLAYBACK_COMPATIBILITY_MATRIX.md).

The inactive pass62–66 schedules are retired without marking their partial reports
complete. Preserve their source/binary records. Use
`playback_representative_scene_canaries.json` for the current deduplicated workshop,
model, lighting, text, particle, script, font and input coverage: 59 unique scenes.
It retains the greatest authored screenshot delay among overlapping entries and
places the two earlier package-load failures first. Run the three local fixtures
separately. The 362 disjoint remaining scene fixtures are integration-milestone
coverage, contingent on representative review. Do not enqueue overlapping historical
catalogs on top of this plan.

The lead exclusively runs app launches, GPU validation and performance measurements.
Workers may analyze artifacts and make bounded assigned edits. Keep at most two
implementation changes awaiting integration/validation, and associate every result
with the frozen binary and source manifest, even if workers have since edited the
working tree. Capture success, visual fidelity, interaction and authored controls
are separate acceptance dimensions. Windows fidelity stays unverified without a
matching reference.

`SceneNativeSnapshotTool --cursor-path FILE` supports deterministic pointer input.
FILE contains one normalized Y-up x/y sample per frame, with optional leftDown;
the final sample is held. Static and moving paths for pass67 are retained under
`reports/pass67-cursor-input/cursor-paths`. A normal app capture does not by itself
verify cursor events or behavior under a specific input trajectory.


Pass69 documented color helpers are locally accepted after preserving the legacy
scalar HSV alias behavior in revision1. Both debug/release suites pass 346 tests
in 54 suites; each frozen build passes three shader and three script-host fixtures.
Four real color canaries lose 11 distinct method-error diagnostics; all eight
corrected snapshots have clean runtime diagnostics, with only inspected clock text
differences across builds. The corrected app's 27 captures produce 23 passes and
four declared partials, with no script/binder diagnostics or unexpected failures.
This establishes API/default-scene coverage, not full authored-control UI or
Windows fidelity. Evidence: CompatibilitySuite/reports/pass69-color-helpers/REPRODUCTION.md.

The original combined pass68/69 candidate completed 63 workshop scenes and three
local samples (45 pass, 21 declared partial), with the previous eight script-error
and two binder-fallback scenes unchanged. This broad run exposed two resource
outliers; four serial fresh-process repeats did not reproduce their large relative
regressions. Subsequent 120-second Lake and 165-second ISS checks settle without
accumulating memory growth, including about 23 Lake loops and one full ISS loop.
Pass68 timing/residency has bounded local acceptance; broad resource performance
and Windows timing remain unverified. The 63-scene membership and disjoint 358-scene
remainder are frozen in reports/pass69-color-helpers; the original 59-scene catalog
remains unchanged as historical membership. No overlapping old queue was restarted.


Pass70 module preload has a bounded local checkpoint. Loading all top-level
script bodies before authored initializers removes 27 helper-order errors in
one scene. The new regression fails against the previous production code; both
complete Swift suites pass 347 tests in 54 suites, and both shader/script fixture
sets pass. Nine focused snapshots finish cleanly, with inspected differences
confined to clock text. Frozen70 then completes 63 workshop scenes and three
local samples: 45 pass, 21 declared partial, no unexpected capture failures.
Only the expected 27 diagnostics disappear; seven script-error scenes and two
fallback scenes remain. Windows order/fidelity and full authored behavior remain
unverified. Evidence: CompatibilitySuite/reports/pass70-module-preload/REPRODUCTION.md.

Pass70 integration sweep is complete and review-accepted for local capture accounting. Its immutable representative63 + remainder358 union is 421 eligible workshop scenes: 327 pass and 94 declared partial, with no unexpected capture failure or skipped layer. It retains 35 script-error IDs and 14 renderer-fallback IDs for capability triage. Three local samples remain separate (2 pass / 1 declared partial). This checkpoint does not verify interaction, authored controls, visual fidelity, performance/resource acceptance, audio, or Windows parity. Evidence: CompatibilitySuite/reports/pass70-integration-sweep/verification-summary.json and REPRODUCTION.md.


Pass71 revision4 sound playback has bounded local acceptance. Logical transport,
authored gain, finite completion, bounded CAF fallback and renderer recovery passed
367 executed tests in each full build configuration, all products and fixture
tools, and four separately enabled authored-control/zero-gain output probes.
The deduplicated 79 workshop scenes plus three samples completed with 55 pass /
27 declared partial, no unexpected capture failures or skipped layers. Eighteen
sound-error entries disappeared across 13 scenes with no added diagnostics; the
selected 79 retain 11 script-error and three fallback IDs. Nineteen inspected
image pairs show no new blank/main-composition loss; three changed labels follow
authored sound scripts. Eighteen alternating old/new captures on three selected
scenes did not reproduce the large historical timing drift as a binary difference.
This is not a new whole-421 sweep. Scheduling, long clips, device interruption,
audible quality, full control persistence/restoration, general performance and
Windows fidelity remain open. Exact revision4 provenance and limitations:
CompatibilitySuite/reports/pass71-sound-playback/verification-summary.json and
REPRODUCTION.md. No implementation remains queued for validation.


Pass72 pointer-state binding has bounded local acceptance. A GPU regression
first failed twice on held clicks against pass71 revision4, then passed after
the one-case binder addition. Both configurations passed 368 enabled tests
(five optional probes disabled), all products and shader/script fixtures.
The exact 74-workshop plus three-sample catalog completed with 54 pass /
23 declared partial, no unexpected capture failures or skipped layers, and
exactly 13 removed pointer warnings with no added diagnostics or status changes.
All 13 default app image pairs were inspected without a new blank frame or loss
of main composition. Twelve fixed-step snapshots produced six pixel-identical
before/after pairs, including held clicks: real-scene click-force behavior remains
unverified. The one FPS outlier did not reproduce in six alternating old/new
captures. Effect projection, simulation/target wiring, other pointer-vector
components and Windows fidelity remain open. This is selected-corpus coverage,
not a new whole-421 sweep. Exact evidence: CompatibilitySuite/reports/pass72-pointer-state/
verification-summary.json and REPRODUCTION.md. No implementation is awaiting validation.


Pass73 effect feedback has bounded local acceptance. Initial render-target contents
read before replacement persist per authored effect owner; copy/swap preserves
logical names and duplicate IDs no longer share histories. New storage clears
transparent, while ordinary scratch targets stay transient. Six GPU tests cover
image/text feedback, material bindings, swaps, duplicate IDs and stable source
indices after an earlier effect hides. The original negative fails three released
frames on accepted72. Both clean-layout build configurations pass 374 executed
tests (379 registered, five optional probes disabled), all five products and all
shader/script fixtures. The real off-center ripple now remains visible after two
released frames, while matched all-up old/new images are pixel-identical.

The deduplicated 149 workshop scenes plus three samples completed: 69 pass /
83 declared partial, no unexpected failures, status changes, added diagnostics
or skipped layers. Twelve script-error IDs and two fallback IDs remain in the
selected149. All 152 saved-image pairs were reviewed. Eight fixed-frame nighttime
snapshots give four pixel-identical old/new pairs; six HUD repeats retain identical
city/overlay geometry with changes confined to live FPS/seconds text. Six alternating
RSS captures do not reproduce the large historical delta as a consistent binary
difference: median 826.03 to 852.73 MiB, with old72 also reaching 903 MiB. General
resources remain unverified. This is not a new whole-421 sweep.

Float formats, fit/clear metadata, projection, external targets, shadow bindings,
hidden/re-enabled semantics and Windows fidelity remain open. Authored-control
persistence and broader media/video/web/audio acceptance are separate work. Exact
163-file source manifest, frozen products, comparisons and limits are recorded in
CompatibilitySuite/reports/pass73-effect-feedback/verification-summary.json and
REPRODUCTION.md. No implementation is awaiting validation; no commit was created.

## Playback-first video and script regressions

The September 14 user reprioritization makes functional playback and conspicuous
visual defects the acceptance threshold; imperceptible pixel differences and
missing Windows references alone are not blockers. Preserve historical evidence.

After video transport, texture sampling, or script-host threading changes, run
`swift test --filter 'VideoTransportTests|VideoTexturePlayerTests|ScriptThreadMigrationTests'`
and the normal workshop/script canaries. The pass77 catalog deduplicates the
40-scene embedded-video inventory with required canaries into 64 workshop scenes.
Its two authored intro delays are intentional. The color-movie test checks actual
rendered timing, independent shared-file layers, completion and callback context;
the thread tests retain the false-overflow and native-stack-crash regressions.

## Generated evidence retention (September 15)

The user authorized removal of accumulated report images and copied packages in
`Investigate 100GB storage usage`. Existing JSON, logs and written reviews remain;
historical image links may no longer resolve. Preserve source and binary hashes,
input identities, commands, measurements and review findings.

For ongoing validation, use small temporary image batches, inspect them promptly,
and delete them after recording the review. Keep only bounded diagnostic images
while an unresolved defect requires them. Do not rebuild the historical screenshot
archive or retain duplicate package copies. Keep original workshop inputs intact.
`CompatibilitySuite/reports/` is now ignored by Git; this does not itself enforce
on-disk retention. Avoid starting bulk capture jobs without an explicit cleanup
step, and do not run artifact cleanup concurrently with native measurements.

## Standalone video regression checks

For changes to `VideoRenderer`, run `swift test --filter VideoPlaybackTests`.
These tests exercise actual player output, uninterrupted looping, pause/resume,
mute state, sizing, replacement and immediate/idempotent teardown. Use the normal
representative canaries at integration checkpoints.

`VideoCorpusTests` is an opt-in installed-media check, limited to five eligible
videos per invocation. The pass83 runner records exact input/source/binary hashes
and deletes temporary images after review. Its images come from the current
AVPlayerItem output; layer readiness is checked separately. They do not establish
desktop compositor presentation, audible quality or full application lifecycle.
Keep those claims separate. On the single native test machine, run full integration
suites serially (`swift test --no-parallel`) to avoid competing playback probes.

## Effect and material script access

After changing effect lookup or material property bindings, run
`swift test --filter 'EffectAccessTests|SceneLayerTests|ScriptAnimationTests|DynamicLayerTests'`
and the normal sample, workshop, text and script canaries. The effect tests verify
the resulting effect chain and frame-material constants, including command-pass
indexing, override precedence, retained handles, timeline identity, live properties
and cloned-layer independence. Use the three authored callers recorded in pass84
for focused app comparisons. Keep missing authored layer references and the
turntable's separate one-shot animation dependency distinct from lookup failures.

## Authored properties panel regressions

For property UI changes, run
`swift test --no-parallel --filter 'PropertyPanelTests|PropertyResetTests|WallpaperPropertyTests'`
in debug and release. The panel tests open the actual PropertiesWindowController for ascending, equal
and reversed slider endpoints; measuring a detached List does not evaluate its
lazy rows. Preserve authored values and avoid writes during layout. Real projects
declare min1900/max-100 and min100/max100. Never construct a ClosedRange directly
from unchecked endpoint order or create a stepped zero-length SwiftUI slider.

The pass85 isolated host verifies selected UI-to-renderer and persistence paths.
It does not replace production status-menu navigation or real-workshop control
acceptance. Use a separate bundle identity and disable audio/media through volatile
argument defaults for unattended control checks. Keep rendered evidence disposable.

## Authored cursor event regressions

After changing cursor exports, dispatch or layer hit testing, run
`swift test --no-parallel --filter CursorEventTests` and the sample, workshop, text
and script canaries. Public scene-model layout changes require the clean build
noted above. Pass88 records original image-drag, circle-hover and omitted-flag
text-drag probes with source/input hashes and disposable GPU comparisons.

Check explicit interaction opt-outs, hidden ancestors, parent transforms, live
text bounds, multiple property modules, pause/input loss and dynamic-layer removal.
A successful default screenshot does not exercise callbacks. Deterministic input
probes do not establish physical desktop event delivery, overlap arbitration or
precise parallax/shake hit alignment. Judge visible behavior at normal viewing
scale; imperceptible pixel differences are not blockers.

## Cursor transitions and compiler discovery (pass90)

Exercise press/move/release before a single rendered frame, as well as samples
separated by frames. Verify cancellation, a new post-resume click, buffer limits
and AppKit event coordinates. Callbacks must not trigger extra authored updates,
timer steps or simulation. The original pass89/90 logo-drag probe supplies a real
negative/positive check. UI-tool targeting failures do not prove desktop delivery.

Resolve compiler paths successfully before invoking CMake. After failed compiler
detection or a toolchain change, inspect the dependency compile flags: a cached
Release configuration with empty flags can silently produce unoptimized builds.
Use a fresh CMake configuration to recover defaults, then clean/relink Swift
products. Record dependency hashes along with app/source hashes. The regression
command is `python3 -m unittest CompatibilitySuite.test_build_bridge -v`.

The current selected Xcode requires license acceptance. Validation used child
process `DEVELOPER_DIR=/Library/Developer/CommandLineTools`; global selection and
license status were unchanged. Exact Swift Testing search/runtime paths and
commands are retained in pass90 toolchain/build evidence.

## Script input snapshot regressions (pass91)

For input/property/engine snapshot changes, include `ScriptSnapshotTests` and
`ScriptEngineSnapshotTests` alongside the script lifecycle, media, audio, cursor
and user-property suites. Preserve fresh mutable vectors, arrays and nested
objects across modules, changed values in the same frame, retries after failures,
nil inputs and shutdown. Private native snapshots must never be exposed directly;
define own data members so authored prototype setters cannot intercept delivery.

Compare performance using matching build flags. `swift test -c release` enables
testable imports by default while `swift build -c release` does not; both are
optimized, but their timing is not interchangeable. Record the product compiler
arguments, linked dependency hashes, source manifest and executable hash. Use
serial measurements and avoid generalizing short samples into usability claims.

## Text effect opacity (pass93)

Run `TextRendererTests` for text raster or effect-composition changes. A shader
may replace alpha or expand beyond glyph coverage; layer opacity must still apply
once to the final result. Keep live zero/partial/full opacity, repeated copy
effects, plain text and expanded-effect coverage checks. Do not fix opaque custom
effects by clipping every output to the original glyph mask. Use the original
City intro in pass92/93 as a timed authored regression, then the required sample,
workshop, text and script canaries. Alpha1 authored rectangles remain distinct.

## Effect user textures and placeholders (pass95 revision2)

For effect binding or descriptor changes, run `EffectTextureBindingTests` and
`MediaArtworkTests` with the normal effect/text/material canaries. Effect overrides
can declare system artwork or user file-property bindings independently of their
base material. Preserve logical slots, inherited bindings, empty file fallback,
current/previous covers, authored placeholder alpha, live changes and clear/reset behavior. Use the two original
controlled media sequences and87-scene parser audit from pass94/95. Parser coverage
is separate from render and real desktop-control acceptance. Clean rebuilds remain
required for public scene-model layout changes.

## Desktop display-link scheduling (pass97)

Include `DisplayLinkFrameGateTests` for desktop frame scheduling changes. Exercise
refresh bursts while a frame is queued/running, concurrent producers, pause/stop,
restart and stale completion. Keep elapsed simulation time and cursor transition
delivery intact. Also verify real desktop controls remain responsive under a slow
original scene and after a restart. Offscreen screenshot/benchmark jobs use the
automation timer, so passing those canaries does not validate CVDisplayLink
scheduling. Pass97 verifies two original CUA control workflows plus22 live desktop
frames and20 serviced queue requests. The debug-host first frame still stalls6.96seconds;
final eight requests finish within160ms. Separate bounded queue service acceptance
from smooth startup, sustained FPS and overall usability. Require nonzero engine
work when interpreting native queue probes; a locked desktop can service an idle
queue without rendering any frames.

Pass98 uses a separately linked release host: do not infer optimized FPS from
debug UI-host timing. Whole-module compilation can distribute declarations across
object filenames, so omitting main.swift.o may remove unrelated renderer symbols.
Preserve source/object hashes and include the complete compatible object list when
the package entry symbol differs from the host main. Separate startup preparation
profiles from later recurring work, and sampled diagnostics from timing acceptance.

## Particle input performance (pass99)

Keep particle attribute values/order, filtering, size/camera scaling, opacity and
atlas animation intact when optimizing construction. The nonzero-attribute GPU
regression complements the existing opacity, material-pass and atlas tests. Run
focused particle/coordinate checks, both full suites, fixtures and representative
canaries. Use matching release objects and serial old/new runs after warmup for
performance acceptance. Compare real desktop scheduling separately from offscreen
capture timing. Pass99 records desktop21.97→26.31FPS on one original; do not
extrapolate that short result to every particle scene or sustained playback.
