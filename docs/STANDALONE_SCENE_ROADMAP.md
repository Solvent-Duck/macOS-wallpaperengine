# Standalone Scene Roadmap

## Goal

Turn `macOS-wallpaperengine` into a standalone macOS-native Wallpaper Engine scene runtime with eventual 100% scene coverage, instead of treating `linux-wallpaperengine` as the long-term engine.

This is not a renderer swap. It is a compatibility-engine project.

## Current Architecture

The repo has a fully native scene stack:

- Swift app shell in `Sources/WallpaperEngine`
- Native scene modules: `NativeSceneCore`, `NativeSceneRuntime`, `NativeSceneCompatibility`, `NativeSceneRenderer`
- `NativeSceneBridge` adapts the native parser for the app
- `CShaderCompiler` wraps vendored glslang/SPIRV-Cross for GLSL→Metal shader compilation
- `CScriptHost` wraps vendored QuickJS for wallpaper scripting
- `linux-wallpaperengine` submodule is retained only as a source for vendored third-party dependencies (glslang, SPIRV-Cross, QuickJS)

The legacy `CWEBridge`, `libwallpaperengine.a`, and `SceneDescriptionExportTool` have been removed.

## Target Architecture

Build a native scene stack under the app and reduce `linux-wallpaperengine` to a temporary reference implementation during migration.

Target module split:

- `Sources/WallpaperEngine/App`
  macOS app lifecycle, windows, settings, diagnostics.
- `Sources/WallpaperEngine/SceneKit`
  Pure-Swift or Swift-facing orchestration layer for scene playback.
- `Sources/NativeSceneCore`
  Standalone scene model, parsers, property system, animation state, script bindings.
- `Sources/NativeSceneRenderer`
  Metal renderer, passes, textures, frame graph, particles, lighting, text.
- `Sources/NativeSceneCompatibility`
  Shader preprocessing, combo resolution, built-in include libraries, asset compatibility shims, conformance helpers.
- `Sources/NativeSceneBridge`
  Minimal C/C++ interop only where unavoidable, ideally shrinking over time rather than growing.

Long-term bridge goal:

- Swift should talk to your runtime directly.
- There should be no `WallpaperApplication` or `ApplicationContext` dependency in the playback path.
- `linux-wallpaperengine` should remain only as a temporary oracle for behavior comparisons and fixture extraction.

## Migration Principles

1. Replace subsystems behind stable boundaries, not by global rewrite.
2. Build a compatibility harness before claiming coverage improvements.
3. Keep one canonical scene model owned by this repo.
4. Treat workshop wallpapers as conformance fixtures, not ad hoc bug reports.
5. Prefer macOS-native rendering behavior over preserving upstream internals.
6. Do not let new app code depend more deeply on `linux-wallpaperengine`.
7. Measure mixed-runtime overhead explicitly; do not assume Swift/C++ split phases are cheap enough.

## Operational Constraints

### Performance Valley of Death

The highest-risk migration window is the mixed-mode period where:

- a native scene model feeds an upstream renderer
- a native runtime evaluates frame state and pushes it across the bridge every frame

The risk is not theoretical. Per-frame Swift/C++ bridge traffic can erase frame budget quickly, especially for:

- transform-heavy scenes
- large object counts
- particle systems
- script-driven property churn

Rule:

- Phase 1 must establish baseline CPU and GPU timings for representative wallpapers.
- Every mixed-mode phase must compare against those baselines.
- If the bridge cost is too high, collapse Runtime and Renderer replacement into one larger step rather than preserving the phase boundary.

### Memory Management Friction

Mixed Swift and C++ ownership will be one of the main failure modes during extraction.

Risks:

- leaks when Swift unloads scene objects but C++ resources remain alive
- use-after-free when C++ caches point back into transient Swift-owned state
- accidental retain cycles in adapter layers

Rule:

- native/core model types must not be exposed to C++ by direct object reference where avoidable
- default to flat, arena-owned frame packets across the bridge for per-frame data exchange
- use handle-based indirection only for long-lived resources or lifecycle-managed control paths, not for hot per-frame property traffic
- scene unload and reload must become explicit lifecycle test cases in the compatibility harness

