# Execution Log

## 2026-04-03

### Phase 0 Audit Closure

Changes:
- Audited the current state of Phase 0 deliverables against [`docs/IMPLEMENTATION_TASKS.md`](./IMPLEMENTATION_TASKS.md).
- Added [`docs/PHASE_0_AUDIT.md`](./PHASE_0_AUDIT.md) to record what had already been done and what was missing.
- Added [`docs/PATCHLOG.md`](./PATCHLOG.md) as the consolidated divergence inventory required by the roadmap.

Functionality and impact:
- Later phases now have a single source of truth for fork-local behavior.
- The audit confirms that the submodule divergence is still concentrated in embedding, Metal rendering, shader compatibility, and parser/runtime fixes.
- The remaining plan can now proceed with explicit knowledge of what must be preserved versus extracted or deleted.

### Phase 1 Harness Foundation

Changes:
- Added `CompatibilitySuite/schema/fixture.schema.json` to define the machine-readable fixture catalog format.
- Added `CompatibilitySuite/generate_fixtures.py` to scan the local wallpaper corpus and derive fixture metadata automatically.
- Generated `CompatibilitySuite/fixtures.json` from the current local corpus.
- Added [`docs/CI_PLAN.md`](./CI_PLAN.md) to lock the promotion path and enforcement strategy before renderer automation work starts.

Functionality and impact:
- Fixture metadata can now be regenerated from the wallpaper corpus instead of being curated by hand.
- The current local corpus snapshot contains three scene fixtures: `deep_space`, `neon_sunset`, and `shimmering_particles`.
- Automated classification already highlights the main compatibility risk in the corpus: `shimmering_particles` depends on `applyUserProperties` and `thisObject`, which the current script runtime does not expose.
- The harness has an agreed CI shape before screenshot and benchmark features are added to the app.

### Phase 1 App Automation

Changes:
- Added non-interactive launch parsing for `--screenshot`, `--benchmark`, `--frames`, and `--benchmark-duration`.
- Added an automation controller so the app can execute capture tasks sequentially and then exit cleanly.
- Added PNG capture from the scene renderer's Metal output texture.
- Added benchmark JSON export from the in-process performance monitor.

Functionality and impact:
- `WallpaperEngine <wallpaper> --screenshot <file>` now writes a PNG and exits.
- `WallpaperEngine <wallpaper> --benchmark <file>` now writes JSON containing `cpu_avg_ms`, `cpu_p95_ms`, `fps_avg`, `memory_peak_mb`, and `sample_count`.
- Verified locally with `deep_space`: the automation flow produced a valid `1920x1080` PNG and benchmark JSON in `/tmp/`.

### Phase 1 Suite Runner

Changes:
- Added `CompatibilitySuite/run_suite.py` to launch the app per fixture, capture stdout and stderr, and write per-fixture plus summary JSON reports.
- Added `CompatibilitySuite/schema/run-report.schema.json` for the report format.
- Extended screenshot capture to emit a PNG sidecar JSON with black-frame classification metadata.

Functionality and impact:
- The harness now measures `launch_ok`, `render_ok`, `black_frame`, `duration_ms`, and benchmark output per fixture.
- Full local corpus run completed with the current three fixtures.
- Initial baseline:
  - `neon_sunset`: `pass`
  - `deep_space`: `fail` (`black_frame: true`)
  - `shimmering_particles`: `fail` (`black_frame: true`)
- This gives Phase 2+ work a concrete regression target instead of anecdotal testing.

### Phase 1 Black-Frame Investigation

Changes:
- Fixed Apple scene clearing so Metal-backed framebuffers are explicitly cleared before scene draws.
- Added Apple-side fallback decoding for non-power-of-two compressed textures by loading sibling image assets into padded Metal textures when direct TEXB upload is invalid on Metal.
- Corrected the Metal clip-space transform for `g_ModelViewProjectionMatrix` so OpenGL-authored scene geometry is not clipped away on Apple.
- Implemented Metal particle rendering for custom indexed geometry instead of short-circuiting the Apple path.
- Replaced sparse black-frame sampling with a full-buffer scan in screenshot analysis so particle-heavy scenes are classified from the actual captured pixels.

Functionality and impact:
- `deep_space` now renders visible output instead of a fully black capture; focused verification reported `black_frame: false` with `black_pixels: 0`.
- `shimmering_particles` now renders visible particle output on Metal; focused verification reported `black_frame: false` after the renderer fix and screenshot-classifier correction.
- Full suite verification now passes for the current local corpus:
  - `deep_space`: `pass`
  - `neon_sunset`: `pass`
  - `shimmering_particles`: `pass`
- Verified report: `CompatibilitySuite/reports/run_2026-04-03T14-20-33Z.json`
- Residual note: particle scheme colors still need follow-up validation because the current Metal path is rendering with neutralized color inputs for this fixture, but this no longer blocks extraction readiness for the black-frame gate.

### Phase 2 Native Scene Model Extraction

Changes:
- Added [`docs/UPSTREAM_MODEL_MAP.md`](./UPSTREAM_MODEL_MAP.md) to map the upstream `Data/Model/` ownership tree, runtime mutation points, and hot/cold fields.
- Added [`docs/PARSE_FLOW.md`](./PARSE_FLOW.md) to trace `project.json` through `ProjectParser`, `WallpaperParser`, `ObjectParser`, and the lower-level material/effect/user-setting parsers.
- Added a pure Swift `NativeSceneCore` target with [`SceneModel.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneCore/SceneModel.swift) defining the normalized native scene types.
- Added a `NativeSceneBridge` target with [`SceneDescriptionAdapter.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneBridge/SceneDescriptionAdapter.swift) so Swift can construct `SceneDescription` instances from the upstream C++ parsers without polluting `NativeSceneCore` with C dependencies.
- Extended [`WEBridge.h`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/CWEBridge/include/WEBridge.h) and [`WEBridge.cpp`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/CWEBridge/WEBridge.cpp) with a non-rendering `we_copy_scene_description_json` export that serializes parsed scene data into a normalized JSON payload.
- Routed scene-wallpaper metadata loading through the native model in [`WallpaperProject.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/WallpaperEngine/WallpaperProject.swift), [`WallpaperProperty.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/WallpaperEngine/WallpaperProperty.swift), and [`DesktopWindowManager.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/WallpaperEngine/DesktopWindowManager.swift).
- Added [`WallpaperAssets.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/WallpaperEngine/WallpaperAssets.swift) so the bridge adapter and scene renderer resolve the same shared-assets root.
- Fixed upstream parser gaps uncovered by extraction work:
  - `WallpaperParser::parseScene()` now preserves the scene file path in `Wallpaper.filename`.
  - property parsing now preserves `order` and slider `precision`.
  - text-input properties now preserve their raw string value instead of JSON-encoded quoted text.

