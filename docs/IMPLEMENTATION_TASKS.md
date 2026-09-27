# Implementation Tasks — Standalone Scene Migration

Task decomposition of `STANDALONE_SCENE_ROADMAP.md`, sized for delegation to Sonnet-class coding agents. Each task has clear inputs, outputs, and acceptance criteria. Tasks within a phase can often run in parallel; cross-phase dependencies are noted.

---

## Phase 0: Stabilize the Current Fork

**Goal:** Document what exists so extraction work is not guessing about behavioral intent.

### 0.1 — Create PATCHLOG.md: Modified Files

**Input:** `linux-wallpaperengine/` submodule (39 modified files per git status)
**Action:** For each modified file in the submodule, diff it against upstream HEAD (`cb0a0f6`). For each hunk, record:
- File path
- What changed (brief description of the hunk)
- Intent category: `shader-compat` | `metal-backend` | `platform-guard` | `input-injection` | `audio-injection` | `parser-fix` | `runtime-fix` | `embedding-support` | `other`
- Destination module (per roadmap target architecture): `NativeSceneCore` | `NativeSceneRenderer` | `NativeSceneCompatibility` | `NativeSceneBridge` | `NativeSceneRuntime` | `keep-upstream` | `delete`
- Risk level: `low` (platform guard) | `medium` (behavioral change) | `high` (semantic divergence from upstream)

**Output:** `docs/PATCHLOG.md` with a table per file and summary counts by category.
**Acceptance:** Every modified file appears. Categories and destinations are filled in. No "unknown" entries without explanation.

**Parallelizable:** Yes, split by directory — `Render/`, `Data/`, `Application/`, `Input/`, `Audio/`, other.

### 0.2 — Create PATCHLOG.md: Untracked Files

**Input:** 16 untracked files in `linux-wallpaperengine/` (CMetalDriver, MetalOutput, SimpleMouseInput, .mm files, CMakeLists-bridge, extract_pkg)
**Action:** For each untracked file, document:
- File path and size
- Purpose (what it does)
- What upstream component it replaces or extends
- Destination module in target architecture
- Dependencies (what upstream headers/classes it imports)

**Output:** Append to `docs/PATCHLOG.md` under a "New Files (macOS-specific)" section.
**Acceptance:** All 16 files documented.

**Parallelizable with 0.1:** Yes.

### 0.3 — Script API Surface Inventory

**Input:** `linux-wallpaperengine/src/WallpaperEngine/Scripting/ScriptEngine.{cpp,h}`, QuickJS host bindings, and any `scriptwall*` or `engine.*` patterns in wallpaper scenes at `~/wallpaper_engine/test_wallpapers/`.
**Action:**
1. Read `ScriptEngine.cpp` and extract every JS global, function, and property exposed to wallpaper scripts.
2. Grep the test wallpaper corpus for `scriptwall`, `engine.`, `wallpaper`, and other script API patterns in `.json` and `.js` files.
3. Produce a frequency table: API name, call count across corpus, whether the current engine implements it.

**Output:** `docs/SCRIPT_API_INVENTORY.md`
**Acceptance:** At least the host-side bindings are fully enumerated. Corpus scan covers all `.js` files in test wallpapers.

**Parallelizable with 0.1/0.2:** Yes.

### 0.4 — Divergence Classification Summary

**Input:** Outputs of 0.1 and 0.2.
**Action:** Aggregate PATCHLOG entries into a summary report:
- Count of changes per category (shader, runtime, parser, renderer, scripting, packaging)
- Count per destination module
- Risk distribution
- Top 5 highest-risk divergences with explanation

**Output:** Summary section at the top of `docs/PATCHLOG.md`.
**Acceptance:** Summary matches the detailed entries.

**Depends on:** 0.1, 0.2.

---

## Phase 1: Build the Compatibility Harness

**Goal:** Make scene coverage measurable before changing anything.

### 1.1 — Define Fixture Corpus Metadata Schema