Default boundary decision:

- mixed-mode runtime to renderer communication should use a single frame packet or a small fixed set of packets that can be measured, copied, and versioned explicitly
- packet contents should be plain data with stable layout, not graphs of Swift or C++ object references
- if packet size or rebuild cost becomes the bottleneck, optimize packet construction first before introducing more granular bridge indirection

### Script Compatibility Risk

Script host replacement is a major compatibility risk because many wallpapers depend on undocumented globals, timing, and engine behavior.

Rule:

- script API usage inventory starts in Phase 0, not later
- the runtime architecture must be informed by real wallpaper script usage before runtime replacement is finalized

### CI Enforcement

The compatibility harness is only useful long term if regressions are enforced automatically.

Rule:

- reports, screenshots, hashes, and metrics must be CI-readable
- PRs should fail when fixture coverage regresses beyond defined thresholds
- visual checks should use tolerances such as frame hash plus perceptual similarity, not raw byte equality alone

Infrastructure constraint:

- screenshot and GPU-timing gates require macOS execution with Metal access
- if self-hosted or hosted macOS runners are not available yet, treat the harness as required local pre-PR validation first and promote it to a blocking CI gate only after runner availability is solved

## What To Keep Temporarily

Keep during early phases:

- package/container reading
- some asset-location logic
- selected parsers where behavior is already close enough
- third-party libs that are still useful in the final architecture
  - `glslang`
  - `SPIRV-Cross`
  - `quickjs`, if you keep JS compatibility
  - FFmpeg, if video assets remain relevant

Replace first:

- runtime orchestration
- shader preprocessing and translation rules
- Metal pass binding and frame graph
- script API surface
- text system

Replace last:

- package parsing
- filesystem/container abstraction

## Compatibility Harness

This project will not reach 100% scene coverage without explicit conformance testing.

Add a `CompatibilitySuite` with:

- a curated wallpaper corpus
  - target at least 40 to 50 fixtures before Phase 1 is considered complete
  - minimal fixtures
  - popular workshop scenes
  - pathological shaders
  - heavy script-driven scenes
  - text-heavy scenes
  - particle and RTT-heavy scenes
  - video scenes
  - known bug-regression scenes from the current issue backlog
- per-wallpaper metadata
  - detected or inferred asset/schema version where available
  - expected object types
  - expected script APIs
  - expected shader libraries/includes
  - expected special features: lighting, audio, text, particles, video, render targets
- replay diagnostics
  - parser failures
  - unsupported feature hits
  - shader translation failures
  - script API misses
  - render pass failures
  - black-frame detection
- baseline performance capture
  - CPU frame time
  - GPU frame time where available
  - bridge overhead for mixed-mode phases
  - memory growth across repeated load/unload cycles

Recommended outputs:

- JSON run report per wallpaper
- screenshot per wallpaper
- optional frame hash for stable fixtures
- performance sample per wallpaper
- feature coverage dashboard

Recommended CI gates:

- fixture must launch without new fatal errors
- black-frame rate must not regress past threshold
- perceptual similarity against baseline must remain above threshold for stable fixtures
- CPU and GPU frame times must not regress past configured tolerance on benchmark fixtures

Success metric:

- coverage is counted by rendered correctness categories, not by “app launched successfully”.

## Proposed Module Boundaries

### Runtime Architecture Direction

The workshop file format is hierarchical. The runtime does not need to preserve that hierarchy as a heap of mutable objects.

Adopt a hybrid architecture:

- `NativeSceneCore` owns an immutable, normalized scene description.
- `NativeSceneRuntime` owns mutable frame-state and hot-path evaluation data.
- `NativeSceneRenderer` consumes flat frame packets and GPU-friendly buffers, not authoring objects.

Rules:

- do not build the hot path around recursive traversal of a deep Swift class hierarchy
- do not expose Swift object references across the runtime/renderer boundary where handles or snapshots are sufficient
- preserve authoring semantics in the parsed model, but normalize identity and relationships into stable IDs and indices
- flatten hot components aggressively: transforms, visibility, animation channels, light state, particle state, render items, script-bound properties
- keep cold data conventional and descriptive: asset metadata, parsed material definitions, diagnostics, source provenance
- optimize for predictable ownership, cache locality, and measurable bridge packets rather than ideology about pure SoA everywhere

Recommended shape:

- immutable scene model with `NodeID`-style handles, parent indices, dependency indices, and typed descriptor arrays
- mutable runtime arrays for world transforms, visibility, animated values, script outputs, light uniforms, and render extraction
- renderer-facing frame packets that are already sorted and batched for pass execution
- explicit schema/version normalization at parse time so runtime and renderer do not branch on workshop-era format quirks more than necessary

Non-goal:

- a 1:1 Swift reimplementation of the upstream object graph with per-frame recursive traversal

### 1. Native Scene Model

Create a standalone scene domain model that does not depend on `linux-wallpaperengine` render classes.

Own:

- project metadata
- immutable normalized scene description
- schema/version normalization rules
- node identity and relationship tables
- object types
- materials
- passes
- textures
- lights
- cameras
- particles
- sounds
- text descriptors
- user properties and animated values

Design constraints:

- prefer stable integer handles and typed descriptors over object references
- preserve hierarchy semantics without requiring a mutable class tree at runtime
- separate authoring-time descriptors from frame-time state
- normalize version-specific scene/property/material differences at parse time where practical

Exit criterion:

- Swift and renderer code consume your model types, not upstream model types.

### 2. Native Runtime

Build a frame-time runtime that evaluates:

- transform inheritance
- visibility
- property overrides
- animation curves
- audio-reactive state
- script-driven values
- scene timing and pause behavior

Implementation direction:

- evaluate frame state from flat runtime storage keyed by stable IDs
- treat the parsed scene model as mostly immutable input
- produce renderer-facing snapshots or frame packets instead of exposing runtime internals directly
- flatten hot-path state into arrays or arena-owned buffers where iteration order is known and measurable

Exit criterion:

- frame state can be stepped without constructing `WallpaperApplication`.

### 3. Native Shader Pipeline

Own the full shader path:

- source loading
- `#include` and `#require`
- combo discovery and resolution
- uniform metadata extraction
- built-in shader library compatibility
- GLSL normalization
- GLSL to MSL path
- Metal slot compaction and address-space fixes
- diagnostics and source dumps

This should become the first fully independent subsystem because it is already accumulating macOS-specific compatibility logic.

Exit criterion:

- the renderer no longer calls upstream shader preprocessing code.

### 4. Native Renderer

Build a Metal-native renderer around a controlled frame graph:

- scene render targets
- pass scheduling
- material/pass resource binding
- mesh/quad submission
- particles
- offscreen buffers
- post-processing
- texture streaming
- audio buffer upload
- lighting data upload

Exit criterion:

- a scene frame can render from your runtime state without calling upstream render objects like `CImage`, `CParticle`, `CPass`, or `CScene`.

### 5. Script Compatibility Layer

This is mandatory for full scene coverage.

Own:

- `engine` global
- expected script lifecycle hooks
- property access/update hooks
- timing APIs
- audio/query helpers
- object/material lookup APIs as needed by real wallpapers

Recommendation:

- keep `quickjs` if it is already sufficient, but replace the host bindings entirely.

Exit criterion:

- script evaluation errors are traceable to missing APIs in your layer, not opaque upstream behavior.

### 6. Text System

Text support cannot remain “unsupported yet” if the goal is 100%.

Own:

- text object parsing
- font resolution
- glyph layout
- text mesh or atlas generation
- styling effects required by scenes
- texture refresh when text changes

Exit criterion:

- text objects render in common workshop scenes with acceptable fidelity.

## Replacement Order

### Phase 0: Stabilize The Current Fork

Purpose:

- stop losing time to avoidable regressions while building the standalone plan.
- audit the current fork deeply enough that later extraction work is not guessing about behavioral intent.

Actions:

- freeze new feature work inside `linux-wallpaperengine` unless it unlocks the next extraction step
- keep diagnostic dumps and compatibility logging
- walk the fork diff against upstream and document every current patch that diverges from upstream
- record intent, risk, and likely destination module for each divergence, not just the raw code delta
- start script API surface inventory from wallpapers already available locally
- tag fork changes that are schema/version compatibility fixes versus renderer-specific fixes

Deliverables:

- `PATCHLOG.md` for all fork-local behavioral changes
- compatibility failure taxonomy
- initial script API frequency report
- divergence classification report: shader, runtime, parser, renderer, scripting, packaging

### Phase 1: Build The Compatibility Harness

Purpose:

- make scene coverage measurable.

Actions:

- define the wallpaper corpus
- add automated launch/render/report flow
- save screenshots and failure reports
- classify unsupported features automatically where possible
- capture baseline CPU and GPU timings
- capture scene load/unload memory behavior
- expand script API usage inventory across the fixture corpus
- include schema/version tagging in fixture metadata
- decide whether gates run on macOS CI runners or as mandatory local harness checks until runner support exists

Deliverables:

- `CompatibilitySuite/fixtures.json`
- baseline report for the current engine
- benchmark fixture set with timing baselines
- script API usage report
- CI execution plan for Metal-capable validation

Exit criterion:

- any runtime change can be evaluated against the corpus.

### Phase 2: Extract A Native Scene Model

Purpose:

- break dependency on upstream model ownership.

Actions:

- define immutable native scene descriptors and handle types
- normalize parent/dependency relationships into stable IDs or indices
- define schema/version adapters and compatibility normalization rules
- write adapters from current parsers into native types
- route Swift-facing code through native model APIs
- keep authoring data separate from frame-state concerns

Deliverables:

- `NativeSceneCore` module
- bridge adapters from existing parsers
- schema/version normalization notes and tests

Exit criterion:

- scene playback setup no longer depends on upstream model classes outside an adapter boundary.

### Phase 3: Replace Shader Pipeline

Purpose:

- stop patching shader behavior in the upstream fork.

Actions:

- move current shader preprocessing code into a native compatibility module
- port all fork fixes already added on macOS
- add explicit compatibility rules for malformed workshop shaders
- make shader translation independently testable

Deliverables:

- `NativeSceneCompatibility/Shaders`
- shader fixture tests from real wallpapers

Exit criterion:

- `SceneRenderer` path compiles shaders without upstream `Shader`, `ShaderUnit`, or `GLSLContext`.

### Phase 4: Replace Runtime Evaluation

Purpose:

- own transforms, animations, property evaluation, and frame state.

Actions:

- create a data-oriented update loop keyed by stable IDs
- evaluate user settings and animated values
- implement audio-driven data updates
- implement hierarchy resolution, visibility, and timing without a mutable object graph
- define renderer-facing frame packets and extraction boundaries as the default mixed-mode bridge contract
- benchmark hot-path storage layouts before broadening the runtime surface

Deliverables:

- `NativeSceneRuntime`
- frame-state snapshot structures
- frame packet schema and measurement hooks
- benchmark notes for transform/light/script packet costs

Exit criterion:

- frame evaluation runs without `WallpaperApplication::update`.

Contingency:

- if runtime-to-renderer bridge cost is too high, merge this phase with Phase 5 and replace runtime plus renderer together.

### Phase 5: Replace Renderer Core

Purpose:

- own rendering outcome rather than binding into upstream render objects.

Actions:

- implement native pass graph
- implement material resource binding
- implement quad/image rendering
- implement scene lights, render targets, post-processing, particle submission
- consume extracted frame packets rather than authoring objects or runtime references

Deliverables:

- `NativeSceneRenderer`

Exit criterion:

- rendering no longer instantiates upstream `CScene`, `CRenderable`, `CImage`, `CParticle`, or `CPass`.