Functionality and impact:
- Swift now has a native, compile-time scene model that is independent of upstream ownership and class hierarchies.
- Scene metadata reads on the Swift side can source from `SceneDescription` instead of ad hoc direct JSON decoding.
- The adapter boundary is explicit: current rendering still flows through the C++ engine, but model extraction is no longer blocked on C++ object ownership.
- Verification:
  - `./build-bridge.sh` rebuilt `build/lib/libwallpaperengine.a` with the new scene-export symbols.
  - `swift build` succeeds with `NativeSceneCore`, `NativeSceneBridge`, and the updated app target.
- Runtime follow-up:
  - A first full-suite run in a real macOS session exposed a Phase 2 adapter bug: non-combo `UserProperty` values omitted `options`, which caused native-model decoding to fail for `shimmering_particles`.
  - Fixed by making [`UserProperty`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneCore/SceneModel.swift) decode `options` as an empty array when absent.
  - Re-ran the isolated `shimmering_particles` fixture; it passed and logged `Native scene model loaded: nodes=5, properties=6, resolution=5760x1080`.
  - Re-ran the full compatibility suite in a real macOS session; all current fixtures passed:
    - `deep_space`: `pass`
    - `neon_sunset`: `pass`
    - `shimmering_particles`: `pass`
  - Verified report: `CompatibilitySuite/reports/run_2026-04-03T15-08-03Z.json`

### Development Procedure: Real Scene Canary Set

Changes:
- Added [`CompatibilitySuite/generate_local_scene_canaries.py`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/generate_local_scene_canaries.py) to reproducibly sample 20 local Steam workshop `scene` wallpapers using seed `431960`.
- Added [`CompatibilitySuite/local_scene_canaries.json`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/local_scene_canaries.json) as the machine-readable real-scene canary catalog rooted at `/Users/isaiahbergstrom/Library/Application Support/Steam/steamapps/workshop/content/431960`.
- Added [`docs/DEVELOPMENT_PROCEDURE.md`](./DEVELOPMENT_PROCEDURE.md) to define the required local test order: fast fixtures first, then the 20-wallpaper real-scene canary set for shared scene-system changes.
- Updated [`docs/CI_PLAN.md`](./CI_PLAN.md) so the local promotion path explicitly includes the new real-scene canary gate.

Functionality and impact:
- Development is now anchored to both the synthetic fixture set and a reproducible sample of real local workshop scenes.
- The current canary selection reflects actual local workshop packaging behavior: all 20 sampled scenes are package-backed (`scene.pkg` present, no loose root `scene.json`), which is useful coverage for parser and asset-locator changes.
- Future compatibility work can be evaluated against exact, repeatable local workshop IDs instead of ad hoc manual picks.

### Phase 2 Canary Runtime Remediation

Changes:
- Normalized scene project loading so mixed-case workshop `project.json.type` values decode correctly and renderer selection uses the normalized `resolvedType` path.
- Hardened upstream parsing for real workshop content:
  - accepted `usershortcut` properties,
  - treated non-vector string user-setting values as plain strings instead of invalid vectors,
  - added relaxed JSON parsing for trailing commas across project, scene, material, effect, model, particle, and bridge-export inputs,
  - ignored non-JSON shader prose comments during metadata extraction, while still repairing malformed bare-key combo JSON.
- Prevented native runtime crashes from malformed particle definitions by skipping particle objects whose material failed to load instead of constructing `CParticle` with a null material.
- Replaced the Apple video-texture no-op path with an AVFoundation-to-Metal upload path so scene materials backed by video textures render visible content on macOS.
- Refined screenshot black-frame classification so overwhelmingly dark scenes with a meaningful visible highlight area are no longer misclassified as blank captures.

Functionality and impact:
- The previously failing real-scene canaries were resolved by root cause instead of being deferred:
  - `2021551537` (`Tenkinoko 天気の子`) no longer crashes; crash reports showed an `EXC_BAD_ACCESS` in `CParticle::CParticle(...)`, which is now avoided by skipping invalid particle systems.
  - `3368256253` (`Shimmering Pond | きらめく池`) now renders through the Metal path instead of logging `video textures not yet supported on Metal path`.
  - `1672387064` and `3035352006` were confirmed to be visibly rendered dark scenes rather than blank frames; the classifier now reflects that distinction.
- Focused verification milestones:
  - Structural/parser blocker cleared: `CompatibilitySuite/reports/run_2026-04-03T21-17-54Z.json`
  - Crash + video-texture fixes validated: `CompatibilitySuite/reports/run_2026-04-03T21-29-16Z.json`
  - Dark-scene classifier validation: `CompatibilitySuite/reports/run_2026-04-03T21-31-08Z.json`
- Final acceptance result:
  - Full Tier 2 20-scene local canary suite passed with no `crash`, `fail`, or `partial` statuses.
  - Verified report: `CompatibilitySuite/reports/run_2026-04-03T21-31-34Z.json`

### Phase 3 Replace Shader Pipeline