**Input:** Roadmap section on Compatibility Harness, upstream docs at `linux-wallpaperengine/docs/`.
**Action:** Design a JSON schema (`CompatibilitySuite/schema/fixture.schema.json`) for per-wallpaper metadata:
- `id`: unique fixture identifier
- `name`: human-readable name
- `path`: relative path to wallpaper directory
- `type`: `scene` | `video` | `web`
- `category`: `minimal` | `popular` | `pathological-shader` | `script-heavy` | `text-heavy` | `particle-heavy` | `video-scene` | `regression`
- `expected_features`: array of `light` | `audio` | `text` | `particle` | `rtt` | `video-texture` | `script` | `post-processing`
- `expected_script_apis`: array of API names used
- `expected_object_types`: array of object type strings
- `shader_includes`: array of `#include`/`#require` library names
- `schema_version`: detected format version if available
- `known_status`: `pass` | `partial` | `fail` | `crash` | `untested`
- `notes`: free-form string

**Output:** `CompatibilitySuite/schema/fixture.schema.json`
**Acceptance:** Valid JSON Schema. Covers all metadata fields from the roadmap.

### 1.2 — Scan and Catalog Test Wallpapers

**Input:** `~/wallpaper_engine/test_wallpapers/`, `~/wallpaper_engine/assets/`
**Action:**
1. Walk the test wallpaper directory and parse each `project.json`.
2. For each wallpaper, extract: name, type, preview image path, detected features (scan scene JSON for object types, script references, shader includes, light objects, text objects, particle objects).
3. Generate a `CompatibilitySuite/fixtures.json` conforming to the schema from 1.1.
4. Classify each wallpaper into the corpus categories.

**Output:** `CompatibilitySuite/fixtures.json` with entries for all available test wallpapers.
**Acceptance:** Every wallpaper in the test directory has an entry. Feature detection is automated, not manual.

**Depends on:** 1.1 (schema).

### 1.3 — Build Automated Launch/Render/Report Runner

**Input:** The existing app binary (`.build/release/WallpaperEngine`), fixture list from 1.2.
**Action:** Create a shell script or Swift CLI tool (`CompatibilitySuite/run_suite.sh` or similar) that:
1. Iterates over fixtures in `fixtures.json`
2. Launches the app with each wallpaper path
3. Waits for N frames (configurable, default 60 = 2 seconds at 30fps)
4. Captures: did it crash? did it produce a non-black frame? stderr/stdout logs
5. Writes a JSON report per wallpaper: `{ fixture_id, status, launch_ok, render_ok, black_frame, errors[], duration_ms }`
6. Writes a summary report: `CompatibilitySuite/reports/run_YYYY-MM-DD.json`

**Design constraint:** The app currently takes a single CLI wallpaper path. The runner launches it once per fixture. Capture Metal screenshot requires changes to the app (see 1.4).

**Output:** `CompatibilitySuite/run_suite.sh` + report schema
**Acceptance:** Can run against the full corpus and produce a machine-readable report.

**Depends on:** 1.2 (fixture list).

### 1.4 — Add Screenshot Capture to the App

**Input:** `SceneRenderer.swift`, `WEBridge.h`
**Action:** Add a `--screenshot <output_path>` CLI flag to the app that:
1. Loads the wallpaper
2. Renders N frames
3. Captures the Metal texture to a PNG file
4. Exits with status 0 on success

Implementation: After N render callbacks on the CVDisplayLink, read back the MTKView's `currentDrawable` texture, convert to CGImage via `MTLTexture` → `CIImage` → `CGImage`, write PNG.

**Output:** Modified `main.swift`, `SceneRenderer.swift` (or a new `ScreenshotCapture.swift` helper).
**Acceptance:** `./WallpaperEngine ~/wallpaper_engine/test_wallpapers/some_wallpaper --screenshot /tmp/test.png` produces a valid PNG.

### 1.5 — Add Baseline Performance Capture