### Phase 6: Replace Script Host

Purpose:

- eliminate a major source of black screens and undefined behavior.

Actions:

- inventory real wallpaper script API usage
- implement `engine` host object and required globals
- bind scene/property APIs into the native runtime

Deliverables:

- script compatibility matrix
- host API coverage report

Exit criterion:

- script-driven scenes run against your host bindings.

### Phase 7: Replace Text

Purpose:

- remove one of the last obvious unsupported object types.

Actions:

- parse text objects
- layout and render text
- support dynamic updates from scripts/properties

Harness requirement:

- text-heavy scenes must already exist as explicit known-failure fixtures from Phase 1 onward so progress is measurable before this phase begins.

Exit criterion:

- text-heavy wallpapers no longer fail or render blank due to unsupported text objects.

### Phase 8: Retire Upstream Runtime ✓

**Completed.** `CWEBridge`, `libwallpaperengine.a`, and `SceneDescriptionExportTool` removed. App builds and renders scenes using only the native Swift stack plus vendored shader/script compilers.

## Immediate Work Queue

These are the next concrete tasks that should happen in this repo.

1. Create `docs/PATCHLOG.md` and record every behavior patch already made in the fork.
2. Walk the entire fork diff against upstream and annotate intent, destination subsystem, and risk for each divergence.
3. Start script API usage inventory immediately from the local wallpaper corpus, especially black-screening scenes.
4. Create a `CompatibilitySuite` folder with an initial target of 40 to 50 stratified fixtures.
5. Add baseline performance benchmarking to the compatibility harness and define benchmark fixtures.
6. Add schema/version tagging to fixture metadata and identify known format families that must normalize cleanly.
7. Define immutable native scene descriptors, stable handle types, and parent/dependency indexing rules.
8. Define the runtime/frame-state split: authoring descriptors vs mutable evaluation storage.
9. Define renderer frame-packet boundaries so pass submission never depends on traversing scene objects.
10. Add a native shader package and move the current fork-specific shader fixes there.
11. Inventory object-type coverage and tag every unsupported type in reports.
12. Define a “reference frame” capture flow so visual regressions are trackable.
13. Decide whether Metal validation is gated by macOS CI runners or required local harness runs until CI support exists.
14. Define mixed-runtime bridge packet rules so per-frame data crossing is measurable and batchable.

## Risks

- Chasing full fidelity without a harness will waste months.
- Script compatibility may become the longest pole.
- Text and particles are easy to defer and expensive to ignore.
- Replacing everything at once will stall the project.
- Leaving app code coupled to upstream types will make extraction much harder later.
- Overcorrecting into “everything must be SoA” can make cold-path code harder to evolve without improving frame time.
- A native Swift class graph that survives into hot-path evaluation is likely to recreate the same ownership and locality problems the migration is supposed to remove.
- Underestimating schema/version drift across workshop assets can invalidate early scene-model assumptions.
- Pretending Metal screenshot validation is a normal headless CI problem will delay meaningful enforcement if macOS runner strategy is not chosen early.

## Decision Rules

Use these rules during migration:

- If a fix is shader-Metal specific, prefer adding it in the native shader pipeline, not deeper in upstream.
- If a feature changes scene semantics, implement it in the native runtime, not in Swift UI code.
- If a wallpaper-specific quirk appears more than once, encode it as compatibility behavior with a test.
- If a subsystem needs repeated upstream patching, move it earlier in the extraction order.
- If data is touched every frame across many objects, move it into runtime-owned flat storage before expanding feature work around it.
- If data is mostly descriptive or load-time only, keep it in the immutable scene model instead of forcing it into hot-path layouts.

## Definition Of Done

This project is standalone when all of the following are true:

- the app does not link `libwallpaperengine.a`
- the playback path does not instantiate `WallpaperApplication`
- the scene model, runtime, scripts, and renderer are owned by this repo
- compatibility is measured against a real scene corpus
- scene failures are classified by unsupported behavior rather than opaque engine errors
- new scene support work lands in native modules, not in the upstream fork