Changes:
- Added [`docs/SHADER_PIPELINE.md`](./SHADER_PIPELINE.md) to document the owned shader flow: asset lookup, `#include`/`#require`, combo discovery, GLSL assembly, GLSL -> SPIR-V -> MSL compilation, reflected slot extraction, and the fork-specific sanitizer passes now carried in repo code.
- Added a new `CShaderCompiler` target in [`Package.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Package.swift) with [`ShaderCompilerBridge.h`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/CShaderCompiler/include/ShaderCompilerBridge.h) and [`ShaderCompilerBridge.cpp`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/CShaderCompiler/ShaderCompilerBridge.cpp), exposing a standalone C API for compiling a vertex/fragment GLSL pair into MSL plus reflected slot metadata.
- Added the `NativeSceneCompatibility` target in [`Package.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Package.swift) and implemented the owned shader pipeline in:
  - [`ShaderTypes.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneCompatibility/Shaders/ShaderTypes.swift)
  - [`ShaderAssetResolver.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneCompatibility/Shaders/ShaderAssetResolver.swift)
  - [`ShaderMetadata.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneCompatibility/Shaders/ShaderMetadata.swift)
  - [`ComboResolver.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneCompatibility/Shaders/ComboResolver.swift)
  - [`ShaderPreprocessor.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneCompatibility/Shaders/ShaderPreprocessor.swift)
  - [`MetalShaderCompiler.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneCompatibility/Shaders/MetalShaderCompiler.swift)
  - [`ShaderPipeline.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneCompatibility/Shaders/ShaderPipeline.swift)
- Added [`ShaderFixtureTool`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/ShaderFixtureTool/main.swift) so fixture inputs can be compiled into stable JSON snapshots without depending on the app runtime.
- Added repo-owned shader fixtures under [`CompatibilitySuite/shader_fixtures/`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/shader_fixtures):
  - `basic_include_require_combo`
  - `fragment_mutates_varying`
  - `workshop_compat_rewrite`
- Added [`CompatibilitySuite/run_shader_fixtures.py`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/run_shader_fixtures.py) as the Phase 3 acceptance runner that compiles every fixture through `ShaderFixtureTool` and checks it against `expected.json`.
- Fixed a Phase 3 resolver regression found during the first fixture snapshot run: relative shader IDs were being converted into absolute filesystem paths when extensions were rewritten. `ShaderAssetResolver` now rewrites extensions with path-string operations so `effects/basic` stays an asset-relative key.

Functionality and impact:
- Shader preprocessing and GLSL assembly are now owned in Swift instead of staying embedded in the upstream `ShaderUnit` code path.
- The only remaining native dependency in the shader pipeline is the compiler shim that wraps vendored glslang and SPIRV-Cross; it no longer depends on upstream scene/runtime objects.
- Phase 3 compatibility coverage is now locked to repo-owned fixtures for the key fork behaviors:
  - `#include` and `#require` expansion
  - malformed combo metadata repair
  - fragment varying mutation repair
  - workshop `zcompat` shader-path rewrite
- Verification:
  - `swift build`
  - `python3 CompatibilitySuite/run_shader_fixtures.py`
- Acceptance result:
  - build succeeded with the new `CShaderCompiler`, `NativeSceneCompatibility`, and `ShaderFixtureTool` targets
  - shader fixture runner passed: `verified 3 shader fixtures`

### Phase 4 Replace Runtime Evaluation

Changes:
- Added [`docs/RUNTIME_UPDATE_FLOW.md`](./RUNTIME_UPDATE_FLOW.md) to map the actual upstream frame flow across `WallpaperApplication::render()`, `WallpaperApplication::update(viewport)`, `RenderContext::render(viewport)`, and `CScene::renderFrame(viewport)`, including time, pause, input, audio, parallax, light-state, and object-render ordering.
- Added a new `NativeSceneRuntime` target in [`Package.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Package.swift) with the Phase 4 runtime surface:
  - [`FramePacket.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneRuntime/FramePacket.swift)
  - [`PropertyEvaluator.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneRuntime/PropertyEvaluator.swift)
  - [`AnimationEvaluator.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneRuntime/AnimationEvaluator.swift)
  - [`TransformEvaluator.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneRuntime/TransformEvaluator.swift)
  - [`SceneRuntime.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneRuntime/SceneRuntime.swift)
- The runtime now owns:
  - a flat `FramePacket` schema with stable node/material/light/particle sections
  - runtime-measurable packet sizing through `estimatedByteSize` and JSON encoding
  - parent-first transform hierarchy evaluation
  - user property override resolution
  - limited scripted dynamic-value fallback for common arithmetic/property passthrough cases
  - basic animation-layer phase tracking for image animation layers
  - a top-level `SceneRuntime.step(deltaTime:)` that advances time and emits a renderer-facing packet without calling `WallpaperApplication::update()`
- Added [`SceneRuntimeBenchmarkTool`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/SceneRuntimeBenchmarkTool/main.swift) so the new runtime packet cost can be measured independently of the app UI loop.
- Added [`docs/RUNTIME_BRIDGE_BENCHMARK.md`](./RUNTIME_BRIDGE_BENCHMARK.md) to record the benchmark numbers and the phase-boundary decision.

Functionality and impact:
- The repo now has an owned mutable runtime layer instead of only an immutable scene model plus the upstream renderer/runtime.
- Scene state can be stepped in Swift and exported as a flat packet that is explicitly measurable at the runtime/renderer boundary.
- The benchmark gate for the Phase 4 -> Phase 5 split is now data-backed on the sample fixture corpus:
  - `deep_space`: current engine `0.314 ms` avg vs packet+encode `0.113 ms`
  - `neon_sunset`: current engine `0.781 ms` avg vs packet+encode `0.207 ms`
  - `shimmering_particles`: current engine `0.588 ms` avg vs packet+encode `0.233 ms`
- Decision:
  - keep Phases 4 and 5 separate for now
  - re-run the benchmark method on a representative local canary subset before expanding mixed-mode runtime usage further
- Scope note:
  - this phase does not replace the full JS host; `NativeSceneRuntime` currently resolves static/property-bound values and a limited scripted arithmetic subset, while full script-host compatibility remains a Phase 6 task
  - animation support currently covers packetized layer timing/visibility rather than full upstream authored curve parity, because those curve definitions are not yet part of the extracted scene model

Verification:
- `swift build`
- `./.build/debug/SceneRuntimeBenchmarkTool /Users/isaiahbergstrom/wallpaper_engine/test_wallpapers/deep_space /Users/isaiahbergstrom/wallpaper_engine/assets --frames 300`
- `./.build/debug/SceneRuntimeBenchmarkTool /Users/isaiahbergstrom/wallpaper_engine/test_wallpapers/neon_sunset /Users/isaiahbergstrom/wallpaper_engine/assets --frames 300`
- `./.build/debug/SceneRuntimeBenchmarkTool /Users/isaiahbergstrom/wallpaper_engine/test_wallpapers/shimmering_particles /Users/isaiahbergstrom/wallpaper_engine/assets --frames 300`

### Phase 5 Replace Renderer Passes

Changes:
- Added [`docs/RENDER_PASS_MAP.md`](./RENDER_PASS_MAP.md) to map the upstream render responsibilities onto the owned Phase 5 renderer modules and to record the deliberate mixed-mode scope boundary.
- Added the new `NativeSceneRenderer` target in [`Package.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Package.swift) and implemented the first owned renderer surface in:
  - [`NativeSceneRenderer.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneRenderer/NativeSceneRenderer.swift)
  - [`PassGraph.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneRenderer/PassGraph.swift)
  - [`MaterialBinder.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneRenderer/MaterialBinder.swift)
  - [`ImageRenderer.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneRenderer/ImageRenderer.swift)
  - [`ParticleRenderer.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneRenderer/ParticleRenderer.swift)
  - [`LightingPass.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneRenderer/LightingPass.swift)
  - [`PostProcessPass.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneRenderer/PostProcessPass.swift)
- Added [`SceneNativeSnapshotTool`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/SceneNativeSnapshotTool/main.swift) so the owned renderer can be exercised offscreen without going through the app window stack.
- Integrated the native path into [`SceneRenderer.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/WallpaperEngine/SceneRenderer.swift) behind the `WE_USE_NATIVE_SCENE_RENDERER=1` feature flag:
  - `SceneRenderer` now accepts the already-loaded native scene description from [`DesktopWindowManager.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/WallpaperEngine/DesktopWindowManager.swift)
  - native scene selection is gated by `NativeSceneRenderer.support(scene:)`
  - unsupported scenes or native init failures fall back to the existing bridge path
  - the shared `SceneMetalView` presentation path now handles either bridge textures or native-rendered offscreen textures
  - initial property application is now stored and replayed when the renderer backend is actually created, instead of being dropped before `play()`
- Added native runtime plumbing in `SceneRenderer` for:
  - property override translation from `WallpaperProperty` values into `FrameValue`
  - summarized audio forwarding into `AudioInputState`
  - screenshot/benchmark automation reuse through the same `TextureSnapshot` path already used by the bridge renderer

Functionality and impact:
- The repo now has an owned Metal render path for the first supported scene subset instead of being fully dependent on upstream `CScene`/`CImage` rendering.
- The current owned subset is intentionally image/material focused:
  - image nodes with flat geometry
  - material pass binding through the owned shader pipeline
  - runtime packet consumption from `NativeSceneRuntime`
- Particle nodes, RTT/effect graphs, and full post-processing remain outside the native subset and continue to route through the bridge path.
- This phase establishes the mixed-mode migration shape the roadmap called for:
  - same app entrypoint
  - explicit feature flag
  - deterministic fallback

Verification:
- `swift build`
- `./.build/debug/SceneNativeSnapshotTool /Users/isaiahbergstrom/wallpaper_engine/test_wallpapers/deep_space /Users/isaiahbergstrom/wallpaper_engine/assets /tmp/deep_space_native.png --frames 2`
- `WE_USE_NATIVE_SCENE_RENDERER=1 ./.build/debug/WallpaperEngine /Users/isaiahbergstrom/wallpaper_engine/test_wallpapers/deep_space --screenshot /tmp/phase5-native-app.png --frames 60`

Acceptance result:
- build succeeded with the new `NativeSceneRenderer` and `SceneNativeSnapshotTool` targets
- offscreen native snapshot completed successfully on the `deep_space` sample scene
- end-to-end app automation succeeded on the feature-flagged native path for `deep_space`
- screenshot report `/tmp/phase5-native-app.png.json` recorded `black_frame: false`

Scope note:
- Phase 5 is complete for the first native render slice, not for full scene parity.
- The native path is intentionally restricted to scenes accepted by `NativeSceneRenderer.support(scene:)`; everything else still falls back to the bridge until later phases replace particles, effects, and broader geometry support.

### Phase 6 Replace Script Host

Changes:
- Added [`docs/SCRIPT_HOST_BINDINGS.md`](./SCRIPT_HOST_BINDINGS.md) to document the actual upstream `ScriptEngine.cpp` binding surface, including the per-evaluation globals, fluent builder methods, `update(value)` entrypoint, and the explicit gap between scripted dynamic values and scene-level callback scripts.
- Added a new `CScriptHost` target in [`Package.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Package.swift) with:
  - [`ScriptHostBridge.h`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/CScriptHost/include/ScriptHostBridge.h)
  - [`ScriptHostBridge.c`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/CScriptHost/ScriptHostBridge.c)
- The new bridge links directly against the vendored QuickJS library already built in `build/quickjs`, lazily owns a shared runtime/context, recreates the upstream wrapper shape (`createScriptProperties()` plus `update(value)`), and returns either a JSON-serialized JS result or a traceable QuickJS exception string.
- Added [`ScriptHost.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneRuntime/ScriptHost.swift) in `NativeSceneRuntime` as the Swift-facing host wrapper:
  - marshals `FrameValue` and script property dictionaries into the same scalar/vector JS shapes used upstream
  - converts JS results back into `FrameValue` using the base value as the type hint
  - surfaces evaluation errors to the runtime instead of failing opaquely
- Replaced the heuristic string-based script evaluator in [`PropertyEvaluator.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneRuntime/PropertyEvaluator.swift) with the owned QuickJS-backed host, while preserving base-value fallback on script errors.
- Added a repo-owned fixture harness for the new host:
  - [`ScriptHostFixtureTool`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/ScriptHostFixtureTool/main.swift)
  - [`CompatibilitySuite/script_host_fixtures/`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/script_host_fixtures)
  - [`CompatibilitySuite/run_script_host_fixtures.py`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/run_script_host_fixtures.py)
- Added [`CompatibilitySuite/generate_script_compatibility.py`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/generate_script_compatibility.py), which scans the current sample wallpaper corpus for embedded scripts and writes the Phase 6 compatibility matrix report to [`CompatibilitySuite/reports/script_compatibility.json`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/reports/script_compatibility.json).

Functionality and impact:
- The runtime no longer relies on the previous ad hoc “first return expression” parser for scripted dynamic values.
- Scripted dynamic values now execute through a real QuickJS host that matches the current upstream host model:
  - `createScriptProperties()`
  - builder default registration
  - `update(value)` return-value semantics
- Evaluation failures now include the actual QuickJS exception text in the runtime log, which makes missing APIs and malformed scripts diagnosable.
- The script compatibility matrix makes the current limitation explicit on the sample corpus:
  - the one observed sample script (`shimmering_particles`) uses `applyUserProperties` and `thisObject`
  - those are scene-level callback APIs, not scripted dynamic-value bindings
  - they remain unsupported because the extracted model does not yet carry top-level scene script callbacks

Verification:
- `swift build`
- `python3 CompatibilitySuite/run_script_host_fixtures.py`
- `python3 CompatibilitySuite/generate_script_compatibility.py`

Acceptance result:
- build succeeded with the new `CScriptHost` and `ScriptHostFixtureTool` targets
- script host fixture runner passed: `verified 3 script host fixtures`
- compatibility matrix generated at [`CompatibilitySuite/reports/script_compatibility.json`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/reports/script_compatibility.json)

Scope note:
- Phase 6 is complete for the upstream host that exists today in `ScriptEngine.cpp`, which is a scripted-dynamic-value host centered on `update(value)`.
- Full scene callback support (`applyUserProperties`, `init`, `destroy`, `thisObject`, `engine.*`, `input.*`) is still deferred because it requires exporting scene-level script definitions and imperative mutation targets into the native model/runtime.

### Post-Phase-6 Verification Audit

Changes:
- Ran the full current verification stack:
  - `swift build`
  - `python3 CompatibilitySuite/run_shader_fixtures.py`
  - `python3 CompatibilitySuite/run_script_host_fixtures.py`
  - `python3 CompatibilitySuite/run_suite.py --fixtures CompatibilitySuite/fixtures.json`
  - `python3 CompatibilitySuite/run_suite.py --fixtures CompatibilitySuite/local_scene_canaries.json`
  - `WE_USE_NATIVE_SCENE_RENDERER=1 ./.build/debug/WallpaperEngine /Users/isaiahbergstrom/wallpaper_engine/test_wallpapers/deep_space --screenshot /tmp/phase6-native-smoke.png --frames 60`
- Added [`docs/NEXT_PHASE_AUDIT.md`](./NEXT_PHASE_AUDIT.md) to record:
  - what is actually validated
  - what migration scope remains intentionally incomplete
  - what should be fixed before Phase 7 text work
- Fixed a harness defect found during the audit:
  - [`CompatibilitySuite/run_suite.py`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/run_suite.py) now appends a random suffix to `run_id`
  - this prevents concurrent suite runs from writing into the same report directory/summary file

Audit result:
- Fast verification stack passed.
- Sample runtime suite passed.
- Native-path smoke passed on `deep_space` with `black_frame: false`.
- Full canary suite exposed a flaky teardown/runtime issue on canary `3035352006`:
  - one clean full-suite rerun produced exit code `-11` after screenshot/benchmark output
  - isolated rerun of the same canary then passed
- This is tracked in the audit document as a fix-before-next-phase item rather than silently treating the suite as fully green.

### Pre-Phase-7 Readiness Hardening

Changes:
- Hardened shutdown and automation stability in:
  - [`AppDelegate.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/WallpaperEngine/AppDelegate.swift)
  - [`DesktopWindowManager.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/WallpaperEngine/DesktopWindowManager.swift)
- The shutdown path is now idempotent across both `applicationWillTerminate` and manual automation exit.
- `DesktopWindowManager` now nils out the active renderer before stopping it during wallpaper replacement/clear/teardown, which avoids shutdown-time reuse of a renderer that is already being dismantled.
- Automation runs no longer subscribe to screen-parameter or sleep/wake notifications, which prevents long suite runs from pausing the renderer or rebuilding windows mid-run.
- Extended [`CompatibilitySuite/run_suite.py`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/run_suite.py) with:
  - `--backend bridge|native`
  - `requested_backend` and `observed_backend` in per-fixture reports
  - native-requested execution via `WE_USE_NATIVE_SCENE_RENDERER=1`
- Added [`CompatibilitySuite/text_scene_canaries.json`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/text_scene_canaries.json) to keep two real text-bearing workshop scenes in the acceptance loop before Phase 7:
  - `2232968607`
  - `3368256253`
- Updated:
  - [`docs/NEXT_PHASE_AUDIT.md`](./NEXT_PHASE_AUDIT.md)
  - [`docs/DEVELOPMENT_PROCEDURE.md`](./DEVELOPMENT_PROCEDURE.md)
  - [`docs/CI_PLAN.md`](./CI_PLAN.md)

Verification:
- `swift build`
- `python3 CompatibilitySuite/run_suite.py --fixtures CompatibilitySuite/local_scene_canaries.json --fixture 3035352006`
- `python3 CompatibilitySuite/run_suite.py --fixtures CompatibilitySuite/local_scene_canaries.json --fixture 3035352006`
- `python3 CompatibilitySuite/run_suite.py --fixtures CompatibilitySuite/text_scene_canaries.json`
- `python3 CompatibilitySuite/run_suite.py --fixtures CompatibilitySuite/fixtures.json --backend native`
- `python3 CompatibilitySuite/run_suite.py --fixtures CompatibilitySuite/local_scene_canaries.json`
- `python3 CompatibilitySuite/run_suite.py --fixtures CompatibilitySuite/local_scene_canaries.json --backend native`
- `python3 CompatibilitySuite/run_shader_fixtures.py`
- `python3 CompatibilitySuite/run_script_host_fixtures.py`
- `python3 CompatibilitySuite/generate_script_compatibility.py`
- `python3 CompatibilitySuite/run_suite.py --fixtures CompatibilitySuite/fixtures.json`
- `python3 CompatibilitySuite/run_suite.py --fixtures CompatibilitySuite/fixtures.json --backend native`

Acceptance result:
- `3035352006` now passes repeated isolated reruns instead of intermittently exiting `-11`.
- Full 20-wallpaper bridge canary lane passed:
  - [`run_2026-04-03T23-20-01-441720Z_79e2c34a.json`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/reports/run_2026-04-03T23-20-01-441720Z_79e2c34a.json)
- Full 20-wallpaper native-requested canary lane passed:
  - [`run_2026-04-03T23-29-24-568733Z_07b62c60.json`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/reports/run_2026-04-03T23-29-24-568733Z_07b62c60.json)
- Text-bearing canary lane passed:
  - [`run_2026-04-03T23-18-57-553788Z_eb450b3b.json`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/reports/run_2026-04-03T23-18-57-553788Z_eb450b3b.json)
- Sample bridge lane passed:
  - [`run_2026-04-03T23-32-44-498421Z_f04710c5.json`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/reports/run_2026-04-03T23-32-44-498421Z_f04710c5.json)
- Sample native-requested lane passed:
  - [`run_2026-04-03T23-33-14-891946Z_0ad680b3.json`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/reports/run_2026-04-03T23-33-14-891946Z_0ad680b3.json)

Readiness note:
- The repo is now signed off as Phase-7-ready without starting Phase 7 itself.
- Remaining gaps are feature scope items for Phase 7 and later, not unresolved pre-phase blockers.

### Phase 7: Replace Text

Changes:
- Added real-schema text object documentation in [`TEXT_OBJECT_FORMAT.md`](./TEXT_OBJECT_FORMAT.md), based on workshop scenes `2232968607` and `3098403977`.
- Extended the upstream parser/model/export path to carry text objects through the bridge:
  - [`linux-wallpaperengine/src/WallpaperEngine/Data/Model/Types.h`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/linux-wallpaperengine/src/WallpaperEngine/Data/Model/Types.h)
  - [`linux-wallpaperengine/src/WallpaperEngine/Data/Model/Object.h`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/linux-wallpaperengine/src/WallpaperEngine/Data/Model/Object.h)
  - [`linux-wallpaperengine/src/WallpaperEngine/Data/Parsers/ObjectParser.h`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/linux-wallpaperengine/src/WallpaperEngine/Data/Parsers/ObjectParser.h)
  - [`linux-wallpaperengine/src/WallpaperEngine/Data/Parsers/ObjectParser.cpp`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/linux-wallpaperengine/src/WallpaperEngine/Data/Parsers/ObjectParser.cpp)
  - [`Sources/CWEBridge/WEBridge.cpp`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/CWEBridge/WEBridge.cpp)
- Added structured native decoding for text descriptors in:
  - [`Sources/NativeSceneCore/TextParser.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneCore/TextParser.swift)
  - [`Sources/NativeSceneCore/SceneModel.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneCore/SceneModel.swift)
- Added runtime-owned text packets in:
  - [`Sources/NativeSceneRuntime/FramePacket.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneRuntime/SceneRuntime.swift)
  - [`Sources/NativeSceneRuntime/SceneRuntime.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneRuntime/SceneRuntime.swift)
  - [`Sources/NativeSceneRuntime/TransformEvaluator.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneRuntime/TransformEvaluator.swift)
- Implemented native text rasterization in [`Sources/NativeSceneRenderer/TextRenderer.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneRenderer/TextRenderer.swift) using Core Text / Core Graphics, and wired the renderer into [`Sources/NativeSceneRenderer/NativeSceneRenderer.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneRenderer/NativeSceneRenderer.swift).
- Fixed two Phase-7-specific compatibility defects during runtime validation:
  - typed-null scripted text values now decode without aborting native scene loading
  - text backgrounds authored as RGB now normalize to implicit alpha `0` instead of incorrectly forcing opaque backgrounds
- Reworked the native text placement path to build screen-space text quads directly from scene-space coordinates, which resolved the previous skewed/clipped glyph rendering bug.
- Added a deterministic native text fixture catalog in:
  - [`CompatibilitySuite/text_fixtures.json`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/text_fixtures.json)
  - [`CompatibilitySuite/text_fixtures/text_clock_native/project.json`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/text_fixtures/text_clock_native/project.json)
  - [`CompatibilitySuite/text_fixtures/text_clock_native/scene.json`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/text_fixtures/text_clock_native/scene.json)
- Expanded the real workshop text canary catalog in [`CompatibilitySuite/text_scene_canaries.json`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/text_scene_canaries.json) to include the text-heavy HUD scene `3098403977`.
- Added [`PHASE7_TEXT_STATUS.md`](./PHASE7_TEXT_STATUS.md) to separate completed text-subsystem work from the remaining broader native image/material boundary.

Verification:
- `./build-bridge.sh`
- `swift build`
- `python3 CompatibilitySuite/run_suite.py --fixtures CompatibilitySuite/text_fixtures.json --backend native`
- `python3 CompatibilitySuite/run_suite.py --fixtures CompatibilitySuite/text_scene_canaries.json --backend bridge`
- `python3 CompatibilitySuite/run_suite.py --fixtures CompatibilitySuite/text_scene_canaries.json --backend native`
- `./.build/debug/SceneRuntimeBenchmarkTool '/Users/isaiahbergstrom/Library/Application Support/Steam/steamapps/workshop/content/431960/2232968607' '/Users/isaiahbergstrom/wallpaper_engine/assets' --frames 1`

Acceptance result:
- Deterministic native text fixture passed and renders visible text:
  - [`run_2026-04-04T00-33-20-761742Z_a29d1c7d.json`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/reports/run_2026-04-04T00-33-20-761742Z_a29d1c7d.json)
- Real workshop text canaries pass on the bridge lane:
  - [`run_2026-04-04T00-21-38-632883Z_3f2843c1.json`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/reports/run_2026-04-04T00-21-38-632883Z_3f2843c1.json)
- Real workshop text canaries on the native-requested lane now resolve as:
  - `2232968607`: `observed=native`
  - `3098403977`: `observed=native`
  - `3368256253`: `observed=bridge` because particles still keep it outside the native subset
  - Report: [`run_2026-04-04T00-34-20-269184Z_8879bd3d.json`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/reports/run_2026-04-04T00-34-20-269184Z_8879bd3d.json)

Scope note:
- Phase 7 is complete for native text parsing, dynamic-value/script evaluation, and visible text rendering.
- Bridge-parity backgrounds/effects in complex real wallpapers still depend on the broader native image/material coverage boundary from Phase 5, not on missing text support.

### Phase 8: Retire Upstream Runtime

Changes:
- Removed the app target's direct bridge/runtime dependency in [`Package.swift`](./Package.swift):
  - `WallpaperEngine` no longer depends on `CWEBridge`
  - `SceneDescriptionExportTool` now owns the remaining `CWEBridge` linkage
- Reworked [`Sources/NativeSceneBridge/SceneDescriptionAdapter.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneBridge/SceneDescriptionAdapter.swift) to launch a helper process for scene export instead of calling `we_copy_scene_description_json(...)` directly from the app.
- Added [`Sources/SceneDescriptionExportTool/main.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/SceneDescriptionExportTool/main.swift) as the temporary helper boundary around the remaining upstream scene-export oracle.
- Removed all direct upstream runtime/render calls from [`Sources/WallpaperEngine/SceneRenderer.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/WallpaperEngine/SceneRenderer.swift), leaving only the owned native playback path.
- Fixed a large-scene helper deadlock by changing the export-tool boundary from stdout transport to temp-file output.
- Fixed a shader preprocessor recursion crash in [`Sources/NativeSceneCompatibility/Shaders/ShaderPreprocessor.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneCompatibility/Shaders/ShaderPreprocessor.swift) by adding include/require cycle guards.
- Fixed native viewport sizing for auto-sized scenes in:
  - [`Sources/NativeSceneRenderer/ImageRenderer.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneRenderer/ImageRenderer.swift)
  - [`Sources/NativeSceneRenderer/MaterialBinder.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneRenderer/MaterialBinder.swift)
  - [`Sources/NativeSceneRenderer/NativeSceneRenderer.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneRenderer/NativeSceneRenderer.swift)
- Added a native billboard particle path in [`Sources/NativeSceneRenderer/ParticleRenderer.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneRenderer/ParticleRenderer.swift) to stop routing particle nodes through upstream particle shaders.
- Hardened automation startup failure handling in [`Sources/WallpaperEngine/SceneRenderer.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/WallpaperEngine/SceneRenderer.swift) so export/init failures surface immediately instead of waiting on an automation timeout.
- Added the formal Phase 8 docs:
  - [`PHASE8_DEPENDENCY_AUDIT.md`](./PHASE8_DEPENDENCY_AUDIT.md)
  - [`PHASE8_RUNTIME_STATUS.md`](./PHASE8_RUNTIME_STATUS.md)

Verification:
- `./build-bridge.sh`
- `swift build`
- `python3 CompatibilitySuite/run_shader_fixtures.py`
- `python3 CompatibilitySuite/run_script_host_fixtures.py`
- `python3 CompatibilitySuite/run_suite.py --fixtures CompatibilitySuite/fixtures.json --backend native`
- `python3 CompatibilitySuite/run_suite.py --fixtures CompatibilitySuite/text_scene_canaries.json --backend native`
- `python3 CompatibilitySuite/run_suite.py --fixtures CompatibilitySuite/local_scene_canaries.json --backend native`
- `python3 CompatibilitySuite/run_suite.py --fixtures CompatibilitySuite/local_scene_canaries.json --fixture 3153305636 --backend native`
- `python3 CompatibilitySuite/run_suite.py --fixtures CompatibilitySuite/local_scene_canaries.json --fixture 3613126158 --backend native`
- `python3 CompatibilitySuite/run_suite.py --fixtures CompatibilitySuite/local_scene_canaries.json --fixture 2147092453 --backend native`
- `python3 CompatibilitySuite/run_suite.py --fixtures CompatibilitySuite/local_scene_canaries.json --fixture 2232968607 --backend native`

Current status:
- Dependency-cut acceptance is met:
  - the app no longer links `libwallpaperengine.a`
  - the playback path no longer instantiates `WallpaperApplication`
- Runtime compatibility acceptance is not fully met yet:
  - sample native-only suite is `2/3` pass:
    - [`run_2026-04-04T09-11-57-904023Z_1230ebb3.json`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/reports/run_2026-04-04T09-11-57-904023Z_1230ebb3.json)
  - text native-only canary lane is `3/3` pass:
    - [`run_2026-04-04T09-15-53-824386Z_e74e0678.json`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/reports/run_2026-04-04T09-15-53-824386Z_e74e0678.json)
  - latest full local native-only canary lane is `16/20` pass with focused reruns showing two stable export crashes and two suite-level flaky crashes:
    - full suite: [`run_2026-04-04T09-24-02-399779Z_54b1e8b0.json`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/reports/run_2026-04-04T09-24-02-399779Z_54b1e8b0.json)
    - focused export failures:
      - [`run_2026-04-04T09-23-40-853022Z_1fc20b35.json`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/reports/run_2026-04-04T09-23-40-853022Z_1fc20b35.json)
      - [`run_2026-04-04T09-28-46-434587Z_aed83305.json`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/reports/run_2026-04-04T09-28-46-434587Z_aed83305.json)
    - focused flaky reruns that pass in isolation:
      - [`run_2026-04-04T09-29-07-191986Z_0b1d5115.json`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/reports/run_2026-04-04T09-29-07-191986Z_0b1d5115.json)
      - [`run_2026-04-04T09-29-07-259442Z_f951e9a7.json`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/reports/run_2026-04-04T09-29-07-259442Z_f951e9a7.json)

Open blockers:
- `shimmering_particles` still renders black on the native-only sample lane.
- The helper-based scene export still aborts on at least `3153305636` and `3613126158`.
- The long native-only local canary lane still shows suite-level instability beyond the focused export failures.

### Phase 8: Blocker Remediation And Acceptance

Changes:
- Fixed upstream conditional-setting export semantics in [`UserSettingParser.cpp`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/linux-wallpaperengine/src/WallpaperEngine/Data/Parsers/UserSettingParser.cpp):
  - direct `user: "property"` bindings still connect to the source property
  - conditional `user: { name, condition }` settings no longer overwrite their authored literal/scripted value during export
- Hardened scalar JSON parsing in [`JSON.h`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/linux-wallpaperengine/src/WallpaperEngine/Data/JSON.h) so parser reads can unwrap nested `value` payloads from real workshop user-setting objects.
- Promoted text `pointSize` to a user-setting-backed field through:
  - [`Object.h`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/linux-wallpaperengine/src/WallpaperEngine/Data/Model/Object.h)
  - [`ObjectParser.cpp`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/linux-wallpaperengine/src/WallpaperEngine/Data/Parsers/ObjectParser.cpp)
  - [`WEBridge.cpp`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/CWEBridge/WEBridge.cpp)
  - [`TextParser.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneCore/TextParser.swift)
  - [`SceneRuntime.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneRuntime/SceneRuntime.swift)
- Fixed native conditional-setting evaluation in [`PropertyEvaluator.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneRuntime/PropertyEvaluator.swift) so condition-bound settings use their own literal/scripted value and apply the condition as a gate instead of substituting the bound property value.
- Replaced the stale partial-acceptance note in [`PHASE8_RUNTIME_STATUS.md`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/docs/PHASE8_RUNTIME_STATUS.md) with the final green Phase 8 runtime audit.

Verification:
- `./build-bridge.sh`
- `swift package clean`
- `swift build`
- `python3 CompatibilitySuite/run_shader_fixtures.py`
- `python3 CompatibilitySuite/run_script_host_fixtures.py`
- `python3 CompatibilitySuite/run_suite.py --backend native --fixtures CompatibilitySuite/fixtures.json`
- `python3 CompatibilitySuite/run_suite.py --backend native --fixtures CompatibilitySuite/text_scene_canaries.json`
- `python3 CompatibilitySuite/run_suite.py --backend native --fixtures CompatibilitySuite/local_scene_canaries.json`
- focused blocker reruns:
  - `python3 CompatibilitySuite/run_suite.py --backend native --fixtures CompatibilitySuite/fixtures.json --fixture shimmering_particles`
  - `python3 CompatibilitySuite/run_suite.py --backend native --fixtures CompatibilitySuite/local_scene_canaries.json --fixture 3153305636`
  - `python3 CompatibilitySuite/run_suite.py --backend native --fixtures CompatibilitySuite/local_scene_canaries.json --fixture 3613126158`

Acceptance result:
- Sample native lane is now `3/3 pass`:
  - [`run_2026-04-04T09-52-26-350451Z_0a85a880.json`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/reports/run_2026-04-04T09-52-26-350451Z_0a85a880.json)
- Text native canary lane remains `3/3 pass` after the text point-size export/runtime change:
  - [`run_2026-04-04T09-55-25-551828Z_96bbb478.json`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/reports/run_2026-04-04T09-55-25-551828Z_96bbb478.json)
- Full 20-scene local native canary lane is now `20/20 pass`, including the two previously flaky full-suite cases:
  - [`run_2026-04-04T09-52-26-350480Z_23e3d82a.json`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/reports/run_2026-04-04T09-52-26-350480Z_23e3d82a.json)
- Focused blocker reruns are green:
  - `shimmering_particles`: [`run_2026-04-04T09-51-57-010788Z_bc3d94e1.json`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/reports/run_2026-04-04T09-51-57-010788Z_bc3d94e1.json)
  - `3153305636`: [`run_2026-04-04T09-51-57-010834Z_f5b27e6a.json`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/reports/run_2026-04-04T09-51-57-010834Z_f5b27e6a.json)
  - `3613126158`: [`run_2026-04-04T09-51-57-010819Z_4d870f0e.json`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/reports/run_2026-04-04T09-51-57-010819Z_4d870f0e.json)

Scope note:
- The helper export path still emits some upstream warning noise for unsupported scripts, `solid` placeholder objects, and system-texture references in a few real wallpapers.
- Those warnings no longer block export or native playback for the current acceptance corpus, so they are parity-cleanup work rather than Phase 8 blockers.

## 2026-07-15

### Rendering Correctness Overhaul (root-cause session)

Three long-standing bugs meant the native renderer had **never produced a correct frame**, while the harness reported green because it only checked for black frames:

1. **`device float3*` stride mismatch** in the inline MSL of `PostProcessPass.copyTexture` and `ParticleRenderer`. MSL strides `float3` by 16 bytes; the CPU buffers pack 12-byte triples, so the final scene blit drew a twisted two-triangle "bowtie" every frame. Fixed with `packed_float3`.
2. **`.tex` decoder never decoded anything**: every container-magic comparison tested `String(cString:)` output (NUL-stripped) against literals ending in `\0`, so it always failed and every packed workshop texture fell back to a 1×1 white pixel. Rewrote `WETexDecoder` against upstream `TextureParser.cpp`: LZ4 (raw block) decompression via the Compression framework, embedded PNG/JPEG payloads, raw RGBA8888/DXT1/DXT3/DXT5/RG88/R8 uploads (Metal BC formats), TEXB0004 mipmap header fields, and WE `g_TextureNResolution` semantics (storage size in xy, real image size in zw).
3. **`g_Texture3`/`g_Texture4` were hard-forced to the white fallback** in `MaterialBinder.resolveTexture`, whiting out any material that legitimately uses 4–5 texture slots (e.g. `flowimage`).

Harness hardening so this class of failure can't hide again:
- `ScreenshotReport` now records `flat_frame` (single-solid-color detector), luminance mean/stddev, and `animation_delta` (mean per-channel difference between captures 24 frames apart).
- `run_suite.py` fails fixtures on `flat_frame` and warns when `animation_delta` shows no motion.
- `NativeSceneRenderer`/`SceneNativeSnapshotTool` gained `WE_DEBUG_STAGES` (per-node and per-chain-step texture dumps) and `MaterialBinder` gained `WE_DEBUG_BIND` for attribute/uniform/candidate-path tracing.

Feature work in the same session (validated against the 20-canary corpus plus a full 424-scene feature inventory):
- Particles: `alpharandom`, `turbulentvelocityrandom`, `mapsequencearoundcontrolpoint` initializers; `controlpointattract`, `sizechange`, `alphachange`, `colorchange`, `turbulence`, `oscillatesize`, `vortex` operators (CPU curl-noise port); `spritetrail`/`rope`/`ropetrail` renderers (velocity-stretched quads and Catmull-Rom ribbons); child particle systems (`static`, `eventfollow`, `eventspawn`, `eventdeath`) with per-child materials; pointer-linked control points now convert to node-local space; particle parameter keys are matched case-insensitively (the old camelCase lookups silently disabled alphafade/oscillators).
- Puppet warp: full `MDLV0013–0023` decoder (`PuppetModel.swift`) — vertex layouts (52/44/40/80-byte strides), `MDLS` skeletons with bone-name/constraint strings, `MDLA` animations with mirror mode — validated against 333/346 corpus models, with CPU skinning and UV-fit mapping into the node quad in `ImageRenderer`.
- Sound nodes: `SceneSoundPlayer` (AVAudioPlayer) plays scene `sound` objects with loop/volume support, wired to mute/pause; created lazily so automation never decodes audio.
- Audio-reactive shaders: 128-band FFT spectrum now flows through `FramePacket.audio` into `g_AudioSpectrum{16,32,64}{Left,Right}` uniform arrays (std140 layout).
- Text: text nodes route through the standard effect-chain pipeline (blurprecise/scroll/godrays/etc.); empty transform-only scene objects classify as `group` nodes instead of `unknown`.