**Input:** `PerformanceMonitor.swift`, the runner from 1.3.
**Action:** Add a `--benchmark <output_path>` CLI flag that:
1. Loads the wallpaper
2. Renders for a configurable duration (default 5s)
3. Captures: average CPU frame time, p95 CPU frame time, average FPS, peak RSS memory
4. Writes JSON to the output path
5. Exits

The existing `PerformanceMonitor` already tracks frame timings — expose its ring buffer data.

**Output:** Modified CLI, JSON benchmark output format.
**Acceptance:** Benchmark JSON contains cpu_avg_ms, cpu_p95_ms, fps_avg, memory_peak_mb.

**Parallelizable with 1.4:** Yes (separate CLI flags, separate code paths).

### 1.6 — Add Black-Frame Detection

**Input:** Screenshot capture from 1.4.
**Action:** After capturing a screenshot, analyze pixel data:
1. Sample pixels (e.g., 100 random or grid-sampled points)
2. If >95% of sampled pixels are near-black (all channels < 10/255), flag as `black_frame: true`
3. Include in the per-fixture report

**Output:** Black-frame detection logic in the screenshot/report flow.
**Acceptance:** Known-broken wallpapers are flagged as black-frame; known-working ones are not.

**Depends on:** 1.4.

### 1.7 — CI Execution Plan Document

**Input:** Roadmap CI constraints section.
**Action:** Write a short document (`docs/CI_PLAN.md`) that decides:
1. Whether Metal validation gates run on macOS CI runners or as mandatory local harness runs
2. What the promotion path is from local → CI
3. What GitHub Actions / self-hosted runner configuration would be needed
4. What the thresholds are for: black-frame regression, perceptual similarity, frame time regression

This is a document, not code. It unblocks the decision so later phases don't stall.

**Output:** `docs/CI_PLAN.md`
**Acceptance:** The three decision questions are answered with a recommendation.

**Parallelizable:** Yes, independent of all other 1.x tasks.

---

## Phase 2: Extract a Native Scene Model

**Goal:** Break dependency on upstream model ownership.

### 2.1 — Map Upstream Scene Model Types

**Input:** `linux-wallpaperengine/src/WallpaperEngine/Data/Model/` (13 files: Object.h, Material.h, Effect.h, Property.h, Project.h, Wallpaper.h, Types.h, UserSetting.h, DynamicValue, ScriptedDynamicValue, Model.h)
**Action:** For each upstream model type, document:
- Class name and inheritance hierarchy
- Fields with types
- Which fields are immutable after parse vs. mutated at runtime
- Which fields are accessed in the hot path (per-frame) vs. cold path (load-time)
- Relationships to other model types (parent, children, references)

**Output:** `docs/UPSTREAM_MODEL_MAP.md`
**Acceptance:** Every class in `Data/Model/` is mapped. Hot/cold classification is present.

### 2.2 — Map Upstream Parse Flow

**Input:** `linux-wallpaperengine/src/WallpaperEngine/Data/Parsers/`, `Data/Builders/`
**Action:** Trace the parse flow from `project.json` → scene model:
1. What parser classes exist and in what order they run
2. What JSON keys they read
3. What model objects they construct
4. Where schema/version branching happens
5. Where error recovery or fallback behavior exists

**Output:** `docs/PARSE_FLOW.md` — a sequential walkthrough with key decision points annotated.
**Acceptance:** Someone could rewrite the parser from this document without reading the C++ source.

**Parallelizable with 2.1:** Yes.

### 2.3 — Design Native Scene Model Types (Swift)

**Input:** Outputs of 2.1 and 2.2, roadmap Runtime Architecture Direction section.
**Action:** Design the Swift type system for `NativeSceneCore`:
- `NodeID` (stable integer handle type)
- `SceneDescription` (immutable, normalized scene graph)
- `NodeDescriptor`, `MaterialDescriptor`, `EffectDescriptor`, `PassDescriptor`
- `TextureReference`, `ShaderReference`
- `LightDescriptor`, `CameraDescriptor`, `ParticleDescriptor`, `SoundDescriptor`, `TextDescriptor`
- `UserProperty` (with typed value variants)
- `SceneMetadata` (project info, schema version)
- Parent/dependency indexing via flat arrays keyed by `NodeID`

