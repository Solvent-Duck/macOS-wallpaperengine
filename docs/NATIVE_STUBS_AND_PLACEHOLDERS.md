# Native Stubs And Placeholders

Audit date: 2026-04-04

Purpose: record the current native-only runtime boundaries that are intentionally incomplete so the repo does not present partial-parity systems as finished.

## Interpretation Rules

- `stub` means the code path exists but does not implement the real Wallpaper Engine behavior.
- `placeholder` means the code path renders or evaluates an approximation that is useful for smoke coverage but is not parity work.
- `structural debt` means the runtime architecture is correct enough for the current build, but the dependency boundary is still not at the roadmap end state.

## Renderer

### Lighting

- Status: partial implementation
- Files:
  - [`LightingPass.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneRenderer/LightingPass.swift)
  - [`MaterialBinder.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneRenderer/MaterialBinder.swift#L225)
- Current behavior:
  - authored point/spot/tube/directional light data is packed from `FrameLight` into shader uniforms in `MaterialBinder`.
  - ambient/skylight, light arrays, camera eye position, and related shader-visible lighting values now come from the native scene/runtime state instead of fixed placeholders.
  - the dedicated `LightingPass` hook remains thin; there is still no separate shared light-buffer or shadow pass.
- Implication:
  - authored lighting can now affect native shaders, but this is not yet full light-pass/shadow parity.

### Post-processing / RTT / Effect Chains

- Status: partial implementation
- Files:
  - [`PostProcessPass.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneRenderer/PostProcessPass.swift)
  - [`NativeSceneRenderer.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneRenderer/NativeSceneRenderer.swift)
  - [`MaterialBinder.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneRenderer/MaterialBinder.swift)
- Current behavior:
  - native rendering now uses offscreen scene ping-pong textures so image materials and effect passes can sample `_rt_FullFrameBuffer` and other RTT outputs without read/write hazards.
  - image nodes execute local RTT/effect chains, including named FBO targets, `previous` binds, copy/swap commands, and final scene compositing.
  - camera bloom now runs as a real native post-process chain using quarter/eighth/bloom intermediate targets and a final combine pass.
  - material binding now accepts runtime texture overrides and populates `g_TextureNResolution` from the actual bound RTT textures.
  - missing workshop shader assets in effect chains are skipped with a runtime warning instead of aborting the frame.
- Implication:
  - common RTT-driven image effects and camera bloom now execute on the owned path, but this is not yet a full generalized frame-graph system and mesh/particle-heavy scenes still keep overall parity partial.

### Particles

- Status: partial implementation
- Files:
  - [`SceneRuntime.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneRuntime/SceneRuntime.swift#L267)
  - [`ParticleRenderer.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneRenderer/ParticleRenderer.swift#L38)
- Current behavior:
  - runtime now owns persistent sprite-particle simulation state per node and emits real particle instances into the frame packet.
  - native coverage includes the workshop subset exercised by the current canaries: `sprite` renderers, `boxrandom` / `sphererandom` emitters, `lifetimerandom` / `sizerandom` / `velocityrandom` / `colorrandom` / `rotationrandom` / `angularvelocityrandom` initializers, and `movement` / `angularmovement` / `alphafade` / `oscillateposition` / `oscillatealpha` operators.
  - renderer now draws per-particle sprite quads from the simulated instance list instead of a single estimate-sized placeholder quad.
  - particle support reporting is no longer unconditional; scenes only keep the `particles` placeholder when they use unsupported particle renderers, initializers, operators, control-point pointer links, or child systems.
- Implication:
  - the exercised native particle canaries are now on the real owned path, but rope/trail renderers, child systems, pointer-linked control points, spritesheet animation parity, and broader particle feature coverage are still open.

### Mesh / Model Geometry

- Status: placeholder detection only
- Files:
  - [`NativeSceneRenderer.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneRenderer/NativeSceneRenderer.swift#L90)
  - [`ImageRenderer.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneRenderer/ImageRenderer.swift)
- Current behavior:
  - support analysis flags `.mdl`/`.obj` usage.
  - native image rendering still produces quad geometry only.
- Implication:
  - model-backed scenes are currently rendered through the quad path unless future parity work replaces it.

### Text

- Status: partial implementation
- Files:
  - [`TextRenderer.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneRenderer/TextRenderer.swift)
  - [`TextParser.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneCore/TextParser.swift)
- Current behavior:
  - native text parsing and rasterization exist.
  - rendering now uses Core Text framesetter layout with multiline wrapping, row limiting, ellipsis truncation, and block/paragraph alignment.
  - texture cache entries are still keyed by resolved text state.
  - advanced text effects remain flagged as placeholders by support analysis.
- Implication:
  - text is no longer “unsupported”, but it is not full workshop-text parity.

## Runtime

### Script Host

- Status: partial implementation
- Files:
  - [`PropertyEvaluator.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneRuntime/PropertyEvaluator.swift#L153)
  - [`ScriptHost.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneRuntime/ScriptHost.swift)
  - [`SCRIPT_API_INVENTORY.md`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/docs/SCRIPT_API_INVENTORY.md)
- Current behavior:
  - the native path evaluates scripted dynamic values through the owned QuickJS host.
  - the standard scene callback/object host surface is still not implemented.
- Implication:
  - dynamic-value scripts work on the owned path; full SceneScript parity does not.

### Cursor / Parallax / Interactive Input

- Status: partial implementation
- Files:
  - [`SceneRenderer.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/WallpaperEngine/SceneRenderer.swift#L142)
  - [`NativeSceneRenderer.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneRenderer/NativeSceneRenderer.swift#L83)
- Current behavior:
  - normalized cursor updates now flow from the app into `NativeSceneRenderer` and `SceneRuntime`.
  - runtime parallax displacement is evaluated from camera parallax settings and node `parallaxDepth` values.
  - shader-facing pointer uniforms are populated from the current native cursor state.
  - click-driven interaction and broader scene-script interactive behavior are still not implemented.
- Implication:
  - cursor-driven parallax and pointer-aware shaders work on the owned path, but full interactive wallpaper parity is still pending.

## Scene Loading / Dependencies

### Scene Export Helper

- Status: structural debt
- Files:
  - [`SceneDescriptionAdapter.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneBridge/SceneDescriptionAdapter.swift)
  - [`SceneDescriptionExportTool/main.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/SceneDescriptionExportTool/main.swift)
  - [`Package.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Package.swift#L149)
- Current behavior:
  - the app runtime is native-only.
  - scene descriptions are now exported directly through `CWEBridge` from `NativeSceneBridge` instead of spawning the helper executable.
  - parser ownership is still upstream/C++ and still linked into the process.
- Implication:
  - the helper-process boundary is gone, but load-time parser ownership has not yet moved native.

### App Shutdown

- Status: structural debt
- Files:
  - [`AppDelegate.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/WallpaperEngine/AppDelegate.swift#L221)
- Current behavior:
  - app shutdown uses `_exit()` after manual teardown to avoid a C++ finalizer crash.
- Implication:
  - teardown is operationally stable for automation, but the finalizer path is not clean yet.

## Compatibility Harness

### Runtime Mode

- Status: cleaned up to native-only
- Files:
  - [`run_suite.py`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/run_suite.py)
- Current behavior:
  - the harness now reflects the native-only app runtime and records the renderer support report in each fixture result.
- Remaining limitation:
  - the harness still does not perform perceptual image comparison or enforce full feature expectations automatically.

### Coverage Scope

- Status: placeholder validation scope
- Files:
  - [`fixtures.json`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/fixtures.json)
  - [`text_scene_canaries.json`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/CompatibilitySuite/text_scene_canaries.json)
- Current behavior:
  - the shipped corpus is useful for smoke validation and local canaries.
- Implication:
  - it is not yet the 40-50 fixture parity corpus described by the roadmap.

## Maintenance Rule

When a stub or placeholder is removed, update:

1. the support analysis in [`NativeSceneRenderer.swift`](/Users/isaiahbergstrom/Projects/macOS-wallpaperengine/Sources/NativeSceneRenderer/NativeSceneRenderer.swift)
2. this document
3. any affected fixture expectations in `CompatibilitySuite`