**Output:** `Sources/NativeSceneCore/SceneModel.swift` (type definitions only, no parsing logic). Plus a `Sources/NativeSceneCore/` directory with the module structure.
**Acceptance:** Types compile. They cover all object types in the upstream model. Hot/cold split is clear. No class hierarchies for hot-path data.

**Depends on:** 2.1, 2.2.

### 2.4 — Add NativeSceneCore SPM Target

**Input:** `Package.swift`
**Action:** Add a new library target `NativeSceneCore` to `Package.swift`. It should:
- Be a pure Swift module (no C dependencies)
- Not depend on `CWEBridge` or `linux-wallpaperengine`
- Be importable by `WallpaperEngine`

**Output:** Modified `Package.swift`, `Sources/NativeSceneCore/` directory.
**Acceptance:** `swift build` succeeds with the new target. The existing app still builds.

**Parallelizable with 2.3:** Can be done first as scaffolding.

### 2.5 — Write Bridge Adapters from Upstream Parsers

**Input:** Native model types from 2.3, parse flow from 2.2.
**Action:** Write adapter code that:
1. Calls existing C++ parsers via the bridge (or reads JSON directly in Swift)
2. Converts upstream model objects into native `SceneDescription`
3. Normalizes schema/version differences at this boundary

**Decision point:** Should adapters call C++ parsers through a new bridge function, or should Swift parse `project.json` + scene JSON directly? The roadmap says "write adapters from current parsers into native types" — so initially wrap the C++ parsers.

**Output:** `Sources/NativeSceneCore/Adapters/` or `Sources/NativeSceneBridge/`
**Acceptance:** A `SceneDescription` can be constructed for test wallpapers. Verified by printing/logging the resulting model.

**Depends on:** 2.3, 2.4.

### 2.6 — Route Swift Code Through Native Model

**Input:** `SceneRenderer.swift`, `DesktopWindowManager.swift`, native model from 2.3.
**Action:** Update Swift-facing code to read scene metadata (name, type, resolution, properties) from native model types instead of querying through the bridge. The C++ engine still owns rendering — this only changes the model layer.

**Output:** Modified Swift files that import `NativeSceneCore`.
**Acceptance:** Scene playback still works. Swift code uses native model types for metadata access.

**Depends on:** 2.5.

---

## Phase 3: Replace Shader Pipeline

**Goal:** Stop patching shader behavior in the upstream fork.

### 3.1 — Inventory Current Shader Pipeline

**Input:** `linux-wallpaperengine/src/WallpaperEngine/Render/Shaders/` (GLSLContext, Shader, ShaderUnit, Variables/), fork patches from PATCHLOG.
**Action:** Document:
- The full shader compilation flow: source loading → `#include` → `#require` → combo resolution → GLSL normalization → SPIRV → MSL
- Every fork-specific fix (from PATCHLOG shader-compat entries)
- Uniform metadata extraction and slot assignment
- Built-in shader library files and their locations
- Known malformed shader patterns from workshop wallpapers

**Output:** `docs/SHADER_PIPELINE.md`
**Acceptance:** Complete flow documented with fork fixes annotated.

### 3.2 — Create NativeSceneCompatibility Module

**Input:** `Package.swift`
**Action:** Add `Sources/NativeSceneCompatibility/` as a new SPM target:
- Pure Swift (or Swift + C interop for glslang/SPIRV-Cross)
- Depends on `NativeSceneCore` for type definitions
- Does NOT depend on `CWEBridge` or upstream engine

**Output:** Modified `Package.swift`, module directory.
**Acceptance:** `swift build` succeeds.

**Parallelizable with 3.1:** Yes.

### 3.3 — Port Include/Require Resolution

**Input:** Shader pipeline docs from 3.1, `ShaderUnit::preprocessRequires()` and include logic.
**Action:** Implement in Swift:
- `#include "filename"` resolution against asset shader paths
- `#require "library"` resolution and injection
- Path search logic matching upstream behavior

**Output:** `Sources/NativeSceneCompatibility/Shaders/ShaderPreprocessor.swift`
**Acceptance:** Given a shader source string and asset paths, produces the fully resolved source. Tested against real wallpaper shaders.

### 3.4 — Port Combo Discovery and Resolution

**Input:** Shader pipeline docs from 3.1.
**Action:** Implement combo `#define` generation from material combo values:
- Parse combo declarations from shader source
- Generate `#define` block from material property values
- Handle float/string combo edge cases (the fork fixes from 0.1)

**Output:** `Sources/NativeSceneCompatibility/Shaders/ComboResolver.swift`
**Acceptance:** Combo defines match upstream output for test wallpapers.

**Parallelizable with 3.3:** Yes.

### 3.5 — Port GLSL-to-MSL Translation

**Input:** `GLSLContext.cpp` (GLSL → SPIRV → MSL pipeline via glslang + SPIRV-Cross).
**Action:** This is the most complex shader task. Options:
- **Option A:** Call glslang and SPIRV-Cross from Swift via C interop (these libraries are already compiled into the build)
- **Option B:** Rewrite as a Swift wrapper that invokes the same C APIs

Implement: GLSL normalization → glslang compilation → SPIRV-Cross MSL generation → slot compaction → address-space fixes.

**Output:** `Sources/NativeSceneCompatibility/Shaders/MetalShaderCompiler.swift` (or similar)
**Acceptance:** Compiles the same shaders as the upstream pipeline with identical MSL output.

**Depends on:** 3.3, 3.4 (preprocessed source is input to compilation).

### 3.6 — Shader Fixture Tests

**Input:** Test wallpapers, shader pipeline.
**Action:** Extract representative shaders from test wallpapers and create a test suite:
1. For each shader: save the input GLSL, expected MSL output (from current engine), and combo values
2. Write a test harness that runs the native pipeline and compares output
3. Cover: basic shaders, shaders with `#include`, shaders with `#require`, shaders with combos, known-pathological shaders

**Output:** `CompatibilitySuite/shader_fixtures/` directory with test data, test runner script or Swift test target.
**Acceptance:** All fixtures pass.

**Depends on:** 3.5.

---

## Phase 4: Replace Runtime Evaluation

**Goal:** Own transforms, animations, property evaluation, and frame state.

### 4.1 — Map Upstream Runtime Update Loop

**Input:** `WallpaperApplication.cpp` (specifically `update()` method), `CWallpaper.cpp`, `CScene.cpp`.
**Action:** Trace the per-frame update path:
- What `WallpaperApplication::update()` does in order
- Transform hierarchy evaluation
- Visibility determination
- Property/animation update
- Script execution timing
- Audio-reactive value updates
- Scene timing and pause behavior

**Output:** `docs/RUNTIME_UPDATE_FLOW.md`
**Acceptance:** The full per-frame evaluation sequence is documented with data flow.

### 4.2 — Design Frame Packet Schema

**Input:** Runtime flow from 4.1, roadmap frame packet requirements.
**Action:** Define the data structures that the runtime produces and the renderer consumes:
- `FramePacket`: top-level container
- Per-node: world transform, visibility, render-item reference
- Per-material: bound textures, uniform values, pass ordering
- Per-light: position, color, attenuation, type
- Per-particle-system: live particle buffer reference, emission state
- Timing: frame time, elapsed time, pause state

Design for flat layout, stable ordering, and measurable size.

**Output:** `Sources/NativeSceneRuntime/FramePacket.swift` (type definitions)
**Acceptance:** Types compile. Size can be computed at runtime for bridge cost measurement.

### 4.3 — Create NativeSceneRuntime Module

**Input:** `Package.swift`
**Action:** Add `Sources/NativeSceneRuntime/` as a new SPM target:
- Depends on `NativeSceneCore`
- Does NOT depend on `CWEBridge`

**Output:** Modified `Package.swift`, module directory.
**Acceptance:** `swift build` succeeds.

### 4.4 — Implement Transform Hierarchy Evaluation

**Input:** Runtime flow from 4.1, scene model from Phase 2.
**Action:** Implement flat-array transform evaluation:
- Input: `SceneDescription` parent indices + per-node local transforms
- Output: world transform array indexed by `NodeID`
- Evaluate in topological order (parents before children)

**Output:** `Sources/NativeSceneRuntime/TransformEvaluator.swift`
**Acceptance:** World transforms match upstream output for test wallpapers.

### 4.5 — Implement Property and Animation Evaluation

**Input:** `DynamicValue.cpp`, `ScriptedDynamicValue.cpp`, upstream model.
**Action:** Implement:
- User property value application
- Animation curve sampling (linear interpolation, easing)
- Audio-reactive value mapping
- Property override cascading

**Output:** `Sources/NativeSceneRuntime/PropertyEvaluator.swift`, `AnimationEvaluator.swift`
**Acceptance:** Animated values match upstream behavior frame-by-frame for test wallpapers.

**Parallelizable with 4.4:** Yes.

### 4.6 — Implement Frame State Stepping

**Input:** 4.4, 4.5, 4.2.
**Action:** Implement the top-level frame step function:
1. Advance scene time
2. Evaluate animations
3. Evaluate transforms
4. Evaluate visibility
5. Produce `FramePacket`

**Output:** `Sources/NativeSceneRuntime/SceneRuntime.swift`
**Acceptance:** `SceneRuntime.step(deltaTime:)` produces a `FramePacket` without calling `WallpaperApplication::update()`.

**Depends on:** 4.4, 4.5, 4.2.

### 4.7 — Bridge Cost Benchmark

**Input:** Frame packet from 4.6, existing benchmark infrastructure from 1.5.
**Action:** Measure the cost of:
1. Producing a `FramePacket` in Swift
2. Serializing/copying it across the bridge (if mixed-mode rendering is active)
3. Compare against the current baseline where everything runs in C++

**Output:** Benchmark results document, decision on whether Phase 4 and 5 must merge.
**Acceptance:** Numbers exist. Decision is documented.

**Depends on:** 4.6, 1.5.

---

## Phase 5: Replace Renderer Core

**Goal:** Own rendering outcome rather than binding into upstream render objects.

### 5.1 — Map Upstream Render Pass Structure

**Input:** `CPass.cpp`, `CScene.cpp`, `CFBO.cpp`, `CImage.cpp`, `CParticle.cpp`, the Metal `.mm` files.
**Action:** Document:
- Pass types and their ordering
- FBO/render-target creation and lifecycle
- Material-to-pass binding
- Texture binding per pass
- Uniform buffer layout per pass
- Quad/mesh submission per pass
- Particle rendering path
- Post-processing passes

**Output:** `docs/RENDER_PASS_MAP.md`
**Acceptance:** Complete pass graph for a representative multi-pass wallpaper.

### 5.2 — Create NativeSceneRenderer Module

**Input:** `Package.swift`
**Action:** Add `Sources/NativeSceneRenderer/` as a new SPM target:
- Depends on `NativeSceneCore`, `NativeSceneRuntime`
- Links Metal, MetalKit frameworks
- Does NOT depend on `CWEBridge`

**Output:** Modified `Package.swift`, module directory.
**Acceptance:** `swift build` succeeds.

### 5.3 — Implement Metal Pass Graph

**Input:** Render pass map from 5.1.
**Action:** Implement a pass scheduler that:
- Takes a `FramePacket` as input
- Determines pass ordering from scene render target dependencies
- Creates/reuses `MTLRenderPassDescriptor`s
- Manages render target textures (`MTLTexture` pool)

**Output:** `Sources/NativeSceneRenderer/PassGraph.swift`
**Acceptance:** Pass ordering matches upstream for test wallpapers.

### 5.4 — Implement Material Resource Binding

**Input:** Render pass map from 5.1, shader pipeline from Phase 3.
**Action:** Implement:
- Pipeline state object (PSO) creation from compiled MSL
- Texture binding by slot
- Uniform buffer creation and upload
- Sampler state management

**Output:** `Sources/NativeSceneRenderer/MaterialBinder.swift`
**Acceptance:** Materials bind correctly for basic wallpapers.

### 5.5 — Implement Quad/Image Rendering

**Input:** `CImage.cpp`, `CImage.mm`.
**Action:** Implement the most common render object type:
- Full-screen quad submission
- Textured quad with material
- Vertex buffer management

**Output:** `Sources/NativeSceneRenderer/ImageRenderer.swift`
**Acceptance:** Image-only wallpapers render identically to upstream.

### 5.6 — Implement Particle Rendering

**Input:** `CParticle.cpp`.
**Action:** Implement particle system rendering:
- Particle buffer management
- Billboard/oriented particle submission
- Particle state update integration with runtime

**Output:** `Sources/NativeSceneRenderer/ParticleRenderer.swift`
**Acceptance:** Particle wallpapers render.

**Parallelizable with 5.5:** Yes.

### 5.7 — Implement Lighting and Post-Processing

**Input:** Render pass map from 5.1.
**Action:** Implement:
- Light uniform upload
- Lighting pass execution
- Post-processing passes (bloom, blur, color correction)
- Render target chaining

**Output:** `Sources/NativeSceneRenderer/LightingPass.swift`, `PostProcessPass.swift`
**Acceptance:** Lit wallpapers render. Post-processing effects visible.

### 5.8 — Integration: Full Native Render Path

**Input:** All 5.x components.
**Action:** Wire the full path:
1. `SceneRuntime.step()` → `FramePacket`
2. `PassGraph.execute(packet)` → rendered frame
3. `SceneRenderer.swift` blits native output to screen

**Output:** Modified `SceneRenderer.swift` with a native rendering code path (feature-flagged alongside the existing bridge path).
**Acceptance:** Test wallpapers render through the fully native path. Compatibility harness comparison shows acceptable visual match.

**Depends on:** All Phase 5 tasks + Phase 4.

---

## Phase 6: Replace Script Host

**Goal:** Eliminate opaque upstream script behavior.

### 6.1 — Inventory Script Host Bindings

**Input:** `ScriptEngine.cpp`, script API inventory from 0.3.
**Action:** For each JS binding exposed by the current host:
- Function signature
- What engine state it reads/writes
- Whether it's called per-frame or on-event
- Frequency in the wallpaper corpus

**Output:** `docs/SCRIPT_HOST_BINDINGS.md`
**Acceptance:** Every binding in `ScriptEngine.cpp` is documented.

### 6.2 — Implement Native Script Host

**Input:** Script host bindings from 6.1.
**Action:** Using QuickJS (already compiled), implement a new host layer in Swift or C:
- `engine` global object with all required properties
- Script lifecycle hooks: `init`, `update`, `destroy`
- Property access/update hooks
- Timing APIs
- Audio query helpers
- Start with the top-10 most-used APIs from the corpus frequency report

**Output:** `Sources/NativeSceneRuntime/ScriptHost.swift` (or `Sources/NativeSceneBridge/ScriptHost.cpp` if C interop is cleaner)
**Acceptance:** Script-driven test wallpapers run. Script errors are traceable to missing APIs, not opaque crashes.

**Depends on:** 6.1, Phase 4 (runtime owns the state scripts need to access).

### 6.3 — Script Compatibility Matrix

**Input:** 6.2, corpus from Phase 1.
**Action:** Run the compatibility harness against all script-using wallpapers with the new host. Produce a matrix: wallpaper × API → supported/missing/error.

**Output:** `CompatibilitySuite/reports/script_compatibility.json`
**Acceptance:** Matrix exists. Coverage percentage is computed.

---

## Phase 7: Replace Text

**Goal:** Support text objects.

### 7.1 — Inventory Text Object Format

**Input:** Upstream `ObjectParser.cpp` (the code that currently skips text objects), scene JSON files that contain text objects.
**Action:** Document:
- Text object JSON schema
- Font reference format
- Styling properties (size, color, alignment, effects)
- Dynamic text update mechanism (from scripts/properties)

**Output:** `docs/TEXT_OBJECT_FORMAT.md`
**Acceptance:** Schema documented from real wallpaper examples.

### 7.2 — Implement Text Parsing

**Input:** Text format from 7.1.
**Action:** Parse text objects into `TextDescriptor` in `NativeSceneCore`.

**Output:** `Sources/NativeSceneCore/TextParser.swift`
**Acceptance:** Text objects parse without error for text-containing wallpapers.

### 7.3 — Implement Text Rendering

**Input:** Text descriptors from 7.2.
**Action:** Implement text rendering using Core Text / Core Graphics:
- Font resolution (map WE font names to system fonts)
- Glyph layout
- Render to texture atlas
- Submit as textured quad in the pass graph
- Handle dynamic text updates

**Output:** `Sources/NativeSceneRenderer/TextRenderer.swift`
**Acceptance:** Text-heavy wallpapers show visible, correctly positioned text.

---

## Phase 8: Retire Upstream Runtime ✓

**Completed.** `CWEBridge`, `libwallpaperengine.a`, and `SceneDescriptionExportTool` have been removed. The CMake build now only produces the vendored dependency libraries (glslang, SPIRV-Cross, QuickJS). The app builds and renders scenes using the native Swift stack exclusively.

---

## Task Dependency Graph (Summary)

```
Phase 0: [0.1, 0.2, 0.3] → 0.4
Phase 1: 1.1 → 1.2 → 1.3   |   [1.4, 1.5, 1.7] parallel   |   1.4 → 1.6
Phase 2: [2.1, 2.2] → 2.3   |   2.4 (scaffold, anytime)     |   2.3 → 2.5 → 2.6
Phase 3: [3.1, 3.2] → [3.3, 3.4] → 3.5 → 3.6
Phase 4: 4.1 → [4.2, 4.3] → [4.4, 4.5] → 4.6 → 4.7
Phase 5: 5.1 → [5.2, 5.3, 5.4] → [5.5, 5.6, 5.7] → 5.8
Phase 6: 6.1 → 6.2 → 6.3
Phase 7: 7.1 → 7.2 → 7.3
Phase 8: 8.1 → 8.2 → 8.3
```

Cross-phase dependencies:
- Phase 1 should complete before Phase 2 (baseline needed)
- Phase 2 must complete before Phase 4 (native model feeds runtime)
- Phase 3 can run in parallel with Phase 2 (independent subsystem)
- Phase 4 must complete before Phase 5 (runtime produces frame packets for renderer)
- Phase 6 depends on Phase 4 (script host needs runtime state access)
- Phase 7 depends on Phase 2 (text parsing) and Phase 5 (text rendering)
- Phase 8 depends on all prior phases

## Agent Sizing Notes

**Small agent tasks (< 30 min, mostly research/docs):**
0.1, 0.2, 0.3, 0.4, 1.1, 1.7, 2.1, 2.2, 2.4, 3.1, 3.2, 4.1, 4.2, 4.3, 5.1, 5.2, 6.1, 7.1, 8.1

**Medium agent tasks (30-90 min, focused implementation):**
1.2, 1.3, 1.4, 1.5, 1.6, 2.3, 2.5, 2.6, 3.3, 3.4, 4.4, 4.5, 4.7, 5.3, 5.4, 5.5, 6.3, 7.2, 8.2, 8.3

**Large agent tasks (90+ min, complex implementation):**
3.5, 3.6, 4.6, 5.6, 5.7, 5.8, 6.2, 7.3

Large tasks should be further decomposed when they are reached. The descriptions above provide enough context for that decomposition.
