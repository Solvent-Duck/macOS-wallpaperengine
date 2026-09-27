# Windows parity progress

Updated: 2026-09-26 (America/Chicago)

## Target and measurement

The current target is reliable scene, video and web playback with comparable visual quality, correct interaction and wallpaper-authored controls. Deprecated application wallpapers, creation tools, elaborate library management, playlists, scheduling and cloud sync are outside scope. See [Playback Compatibility Matrix](PLAYBACK_COMPATIBILITY_MATRIX.md) for the current priorities and acceptance criteria; dated sections below retain historical implementation evidence. Work is ongoing; neither a nonblack screenshot nor `native_support.parityStatus == "complete"` proves Windows visual parity. That existing field reports only the feature gaps recognized by the current static analyzer, before shader compilation and rendering.

The user confirmed on September 26 that a Windows device is now available for reference captures. Connection, capture tooling, and matching corpus setup remain to be configured; see the [Windows handoff](WINDOWS_HANDOFF.md). Until those captures are collected and compared, visual Windows equivalence remains unverified. Earlier reports reflect the September 11 constraint that only the local macOS corpus was available.

The current test corpus has 421 scene projects, 45 video projects, and one web project, after the four exclusions recorded in [Development Procedure](DEVELOPMENT_PROCEDURE.md). Three published presets omit their type; their dependency loading is now partially supported. The historical 424-scene run on July 17 reported 395 passes, 23 failures, one timeout, and five partial results. A July 18 rerun of 24 failures reported 21 passes and three failures. These are smoke results, not a measured Windows-equivalence percentage.

## Coordinate and binding corrections

- Corrected scene Y coordinates across images, puppet quads, particles, and text. Scene positions increase upward; texture rows remain top-first. Corrected authored rotations to use radians. An asymmetric pixel fixture checks image position and orientation through zero, one, and two identity effects.
- Corrected fullscreen layer geometry, including the first pass of an effect chain. Fullscreen shaders receive clip-space vertices instead of a viewport-sized quad that samples only the center of its texture. Passthrough targets use the scene dimensions.
- Corrected the particle random generator's denominator: 24 extracted bits now map to the full `[0, 1)` interval instead of approximately `[0, 0.004)`. Added deterministic distribution and repeatability tests.
- Kept particles at Z=0 inside the orthographic clip volume and tested sprite position/orientation with a positive near plane.
- Corrected direct user-property bindings so current user values and project defaults override the saved setting snapshot. Runtime overrides retain priority; conditional settings retain their separate gating behavior. Added tests for these cases and missing properties.
- Removed the incorrect fallback from Wallpaper Engine texture indices to Metal reflection indices when selecting effect inputs. A pixel test verifies that `g_Texture1`, reflected as GPU slot 0, is not overwritten by the slot-0 effect input.
- Added Swift Testing targets for native runtime and pixel-level Metal regressions. Updated stale build and runtime descriptions in the README.

No changes were committed. The substantial uncommitted native-runtime migration present at task start was preserved.

## Property timelines and material state

Tracing Beyond (`3335365971`) established that both bokeh compositor chains retained the scene. The final two camera-shutter image layers covered it because the loader discarded their property timelines. A corpus scan found 1,172 such timelines across 147 scene projects.

- Added normalized, serializable timeline descriptors and loading of scalar/vector channels. Playback uses authored FPS and length, with single, loop, mirror, relative values, loop-seam interpolation, start-paused behavior, and the runtime's pause clock. Empty/malformed curves retain the base value; keys are sorted and duplicate frame entries are normalized.
- Added linear and cubic Bézier interpolation with independently enabled incoming/outgoing handles. The serialized handle scaling is provisional and still needs calibration against Windows curve captures; this is not a complete timeline-parity claim.
- Corrected material pipeline caching: compiled GPU state can be shared, but every draw now uses its own current constants and texture references. Previously another layer's values and the first frame's values were reused. This fix visibly removes the extreme displacement of Beyond's foreground character and permits shader-parameter timelines to advance.
- Resolved texture dimensions even when the shader uses only `g_TextureNResolution` and Metal removes the corresponding sampler.
- Added a prefix filter for debug stage captures (`WE_DEBUG_STAGE_FILTER`) to limit GPU readbacks when tracing a large effect chain.
- Added runtime tests for playback modes, relative channels, interpolation, loop seams, pause/resume, start-paused values, key normalization, and backward-compatible serialization. Added Metal pixel tests for animated image placement, shared material values across layers and frames, and optimized-out texture samplers.

Still missing from timeline playback: SceneScript animation controls, timeline events, synchronized parent/child animation controls, and Windows-reference validation of authored curve handles. In particular, a start-paused timeline cannot yet be started by the documented `IAnimation` API.

## Particle simulation

- Scalar emitter distances now expand across axes instead of being discarded. Omitted sphere directions use the XY plane, and omitted signs allow both sides of the origin. Explicit positive/negative sphere signs are respected. Distribution tests check annulus bounds, quadrants, and centering.
- Added boids with separate neighborhood/separation radii, cohesion, alignment, separation, optional speed limits, and lifetime blending. Each step reads a snapshot of neighboring particles; spatial buckets reduce unnecessary pair checks.
- Added swept quad and plane collisions with authored normal/forward orientation, control-point locking, bounce/slide/stop/delete responses, and optional rotation stopping. Swept intersections prevent fast particles from skipping a thin quad and preserve deletion events for child systems.
- Added `remapvalue` and `remapinitialvalue`, scalar/vector ranges, independent input/output clamping, assignment/multiplication/addition/subtraction, lifetime blending, sine/cosine, simplex noise, and fractal noise. Unknown remap variants remain explicitly unsupported. Visual values reset to the initialized appearance each frame so multiplicative remaps compose with fades without frame-rate-dependent decay. Zero-size particles survive so later operators or properties can grow them again.
- Added `capvelocity` with lifetime blending. Tests cover fade-in/out, direction preservation, stationary particles, and particles already below the speed limit.
- Added a dedicated five-scene [particle canary set](../CompatibilitySuite/particle_scene_canaries.json) for the local projects previously excluded by boids, remapping, and quad collisions.

These implementations follow official behavior descriptions and authored local parameters. Flocking force magnitudes/defaults, remap noise sequences, and some implicit remap defaults still need Windows calibration. Sphere/bounds/model collisions, additional particle components, sprite size calibration, atlas animation, and child-system fidelity remain open; recognizing these new operators does not certify complete particle parity.

## Authored particle materials and texture variants

Sprites and sprite trails now execute their authored material passes through the shared shader pipeline. The vertex path supplies particle position, XYZ rotation, size, velocity, lifetime/frame position, and color using the Wallpaper Engine billboard layout. Custom image-layout shaders retain expanded geometry and their own fragment program. All material passes run in authored order; root opacity is applied once, and child systems inherit the root opacity. Rope and rope-trail materials still use the older fixed shader.

The bundled boids example exposed a Metal assertion when its fourth vertex input used buffer index 31. Vertex inputs now occupy the required slots at the end of Metal's 31-buffer range, with uniforms below them. Oversized uniform sets produce an explicit compiler error rather than overlapping vertex data. Uniform packing for shaders that exceed that limit remains open.

Texture bindings now enable sampler-annotated variants such as `MASK`, while preserving explicit combo overrides. The first full-sweep black-frame failure, `2956295460` (Arknights / Texas), had a tint mask whose branch was disabled. Enabling the mask restores the monitors and surrounding scene. Texture channel formats also populate shader combos, including luminance/alpha RG textures, R masks, and compressed normal textures. Pipeline keys account for bound texture slots as well as shader variants.

Regular particle atlases are read from the `TEXS0002`/`TEXS0003` metadata after all image payloads and mip levels. Sprites use one atlas frame with the authored frame aspect, lifetime-scaled sequence speed, or a stable random frame. As the official sprite-sheet tutorial specifies, imported texture duration is ignored for particles. Sequence frames blend; the additionally recognized `once` mode clamps at the last frame and still needs Windows calibration. This currently supports regular grid frames on one image; irregular/rotated layouts, multiple images, sidecar-only atlases, and script-controlled texture animations remain open. Malformed lengths and overflowing atlas dimensions are rejected.

The rain scene `3494637950` exposed two independent visual faults: its fog atlas was drawn as a whole RG image, and particle refraction sampled vertically reversed scene coordinates. Corrected texture variants, atlas sampling, and Metal render-target coordinate adaptation remove the large fog rectangles and square scene patches. Orange artifacts in its rope-based water streams, script errors, missing media widgets, and performance still need work. The adapted source guards are limited to Wallpaper Engine's known refraction-coordinate helpers; arbitrary custom screen-space shaders still need validation.

Solid-layer `g_Color`/`g_Alpha` and combined `g_Color4` bindings now receive evaluated layer color and opacity. Material parameters and annotated defaults retain priority for effect color/alpha uniforms. Pixel tests cover animated layer colors, parameter precedence, masks, authored particle constants, multiple passes, more than three vertex attributes, opacity inheritance, atlas frames/channel conversion, and refraction direction.

Reviewing the first 20-scene material run uncovered skipped frame-builder layers in `3573378561` and `3613126158`, despite nonblack captures. Their shaders use numeric scalar conditions accepted by HLSL. Diagnosed simple scalar ternaries and branches now receive explicit GLSL boolean conversions, with positive, negative, and zero pixel tests. Those effects also require `g_LayerModelMatrix`; it now retains the original layer transform while intermediate passes use their offscreen matrices. The harness now fails a fixture if the renderer logs skipped layers, even when its screenshot is nonblack. Historical reports and the in-flight full sweep retain the older smoke-test classification and must be interpreted with their logs.

The particle canary `3592541966` exposed two more shader translation failures: `or` is a legal GLSL variable name but a reserved Metal operator token, and a vertex shader produced a four-component varying consumed as a two-component value by its fragment shader. Reserved operator identifiers are renamed, and narrower fragment varying views are retained while matching the stage interface. Metal pixel tests cover both failures.

`2986706471` (Holy Mountain) now displays its mountain, temples, sky, and fog instead of a flat white frame. Visual checks remain local comparisons; neither it nor the corrected Texas/rain images has a Windows-reference sign-off.

## SceneScript lifecycle (in progress)

A read-only inventory of the 421 eligible scene packages found 7,263 embedded scripts. Frequently used APIs include audio registration (111 scenes), frame time (114), layer lookup (88), parent lookup (55), timers (72), and local storage (57). The older three-script fixture set does not represent this API surface.

Each SceneRuntime now owns a serialized QuickJS host. Scripted-value descriptors have separate persistent instances, even when multiple properties use identical source. Modules retain lexical state initialized by `init`, receive the current property value, and execute `update` at most once per frame. A cached dispatcher avoids recompiling the authored source during subsequent frames. A script exception no longer discards other instances' state; a stress regression checks repeated failures beside a healthy counter. An unnecessary retained QuickJS reference during JSON serialization was also removed.

Retained audio buffers and their channel arrays refresh in place, including return to silence. SceneScript timers use the runtime clock and millisecond delays and return cancellation functions. Pausing stops updates and timers, and shutdown runs value-script destroy callbacks once. Numeric callback results are expanded to the expected vector type; vector arguments and configured script colors receive vector methods before top-level script code executes. The Vec3 zero-X addition/subtraction bug is fixed.

Value scripts may combine `init`, `update`, and `applyUserProperties` without being misclassified as callback-only scripts. Imperative callbacks also retain their local state, and every distinct callback script on an owner is initialized. Only callback mutations become persistent overrides, avoiding the previous freeze of unrelated animated/scripted properties. Device-query functions describe the native desktop wallpaper runtime. Scene canvas dimensions replace the fixed 1920×1080 value where authored dimensions are available; actual display dimensions and automatic projection updates still require a separate binding.

The first real-scene pass reached additional frame-builder layers in Mount Fuji (`3613126158`), exposing an authored `varying vec4 v_Size.xy;` declaration. The compiler now removes that invalid component suffix before reconciling varying interfaces. Its pixel regression and the real-scene rerun pass: [Mount Fuji shader rerun](../CompatibilitySuite/reports/run_2026-09-12T06-07-00-399541Z_ecd4c732.json). Both the pre-lifecycle and initial lifecycle screenshots still lack the mountain/background and show cloud and media-widget artifacts. This is an existing visual failure even where the earlier nonflat smoke result passed.

The next pass below supplies real property owners, group transforms, layer lookup, and property writes. Remaining scripting work includes dynamic layer creation/removal/reparenting, effect lookup, animation/video/particle controls, input/media events, persistent local storage, imported modules, and vector/matrix API completeness. Existing unimplemented scene and animation helpers are not full support. Timer catch-up cadence and exact callback ordering also need Windows calibration. No complete SceneScript parity is claimed.

## Capture reliability

An app-harness run stalled after loading a wallpaper because macOS stopped delivering display-link ticks. A process sample showed the app waiting in its event loop rather than rendering. Capture and benchmark jobs now use a separate 30 Hz timer and offscreen Metal targets, so display refresh is not required. Interactive playback keeps its existing display link. Automatic projections capture at 1920×1080; explicit projections use their authored dimensions. Offscreen jobs wait for GPU completion and propagate command-buffer errors.

Offscreen benchmark results include GPU completion and may use a different resolution than earlier window-based runs. Their FPS and timing numbers must not be directly compared with those older reports. The interrupted display-link run and the initial 1×1 automatic-projection regression are retained in reports; they are superseded by the corrected 3/3 sample run below.

The initial harness cleanup used a private `TMPDIR`, but disk auditing proved that macOS Foundation ignored it: native package copies accumulated outside the harness directory. The fake subprocess test did not catch this integration failure. The harness now also supplies `WE_PACKAGE_TEMP_DIR`, which the native parser reads explicitly. Scene descriptions share ownership of their extracted assets, so ordinary scene shutdown and failed loads release those copies. Partial extraction failures clean up immediately, and paths escaping the extraction directory are rejected. Real package tests cover copy lifetime, failed scene loading, and malformed archive paths; subprocess tests cover success, failure, timeout, and skipped-layer reporting.

The baseline sweep was paused between fixtures while 432 completed-test extraction copies (about 10.66 GiB) were verified against eligible source packages and removed. Verification required a matching scene hash and complete filename/size table, with creation dates inside this task and before the active test window. No source wallpapers or report captures were removed. The sweep resumed after available disk space returned to about 14 GiB. After completion, another 111 verified baseline copies (3.18 GiB) were removed using the same scene-hash and file-table checks. New validation runs use the explicit directory and scene ownership fix.

## Validation

- Vendored dependency rebuild (`./build-bridge.sh`) and `swift build`: pass. CMake was installed for the dependency rebuild.
- Native tests: nine test functions, including six parameterized placement/effect cases. All pass with Metal access.
- Shader fixtures: 3/3 pass.
- Script host fixtures: 3/3 pass.
- Original-tree sample baseline: 1/3 pass. Built a separate copy of the starting source to establish that `neon_sunset` and `shimmering_particles` already failed.
- Corrected sample lane: 3/3 pass. Report: [sample results](../CompatibilitySuite/reports/run_2026-09-12T03-35-13-538582Z_85e97095.json).
- Final real-scene canaries: 20/20 pass after the fullscreen and texture fixes. Report: [canary results](../CompatibilitySuite/reports/run_2026-09-12T03-35-46-575974Z_10778148.json).
- Final text canaries: 3/3 pass. Report: [text results](../CompatibilitySuite/reports/run_2026-09-12T03-39-48-481549Z_49299a87.json).
- Manual visual check: `3272162526` (Lady of the Lake) now places the sky above the water and restores the recognizable scene composition. Remaining artifacts mean this is not a Windows visual sign-off.
- Before timeline support, `3335365971` (Beyond) produced an effectively flat frame: [earlier failure](../CompatibilitySuite/reports/run_2026-09-12T03-34-54-896238Z_80406464.json). After timeline/material fixes it passes with a nonflat, animated image and no harness errors: [corrected Beyond result](../CompatibilitySuite/reports/run_2026-09-12T03-59-24-943258Z_9ec66d23.json). Its measured app benchmark is only 9.2 FPS on this host; visual artifacts and performance remain work to do.
- After the timeline/material fixes: all 19 native test functions pass (26 cases including parameterized tests), shader fixtures 3/3, script host fixtures 3/3, and sample scenes 3/3: [updated sample result](../CompatibilitySuite/reports/run_2026-09-12T03-58-49-402444Z_5c553a29.json).
- Updated real-scene canaries: 20/20 pass after timeline/material fixes: [updated workshop result](../CompatibilitySuite/reports/run_2026-09-12T04-00-05-104513Z_ea75a21f.json).
- Updated text canaries: 3/3 pass after timeline/material fixes: [updated text result](../CompatibilitySuite/reports/run_2026-09-12T04-04-33-628980Z_4e991950.json). Final scoped diff and new-file whitespace checks pass.
- After particle simulation changes: all 42 native test functions pass, including Metal pixel tests and successive collision contacts; shader fixtures 3/3 and script host fixtures 3/3 pass. Harness temporary-storage tests pass for successful, failed, and timed-out subprocesses.
- Offscreen capture sample lane: 3/3 pass, including the automatic-projection scene and a 5760×1080 scene: [particle/capture sample results](../CompatibilitySuite/reports/run_2026-09-12T04-31-15-539573Z_250e47fd.json).
- Particle canaries: 5/5 pass the harness, with former operator gates removed: [particle scene results](../CompatibilitySuite/reports/run_2026-09-12T04-32-18-484784Z_daf2f89a.json). Visual inspection of `3494637950` still shows repeated scene rectangles and block-like particles. Its offscreen debug benchmark is about 1.7 FPS; other heavy particle scenes are also slow. Particle materials/refraction, geometry, and performance remain open despite these smoke passes.
- Final workshop canaries: 20/20 pass after particle and capture changes: [workshop results](../CompatibilitySuite/reports/run_2026-09-12T04-35-06-345799Z_b572d429.json).
- Final text canaries: 3/3 pass with per-process extraction cleanup enabled: [text results](../CompatibilitySuite/reports/run_2026-09-12T04-39-58-357118Z_41920f39.json).
- The full 421-scene baseline sweep started at 2026-09-12 04:42 UTC and completed with 417 passes, two image failures, one crash, and one timeout. It uses a frozen binary with SHA-256 `54ddf35a068ee1b2479b01e2f116c53b508fd34df138bd7e9c49f42aac3ba599`: [build record](../CompatibilitySuite/reports/run_2026-09-12T04-42-11-334268Z_aaedb3db/build.json). The image failures were `2956295460` and `2986706471`; the crash was `3436945972`, and the timeout was `3462487934`. This is the older frozen baseline, not final-build coverage or a Windows equivalence percentage.
- After authored particle materials, texture variants, atlas playback, refraction, and layer-color fixes: all 54 native test functions pass, shader fixtures 3/3 and script-host fixtures 3/3 pass. Atlas overflow/truncation checks also pass after the scoped review. Sample captures: 3/3 pass: [material/atlas sample results](../CompatibilitySuite/reports/run_2026-09-12T05-22-08-021863Z_bcdbb5ff.json). Workshop, text, particle, and material-failure lanes are being validated against this candidate separately from the frozen full sweep.
- After correcting sequence timing from the official documentation, numeric shader conditions, and the layer-transform uniform: all 56 native test functions pass. Shader/script fixtures remain 3/3, and the harness test verifies both cleanup and failure classification for skipped layers. The stricter canary runs are still in progress; no final material validation is claimed yet.

- The final renderer-only build (SHA-256 `a18bb73f91cea1e87f3dd420d924e7a613ce28dd38d72efb6062c7d6238a152c`) passes 58 native test functions, shader fixtures 3/3, and script-host fixtures 3/3. Its stricter harness results are samples 3/3, workshop 20/20, text 3/3, particles 5/5, and material failures 2/2: [samples](../CompatibilitySuite/reports/run_2026-09-12T05-46-09-797842Z_229e6ef1.json), [workshop](../CompatibilitySuite/reports/run_2026-09-12T05-46-39-531090Z_afda9a1b.json), [text](../CompatibilitySuite/reports/run_2026-09-12T05-51-42-694603Z_b439bada.json), [particles](../CompatibilitySuite/reports/run_2026-09-12T05-52-28-323040Z_bded8e8a.json), [materials](../CompatibilitySuite/reports/run_2026-09-12T05-54-41-020598Z_179b7013.json).
- SceneScript lifecycle tests pass through SceneRuntime, including identical sources on different layers, combined imperative and value scripts, per-owner callbacks, pause/resume, retained initialization values, property events, timer cancellation, audio refresh, repeated exceptions, and destruction. The first lifecycle candidate passes samples 3/3 and text 3/3; the workshop lane is 19/20 because Mount Fuji reaches the additional malformed shader described above. That initial lifecycle batch also passes particles 5/5 and material failures 2/2. Later callback fixes, the varying repair, and package ownership cleanup require the final regression lanes separately from the frozen full sweep.

Commands:

```sh
./build-bridge.sh
swift build
swift test
python3 CompatibilitySuite/run_shader_fixtures.py
python3 CompatibilitySuite/run_script_host_fixtures.py
python3 -m unittest CompatibilitySuite.test_run_suite -v
python3 CompatibilitySuite/run_suite.py --fixtures CompatibilitySuite/fixtures.json --timeout 60 --frames 60 --benchmark-duration 5
python3 CompatibilitySuite/run_suite.py --fixtures CompatibilitySuite/local_scene_canaries.json --timeout 90 --frames 60 --benchmark-duration 5
python3 CompatibilitySuite/run_suite.py --fixtures CompatibilitySuite/text_scene_canaries.json --timeout 90 --frames 60 --benchmark-duration 5
```

The local execution sandbox cannot create a Metal device or app windows. GPU checks were therefore run with native macOS access; sandbox-only launch timeouts are excluded from compatibility conclusions. Swift's module caches were directed to `/tmp` using `CLANG_MODULE_CACHE_PATH` and `SWIFTPM_MODULECACHE_OVERRIDE`, with `--disable-sandbox` for SwiftPM's nested sandbox. CMake was initially missing and was installed from Homebrew for the documented dependency build.

## Remaining work, in priority order

1. Run the full current 421-scene corpus against the final build, preserving the documented exclusions. Investigate remaining visual and performance problems in Beyond and other complex scenes. Retain screenshots and shader/runtime errors, rather than relying on static support labels.
2. Validate the newly added particle operators and authored materials across the full corpus. Complete rope/trail materials, broader atlas formats, child-system behavior, additional particle components, and remaining collision types. Audit sprite sizing and fix performance, then calibrate the simulation against Windows references when available.
3. Add representative pixel/sequence expectations for compositing, crop/padding, text paint order, masks, lighting, HDR/bloom, puppet motion, and 3D camera/model rendering. Reference Windows captures are required for an actual visual-parity claim.
4. Expand property animation and SceneScript coverage: validate serialized curve handles, implement animation controls/events and linked playback, layers/groups and their transforms, per-layer scripting, interaction/events, timers, media, and script-controlled materials/particles. The older phase documents should not be treated as evidence these surfaces are finished.
5. Complete web/video behavior and test it directly. The web renderer currently lacks actual mute support and several documented media registration APIs; CSS/Web Animation pause behavior is covered by pass thirty-three; media integration remains incomplete. Timer cancellation/pause and document navigation delivery are covered by passes twenty-three and thirty. Broaden video formats, alpha, audio, playback controls, and capture validation.
6. Implement and validate quality-of-life parity: persistent per-display assignments/profiles, fit/fill/span behavior, playlists, application/power/fullscreen rules, favorites/search/filtering, property presets/reset/import/export, startup/recovery, and accessible controls. Check existing behavior before choosing each change.

## References

- [Wallpaper Engine custom geometry](https://docs.wallpaperengine.io/en/scene/scenescript/tutorial/models.html) documents positive Y as upward.
- [SceneScript reference](https://docs.wallpaperengine.io/en/scene/scenescript/reference.html) defines the engine, scene, layer, event, and input API surface. [IEngine](https://docs.wallpaperengine.io/en/scene/scenescript/reference/class/IEngine.html) defines retained audio buffers and timer cancellation; [init](https://docs.wallpaperengine.io/en/scene/scenescript/reference/event/init.html) and [update](https://docs.wallpaperengine.io/en/scene/scenescript/reference/event/update.html) define callback value semantics.
- [Timeline introduction](https://docs.wallpaperengine.io/en/scene/timeline/introduction.html) defines playback modes, Bézier easing, loop wrapping, and start-paused behavior.
- [IAnimation reference](https://docs.wallpaperengine.io/en/scene/scenescript/reference/class/IAnimation.html) defines timeline playback controls implemented in pass twenty; broader skeletal animation APIs remain open.
- [Particle emitters](https://docs.wallpaperengine.io/en/scene/particles/component/emitter.html), [initializers](https://docs.wallpaperengine.io/en/scene/particles/component/initializer.html), and [operators](https://docs.wallpaperengine.io/en/scene/particles/component/operator.html) define emission, remapping, flocking, speed limits, blending, and collision behavior.
- [Particle sprite sheets](https://docs.wallpaperengine.io/en/scene/particles/tutorial/spritesheet.html) and [particle system settings](https://docs.wallpaperengine.io/en/scene/particles/component/general.html) define lifetime-scaled sequences, random frames, and sequence speed.
- [Web property listener](https://docs.wallpaperengine.io/web/api/propertylistener) defines property and playback notifications.
- [Web media integration](https://docs.wallpaperengine.io/en/web/audio/media.html) defines the documented media listener registration functions.

References establish behavior contracts; they do not substitute for Windows screenshot comparisons.


## September 12: live scene objects and remaining corpus failures

The final lifecycle/package-ownership build passes 72 native tests and all five canary lanes. Its SHA-256 is `a39e0bf0fd3e57fc3ec073b1252faa1c8f5a04ab561be03e6fd87ca8ff3cfaae`:

- [Samples 3/3](../CompatibilitySuite/reports/run_2026-09-12T06-21-54-665504Z_34bd45aa.json)
- [Workshop 20/20](../CompatibilitySuite/reports/run_2026-09-12T06-22-25-574352Z_62d6ee22.json)
- [Text 3/3](../CompatibilitySuite/reports/run_2026-09-12T06-27-40-523288Z_2ec35aa4.json)
- [Particles 5/5](../CompatibilitySuite/reports/run_2026-09-12T07-08-53-178771Z_e342ae1c.json)
- [Materials 2/2](../CompatibilitySuite/reports/run_2026-09-12T09-01-59-986644Z_ffe2b003.json)

The next implementation restores group scale, rotation, and visibility, including nested groups and live user bindings. SceneScript now receives persistent objects for actual layers and property owners. Name/index lookup, layer counts, enumeration, parent/child lookup, and property writes feed the native frame. Layer scripts run before transform and visibility construction, and a write to a scripted property does not permanently stop its value callback. Layer angles use degrees in SceneScript and radians in scene transforms, following the [ILayer contract](https://docs.wallpaperengine.io/en/scene/scenescript/reference/class/ILayer.html).

The parser now retains nested script-property settings rather than turning their user bindings into null. Boolean combo associations follow the selected option, including properties whose serialized editor snapshot is false. Mount Fuji's day/night controller now selects a background, and the [clean-build canary capture](../CompatibilitySuite/reports/run_2026-09-12T15-15-41-141650Z_16796da0/3613126158/screenshot.png) shows the mountain, city, and lake instead of black. Media controls, local storage, and remaining animation APIs still fail; the image is not a Windows visual sign-off.

The baseline crash reproduces in the lifecycle build. Its stack enters `js_mapped_arguments_mark` and `gc_scan_incref_child`. This matches [QuickJS-NG issue 1400](https://github.com/quickjs-ng/quickjs/issues/1400). The one-line [upstream fix 1401](https://github.com/quickjs-ng/quickjs/pull/1401/files) is backported with an idempotent patch in `build-bridge.sh`. A garbage-collection pressure regression passes. Once the crash is fixed, the wallpaper exposes fragment-input writes in `auto_sway`; the shader translator now gives a diagnosed writable input private storage, preserving narrower component views. Both original launch failures pass the targeted [rerun](../CompatibilitySuite/reports/run_2026-09-12T15-11-22-716851Z_c6737ea9.json).

An intermediate incremental build produced an inconsistent Mount Fuji initialization crash/timeout. A fresh Swift scratch build succeeded on six consecutive Mount Fuji loads. Cleaning/rebuilding the default Swift output also restores successful loading; final acceptance uses a frozen copy of the clean build. The observed evidence is consistent with stale incremental output, but the earlier stack corruption is not treated as an authored wallpaper defect. The final default clean build passes all 82 native test functions, including the new layer/group/material-owner/script-binding tests and fragment-input Metal pixel tests. Its frozen application SHA-256 is `95f86a16fe36da4889b4cf531140bde54cec4a44c6b4b3760fc1dde3c6c6bd6c`. A further material-owner regression passes independently, checking material-local property writes and same-frame layer movement. The final clean-build canaries pass: [samples 3/3](../CompatibilitySuite/reports/run_2026-09-12T15-15-13-603589Z_c1b7d436.json), [workshop 20/20](../CompatibilitySuite/reports/run_2026-09-12T15-15-41-141650Z_16796da0.json), [text 3/3](../CompatibilitySuite/reports/run_2026-09-12T15-19-52-363376Z_12503b5f.json), [particles 5/5](../CompatibilitySuite/reports/run_2026-09-12T15-20-27-433123Z_f0f4a9a6.json), [materials 2/2](../CompatibilitySuite/reports/run_2026-09-12T15-22-15-916649Z_a0c54e2f.json), [crashes 2/2](../CompatibilitySuite/reports/run_2026-09-12T15-22-55-225572Z_974ba73a.json). Shader fixtures 3/3, script-host fixtures 3/3, and harness storage tests also pass. No complete corpus or overall parity claim is made.

The persistent [script canary catalog](../CompatibilitySuite/script_scene_canaries.json) now includes the GC/shader regression, the timeout regression, and Mount Fuji. Dynamic creation, media/local-storage behavior, and full visual equivalence remain open.

A fresh full 421-scene sweep is running against the final clean-build candidate (`95f86a16…`). It uses the stricter skipped-layer classification and explicit package cleanup. This is a discovery/coverage run; script/API diagnostics and Windows visual equivalence still need separate assessment.


## Functional diagnostics alongside rendering

The harness now records script exceptions, material/texture fallbacks, and skipped
layers separately from frame-capture success. `compatibility_status` is either
`issues_detected` or `unverified`; a nonblack frame and the old static `complete`
label never establish Windows parity. Timeout reports carry the same evidence
fields. Existing reports can be audited without rewriting their smoke results:

```bash
python3 CompatibilitySuite/runtime_diagnostics.py <run-directory> --output <audit.json>
```

The [older 421-scene baseline audit](../CompatibilitySuite/reports/pass3-full421-runtime-diagnostics.json)
finds script errors in 112 scenes, renderer fallbacks in 136, and skipped layers in
27, despite its 417 smoke passes. These categories overlap and are not a Windows
coverage percentage. The [latest 20-scene canary audit](../CompatibilitySuite/reports/pass6-workshop-runtime-diagnostics.json)
finds script errors in one scene (Mount Fuji), renderer fallbacks in two scenes,
and no skipped layers. The remaining canary fallbacks are
`g_TextureReductionScale` in Floating Dream (`3096086835`) and
`_rt_imageLayerComposite_128_a` in Mount Fuji (`3613126158`). Four Python harness
and diagnostic tests pass. The already-running new full sweep loaded the earlier
harness implementation and will receive a separate audit after completion.

## September 12, storage and further shader repairs

SceneScript `localStorage` now stores JSON values through a synchronous native
bridge. It supports `get`, `set`, `delete`, and `clear`, with separate screen and
global namespaces, a shared 100 KiB budget per wallpaper, atomic persistence, and
copy-on-read values. This follows the documented [ILocalStorage contract](https://docs.wallpaperengine.io/en/scene/scenescript/reference/class/ILocalStorage.html).
Normal playback stores files under Application Support/WallpaperEngine/SceneScriptStorage;
automation, snapshots, and default runtime hosts use isolated memory storage.
Published wallpapers use their workshop ID, unpublished wallpapers their canonical
folder path, and displays their CoreGraphics UUID when available. Settings reset
finishes scene destroy callbacks, clears every storage scope, restores properties,
and rebuilds the scene. Reset remains accessible without authored user properties;
failed resets preserve the panel's displayed values. Cross-process concurrent
writers and the exact Windows quota accounting are not calibrated.

Floating Dream's `g_TextureReductionScale` now receives 1 because the renderer
does not apply a global texture-quality reduction. Zero previously invalidated UV
offset arithmetic. Two shaders exposed by the stricter full sweep now render:
`2837837781` needs local `const` values initialized from runtime texture data;
`2983846453` needs vector truncation around a complete arithmetic expression,
including macros. Both changes have Metal pixel regressions and real-workshop
canaries in [shader_scene_canaries.json](../CompatibilitySuite/shader_scene_canaries.json).

The frozen rendering candidate `2a0312b9e50f764f92e858b7a9a0a19da05e145043be0e42e065326c8bffa60e`
passes [samples 3/3](../CompatibilitySuite/reports/run_2026-09-12T15-50-17-354216Z_a105f0cd.json),
[workshop 20/20](../CompatibilitySuite/reports/run_2026-09-12T15-50-44-177636Z_bee43f18.json),
[text 3/3](../CompatibilitySuite/reports/run_2026-09-12T15-54-41-580115Z_bc988eb3.json),
[shader regressions 2/2](../CompatibilitySuite/reports/run_2026-09-12T15-55-17-148103Z_f03f8081.json),
and [script canaries 3/3](../CompatibilitySuite/reports/run_2026-09-12T15-55-40-713616Z_ae92abb2.json).
Each run has a `build.json` identifying its frozen executable. The subsequent
unpublished-wallpaper identity correction passes its dedicated storage tests and
[another sample run](../CompatibilitySuite/reports/run_2026-09-12T15-56-26-842260Z_d55abca5.json).
Final reset-panel corrections also have focused UI-model tests. Shader fixtures
3/3, script-host fixtures 3/3, and four Python tests with four harness subcases pass.
The run schema describes the added diagnostic fields. Optional validation with
Python `jsonschema` could not run (`ModuleNotFoundError: jsonschema`); field shapes
were checked directly against the sample reports instead.

The reviewed source passes **94 Swift test functions in 16 suites**. Its frozen
application is `/tmp/wallpaper-parity-pass7-reviewed-bin/WallpaperEngine`, SHA-256
`a74c6b0bfae5b585895e534c8055001b7a1d0e06ab0ae3952e81d246d9bcef97`.
Later review changes affect storage identity and reset behavior; the shader and
scene-runtime implementations match the rendering candidate above. The [reviewed build also passes samples 3/3](../CompatibilitySuite/reports/run_2026-09-12T16-00-01-243174Z_155cceb0.json). Source/test
diff checks pass; generated CMake output has unrelated whitespace diagnostics.

The [new workshop diagnostic audit](../CompatibilitySuite/reports/pass7-workshop-runtime-diagnostics.json)
finds no skipped layers and one remaining fallback scene. Floating Dream's uniform
fallback is gone; Mount Fuji's recorded script exceptions drop from 19 to 12, with
no remaining `localStorage` reference errors. Its media/event APIs and
`_rt_imageLayerComposite_128_a` remain unresolved. The latter references an authored
hidden 4x4 solid layer; visibility and offscreen dependency rendering need explicit
handling rather than a substitute texture.

The full pass-six sweep remains independent and is not restarted. So far it has
also exposed a 90-second timeout in `2837642303` (AGE OF STARS). A runtime-only
eight-frame reproduction completes, but spends approximately 635–664 ms per frame
building packets for 728 nodes, including 724 particle systems. This is a real
performance investigation, not evidence of a native crash. The minified
`import*as` statement in `2983846453` also remains a script syntax failure: the
current import sanitizer only recognizes imports at the start of a line. These
are open work, along with media, hidden-layer render targets, broader video/web
validation, and remaining Windows-equivalence gaps.

At 177 completed fixtures, that independent sweep has 172 passes, four failures,
and one timeout classified by the harness as a crash. In addition to the two
shader cases fixed here, newly recorded failures are `3061226599` (`generic4`
references an undeclared `v_WorldNormal`) and `3114332546` (tone-mapping shader
syntax error). These remain in the original sweep report for targeted follow-up.


## September 12, module imports, optional textures, and runtime cost

SceneScript module rewriting now recognizes minified and multiline imports,
including namespace aliases and named members from WEMath/WEColor. Declarations
are hoisted without editing strings, comments, regular expressions, or templates.
The real minified import in `2983846453` executes without its previous syntax
error. This remains a compatibility rewrite for the built-in modules, not a
complete arbitrary ECMAScript module loader.

Absent optional texture combos remain undefined, allowing `generic4` shaders
that mix `#ifdef NORMALMAP` and `#if NORMALMAP` to select matching branches.
Authored `log10` functions receive a private name to avoid both the compatibility
macro and Metal intrinsic. Pixel tests cover these cases. The expanded four-scene
shader lane captures every fixture, including `3061226599` and `3114332546`.
Its [diagnostic audit](../CompatibilitySuite/reports/pass8-shader-runtime-diagnostics.json)
still records a missing mipmapped reflection framebuffer in Falling Deeper and
script exceptions in two scenes. Successful capture does not resolve those gaps.

The immutable script-owner order is now computed once, and layer membership uses
a set. Unchanged layer values no longer produce redundant script JSON exchanges.
The AGE OF STARS runtime-only eight-frame benchmark improves from approximately
635–664 ms to 89.7 ms per packet, retaining the same node/material/particle counts
and packet sizes. A longer 70-frame run averages 107.5 ms. The
[app capture](../CompatibilitySuite/reports/pass8-age-performance/2837642303/report.json)
now finishes in 83.9 seconds, with no recognized script/fallback/skipped-layer
diagnostics. Its measured playback is only 0.63 FPS (about 1,024 ms average CPU
frame time), so substantial runtime and rendering optimization is still required.
These are debug-build measurements on this Mac, not Windows comparisons.

The first frozen candidate, `/tmp/wallpaper-parity-pass8-bin/WallpaperEngine`,
SHA-256 `7d51ced2b7a7e0ef9216a490183255750466916910cd52104682f61cd74bc52a`,
passes [samples 3/3](../CompatibilitySuite/reports/run_2026-09-12T16-16-16-828987Z_b1b1ee67.json),
[workshop 20/20](../CompatibilitySuite/reports/run_2026-09-12T16-16-43-658532Z_0a79d147.json),
[text 3/3](../CompatibilitySuite/reports/run_2026-09-12T16-20-46-479406Z_3dd2e4c2.json),
[shader regressions 4/4](../CompatibilitySuite/reports/run_2026-09-12T16-21-22-721580Z_8e3fc097.json),
and [script canaries 3/3](../CompatibilitySuite/reports/run_2026-09-12T16-22-28-345450Z_bd66d5bb.json).
It passes 100 Swift tests, three shader fixtures, and three script-host fixtures.
Each corpus run includes a `build.json` identifying that frozen application.

A subsequent change orders visible layers after their transitive render
dependencies, renders required hidden images offscreen, and keeps composite A/B
names attached to their physical textures during ping-pong rendering. A hidden
source remains absent from the desktop. Six Metal pixel cases cover zero, one,
and two effects and both named textures across two frames; another test covers
shared, missing, self, and cyclic dependencies without activating unrelated
hidden layers. All 102 Swift tests in 17 suites pass. The separate frozen candidate
`9f28911c327560d05ac525cdad6d87182279f5bbe99c5970da17d8f8f90795c3` passes
[samples 3/3](../CompatibilitySuite/reports/run_2026-09-12T16-28-48-282679Z_67f09edc.json),
[workshop 20/20](../CompatibilitySuite/reports/run_2026-09-12T16-29-19-100413Z_b7ab315e.json),
[text 3/3](../CompatibilitySuite/reports/run_2026-09-12T16-34-54-522394Z_ddb444a1.json),
[particles 5/5](../CompatibilitySuite/reports/run_2026-09-12T16-35-40-386759Z_4453c613.json),
[materials 2/2](../CompatibilitySuite/reports/run_2026-09-12T16-38-28-049594Z_18f46ff8.json),
[shaders 4/4](../CompatibilitySuite/reports/run_2026-09-12T16-39-18-383681Z_5336dfb3.json),
and [scripts 3/3](../CompatibilitySuite/reports/run_2026-09-12T16-40-51-498393Z_b79ed7d2.json).
The [workshop audit](../CompatibilitySuite/reports/pass8-hidden-workshop-runtime-diagnostics.json)
now has zero renderer fallbacks or skipped layers; Mount Fuji retains 12 script
diagnostics. Its measured CPU frame time increases from 304 to 442 ms while the
required hidden layers are enabled. These runs had concurrent workload, so an isolated comparison is needed before
attributing that difference to the dependency work. Performance remains open;
the required dependencies are retained.
Dynamic layer creation, hidden text targets, and temporal feedback are not
established by this image-dependency fix.


## Further corpus discoveries and video evidence

The continuing full sweep exposes two more shader forms: semicolons terminating
`#elif` expressions in `simple_gradient_audio_bar` (`3409595232`, also
`3439745927`), and HLSL line continuations in `depthparallax` (`3414858021`).
The preprocessor now removes conditional terminators and splices continued lines
before include processing. Both real shader sources compile. New Metal pixel
tests exercise all three audio-style branches and both LF/CRLF continuations in
expressions and included macros. The script in `3409595232` also separates its
export declarations with nonbreaking spaces; the module lexer now recognizes
ECMAScript Unicode whitespace and line separators without changing literals or
Unicode identifiers. Nine separator cases and comment-termination tests pass.
The source passes 106 Swift tests in 17 suites, three shader fixtures, three
script-host fixtures, and four Python harness/diagnostic tests.

The frozen next candidate is `/tmp/wallpaper-parity-pass9-bin/WallpaperEngine`,
SHA-256 `772250660250c2b7213c91af4d9e93a5ed00668c84ecb65f810d8a88a7f51547`.
It passes samples 3/3 (`run_2026-09-12T16-43-32-230168Z_7035f074`), workshop
20/20 (`run_2026-09-12T16-44-01-661159Z_5aceb7f4`), text 3/3
(`run_2026-09-12T16-49-19-799985Z_dd939a33`), shaders 6/6
(`run_2026-09-12T16-50-05-955505Z_201d487f`), and scripts 3/3
(`run_2026-09-12T16-52-19-057773Z_e05957c2`). Build identities accompany each
report. The separate discovery lane passes `3439745927` but still finds black
output in `3415190399`; the subsequent alignment and blending fixes are below.

All [45 local videos](../CompatibilitySuite/reports/pass8-video-decode.json) have
playable AVFoundation metadata and two successfully decoded frames each. The
reproducible [probe](../CompatibilitySuite/VideoDecodeProbe.swift) and
[catalog](../CompatibilitySuite/video_corpus.json) retain this lane. This does
not validate app playback, audio, looping, or controls. The single web wallpaper
also awaits app-level validation. The three previously untyped entries are
valid published presets (`2835508488`, `2984332953`, `2984368737`), each containing
`dependency` and `preset` fields; preset loading is a support gap, not corrupt
metadata. Application wallpapers remain outside the goal.


## Image anchors and layer color blending

Image alignment now places the authored edge or corner at the layer origin,
before applying scale and rotation. This includes puppet and OBJ geometry;
OBJ cache entries retain distinct offsets. Eighteen alignment/effect pixel
cases, a rotated/scaled anchor, and a shared-OBJ cache test pass (109 Swift tests
total). The pass-ten build `f48b1ceb1f9e6f8fd9592418739939ca7949136942d0225f46cef8875b67d45f`
passes samples 3/3, workshop 20/20, and text 3/3. Its four-material discovery lane
passes Breaking the Clouds (`3415190399`), whose anchored border layers previously
covered the image, but still fails the flat night scene (`3448877775`). The
alignment-only capture retains visibly incorrect cloud bands.

Layer `colorBlendMode` was parsed but never rendered. A final stock
`genericimage3` pass now blends the completed layer/effect chain against the
current scene, using its authored BLENDMODE equations. Screen sampling uses
Metal's vertical convention. The added pass receives neutral tint/opacity, and
the initial offscreen material writes straight color/alpha before final
compositing. Twelve pixel cases cover normal, multiply, overlay, and additive
layer modes with zero/one/two effects, two frames, half opacity, and asymmetric
backgrounds. All **110 Swift tests in 17 suites pass**.

The [night capture](../CompatibilitySuite/reports/pass11-layer-blending/night.png)
now retains its artwork instead of becoming flat, and the
[cloud capture](../CompatibilitySuite/reports/pass11-layer-blending/clouds.png)
no longer has the dark bands seen after alignment alone. Neither snapshot skips
a layer or reports a texture/uniform fallback. The night scene still reports
eight animation API script errors. These are local visual checks, not Windows
reference comparisons. Both scenes are retained in the four-case material lane.

The frozen pass-eleven application is
`5865dc8a2666137af74e6ff6dc05bb7d16444c960d388ba71b1a3592d6106342`.
It passes samples 3/3 (`run_2026-09-12T17-10-02-260069Z_1b16929e`), workshop
20/20 (`run_2026-09-12T17-10-33-286042Z_ceab450d`), text 3/3
(`run_2026-09-12T17-16-06-636048Z_e19210ef`), materials 4/4
(`run_2026-09-12T17-16-52-911075Z_97cda106`), shaders 6/6
(`run_2026-09-12T17-18-33-924582Z_47fda6d3`), scripts 3/3
(`run_2026-09-12T17-20-52-252925Z_67411e59`), and particles 5/5
(`run_2026-09-12T17-22-29-400616Z_3bf6b23c`). Each run records the frozen build.

## Completed pass-six full sweep

The [421-scene sweep](../CompatibilitySuite/reports/run_2026-09-12T15-24-19-114031Z_2669bb64.json)
finishes with **405 passes, 14 failures, and two 90-second timeouts**. The latter
are classified as crashes by the harness but are not confirmed native crashes.
The [saved-log audit](../CompatibilitySuite/reports/pass6-full421-runtime-diagnostics.json)
finds script exceptions in 100 scenes, renderer fallbacks in 53, and skipped
layers in 13; these categories overlap. This sweep used the frozen pass-six
binary, so it retains failures fixed by passes seven through eleven. It is not
a current-source coverage percentage.

Remaining targeted discoveries include chroma reflection sampler macros and
scalar vector initialization in `3229704729`, an inactive empty shadow-mask
helper in `3389385059`, and the second timeout `3497488774`, which also exposes
conditional fragment-input mutation and many script API errors. Successful
captures elsewhere do not establish Windows visual or functional equivalence.


## Remaining shader forms and script scope isolation

The compiler header now supports stock sampler-parameter/argument macros, and a
diagnostic-driven repair broadcasts numeric scalar initializers into vectors.
Fragment-input mutation repair preserves repeated declarations and entry points
under their conditional shader-version guards. The real chroma reflection,
mipmapback, and auto_sway shader sources compile after these changes.

For a diagnosed missing-return error, glslang preprocessing now proves whether
its helper is empty and unreferenced in the active variant. Only that empty
unused definition is removed. Active calls—including calls through macros—still
fail rather than receiving an invented result. The real CRT shadow-mask shader
compiles in both enabled and disabled variants. Five new tests cover these cases;
115 Swift tests, three shader fixtures, three script-host fixtures, and four
Python harness tests pass. Shader snapshot changes are limited to the two new
header macros; generated Metal output is unchanged for those snapshots.

The pass-twelve application is
`c9324fea4448636019bdad90faf70ea6d8c33d71489d63cb072e883c5d0e9e89`.
Its required canaries finish with samples 3/3, workshop 20/20, text 3/3,
materials 4/4, shaders 8/8, scripts 4/4, and particles 5/5. Each run has a build
identity. The four-case discovery run
`run_2026-09-12T17-36-47-482763Z_2e410fb3` passes `3264251271`, `3378594980`,
and `3417957645`; `3497488774` still times out at 90 seconds. Remaining reflection
framebuffers and model/lighting accuracy are separate from shader compilation.

A later runtime diagnosis identifies the common `state is not initialized`
error: authored `let state` declarations shadowed the host's initialization
variable in the same closure. Authored value and callback scripts now have their
own scope, with exported callbacks returned to the host prelude. This also keeps
wallpaper locals such as `copy`, `__props`, and `engine` from changing host
bookkeeping. Two lifecycle tests exercise initialization, property updates,
retained locals, and callback isolation. All **117 Swift tests in 17 suites** and
three script-host fixtures pass.

The real scale script in `3042793806` throws that ReferenceError on pass twelve
and returns `[0.75, 0.75, 0.75]` on the new host with its authored minimum/maximum
settings. It is now a permanent script canary. The frozen pass-thirteen app is
`41d2b13d9f7a966ddabf2f22e636cba71f7c51e030a3478eac658c28faea8c29`;
all seven canary lanes pass: samples (3), workshop (20), text (3), scripts (4),
shaders (8), materials (4), and particles (5). Each run retains its build identity.
The [script audit](../CompatibilitySuite/reports/pass13-script-runtime-diagnostics.json)
still records two scenes with script errors and one renderer fallback. The old
full sweep recorded the state error in 272 script instances across 56 scenes.
A subsequent [runtime startup check](../CompatibilitySuite/reports/pass13-state-runtime/summary.json)
steps all 56 scenes through one warmup plus two measured frames: all complete,
and none reports the state-initialization error. Other script errors remain in
51 scenes. This check does not render images or validate later interactions.

At pass thirteen, timeline controls remained open: the documented
[IAnimation](https://docs.wallpaperengine.io/en/scene/scenescript/reference/class/IAnimation.html)
exposes a playback rate, play/pause/stop, and frame seeking;
[thisObject.getAnimation](https://docs.wallpaperengine.io/en/scene/scenescript/reference/class/IThisPropertyObject.html)
can select the current property's animation when no name is supplied. Implementing
this required persistent playback state shared by the script objects and the
property animation evaluator. Pass twenty implements that property-timeline path.


## Visual review: animated 3D models still fail

Although the pass-twelve shader lane captures all eight scenes, its
[Interactive Boat frame](../CompatibilitySuite/reports/run_2026-09-12T17-28-47-186695Z_81bea48b/3229704729/screenshot.png)
has missing/malformed boat and shark content compared with the wallpaper's local
`preview.jpg`. The scene references `models/GreatWhite/GreatWhite.mdl`, with
multiple skeletal animation layers. Current image geometry loads OBJ or a
separate 2D puppet path, then falls back to a quad. The puppet decoder stores XY
positions and affine bone transforms; it is not a 3D MDL renderer. Geometry also
needs normals/tangents, perspective handling, depth testing, and correct
reflection/lighting inputs before this scene can meet visual equivalence.

The [shader audit](../CompatibilitySuite/reports/pass12-shader-runtime-diagnostics.json)
records three scenes with script errors, three with renderer fallbacks, and no
skipped shader layers. Its successful captures are not visual acceptance. The
runtime diagnostic collector now also classifies zero-filled vertex attributes
as fallbacks, backed by a regression test; all five Python tests pass. The
[expanded pass-six audit](../CompatibilitySuite/reports/pass6-full421-runtime-diagnostics-v2.json)
therefore counts 54 fallback scenes (the previous collector counted 53), while
retaining the same 405/14/2 smoke results. A subsequent support-reporting change identifies direct MDL models explicitly
as partial, described below.


## Frame timing, inverse matrices, and model capability reporting

`g_Frametime` now receives the frame delta in seconds, and
`g_ModelViewProjectionMatrixInverse` receives the inverse scene transform.
Offscreen passes override both model and model-view-projection inverses to match
the matrices they actually use. Three two-frame pixel cases round-trip rotated
geometry through both matrix pairs, with zero/one/two effects and changing frame
deltas. The previous full sweep had frame-time fallbacks in 27 scenes and inverse
MVP fallbacks in ten (counts overlap).

Direct `.mdl` model references without a 2D puppet descriptor are now explicitly
reported as `3d-models` partial support, while retaining the partial render.
A regression test distinguishes that report from ordinary image layers. All
**119 Swift tests in 17 suites pass**. This reporting corrects earlier complete
labels; it does not implement 3D geometry. Neon Sunset's retained MDL layers now
make that sample partial rather than a full pass, with its frame still captured.

The frozen pass-fourteen application is
`3c37b42b1faea824d260322a2c9cb3b7fbf67825aed277aef783c47e54a932de`.
All seven lanes complete without unexpected failures: samples **2 pass/1 partial**,
workshop **20 pass**, text **3 pass**, scripts **4 pass**, shaders **6 pass/2 partial**,
materials **4 pass**, and particles **5 pass**. The three partial reports retain
known `3d-models` limitations. The new full sweep is
`run_2026-09-12T17-58-38-504453Z_e8feffc4`; it is still in progress and uses
this frozen build, preceding the pass-fifteen performance and pass-sixteen vector
changes. Its output directory retains `build.json`.

A bounded pass-fourteen snapshot of `3497488774` completes its first frame in
17.25 seconds. The earlier 90-second full-capture timeout therefore does not
establish a startup crash. A 60-frame snapshot completes in 111.27 seconds with
exit status zero, exceeding that suite timeout. A five-second steady-state CPU
profile places most main-thread time in scene runtime/script evaluation, including
repeated user-property resolution and JSON exchange. Both captures share the
machine with other validation runs, so this is diagnosis rather than an isolated
performance comparison.


## Script evaluation cost (pass fifteen)

Literal project properties now resolve once per evaluator context, and the host
reuses their encoded JSON while the values are unchanged. Successful duplicate
reads with identical inputs and a frame index reuse the script result; changed
inputs still dispatch, failed calls are retried, and cross-layer writes remain
applied separately. Unframed calls also clear stale frame/pause metadata in the
JavaScript dispatcher. Two new lifecycle tests cover repeated reads, property/base
changes, a failing property event, retrying an update, and unframed advancement.
All **121 Swift tests in 17 suites** and three script-host fixtures pass.

A [12-frame runtime comparison](../CompatibilitySuite/reports/pass15-runtime-performance/summary.json)
(one warmup) measures `3497488774` at **1524.03 → 456.15 ms** average frame-packet
work. `2837642303` remains **166.22 → 166.19 ms**, so its bottleneck is unresolved.
These runs share the machine with rendering validation; they are not isolated
benchmarks or full rendering FPS measurements. The frozen pass-fifteen app is
`6f91bc9b4e373c409fa57b306176349efbac5e57c2dab402e9d77935b8457148`.
All seven canary lanes complete without unexpected failures (the same three
known 3D-model partial reports are retained). The [60-frame snapshot](../CompatibilitySuite/reports/pass15-runtime-performance/heavy-pass15.png)
completes in **57.49 seconds**, versus **111.27 seconds** on pass fourteen.
Visual review still finds layout/artwork defects and runtime API errors; faster
capture is not visual acceptance.


## SceneScript vectors (pass sixteen)

The script host now supplies `Vec4` and the missing arithmetic/geometry helpers
for the vector classes, following the documented
[Vec2](https://docs.wallpaperengine.io/en/scene/scenescript/reference/class/Vec2.html),
[Vec3](https://docs.wallpaperengine.io/en/scene/scenescript/reference/class/Vec3.html), and
[Vec4](https://docs.wallpaperengine.io/en/scene/scenescript/reference/class/Vec4.html)
interfaces. Constructors parse component strings and zero-fill missing dimensions;
`Vec3(x, y)` no longer incorrectly copies x into z. Vector copies through value
scripts, callbacks, script properties, and scene bindings preserve the fourth
component and its methods. Component writes through material bindings still reach
the frame packet.

Eight added test functions cover constructors, independent arithmetic results,
length/distance, reflection/projection/refraction, interpolation, negative modulo,
rounding, bounds, frame persistence, callbacks, and material component writes.
All **129 Swift tests in 18 suites** and three script-host fixtures pass. Vector
`equals` uses an absolute epsilon of 1e-6; the documentation does not specify its
exact threshold. The spherical implementation uses +Y polar and +X azimuth origin.
Those edge conventions have not been compared against Windows.

A [12-frame heavy-scene runtime check](../CompatibilitySuite/reports/pass16-vector-runtime/summary.json)
completes with no `Vec4 is not defined` errors. It averages **643.05 ms** per frame
packet under concurrent validation, versus 456.15 ms in the earlier pass-fifteen
run; vector work and additional script execution need further performance review.
Other script/API failures remain. The frozen application is
`109147096ee35e2c35a774b06e8194e5f2fd8b0fdb2a71b5d8baa059ab2514c2`;
all seven rendering lanes complete without unexpected failures, retaining the known 3D-model partial reports.


## Vector arithmetic cost (pass seventeen)

A synthetic 200,000-iteration Vec3 copy/add/multiply loop exposed excess
per-component JavaScript callback overhead in the new constructors and basic
arithmetic. Those paths now assign components directly while retaining the new
APIs. The [recorded loop](../CompatibilitySuite/reports/pass17-vector-performance/optimized.json)
returns identical numeric values and measures **3016 → 750/964 ms** under shared
machine load. The earlier vector implementation measured 417/817 ms in a separate
pair of runs, so these results establish the pass-sixteen overhead without proving
an exact speed match to pass fifteen. All **129 Swift tests in 18 suites** pass.

The heavy-scene runtime check measures 698.98 ms per frame packet while full Metal
tests and rendering lanes run concurrently; that measurement cannot establish
whether real-scene performance improved. Missing Vec4 errors remain absent.
The frozen app is
`7b012abb00ad0e221eb1daa8cc9bd2e72d92fc4aee37d33a30906728ab023e30`;
all seven rendering lanes complete without unexpected failures, retaining the known 3D-model partial reports.


## Authored script order (pass eighteen)

The first layer of `3497488774` installs a shared script library; later layers
register events and property groups through it. The previous runtime processed
callback-only scripts before any value scripts and sorted callback owner IDs.
It therefore attempted event registration before the authored library existed.
Callbacks and value scripts now follow authored layer order. Two regressions
exercise an earlier value library followed by callbacks, callback libraries with
non-sorted IDs, and refreshing shared state before property-change callbacks.
All **131 Swift tests in 18 suites** and three script fixtures pass.

The [heavy runtime check](../CompatibilitySuite/reports/pass18-script-order/summary.json)
reduces unique failure lines from 122 to 112. Missing event registration/library
property-group errors disappear; animation and other APIs still fail. A
[60-frame snapshot](../CompatibilitySuite/reports/pass18-script-order/heavy.png)
completes in 95.39 seconds under concurrent validation. The frozen app is
`d1935e6c8f3990e54acd17d7e35ca550eee1e1b861c1b55e318732d310147286`.
This intermediate ordering build has unit/runtime/snapshot evidence; full canaries
will validate the subsequent unified property-script lifecycle build.


## Unified property-script lifecycle (pass nineteen)

Property scripts no longer select different runtimes based on whether their
`init` function declares a parameter. All run through the persistent value host,
which supports initialization returns, user-property callbacks, timers, updates,
and shutdown. This removes the separate callback runtime's discarded returns,
source-based deduplication, and duplicate override storage. Layer mutations stay
in the existing scene binding channel. The host checks the actual exported
`update` function, including arrow functions, when deciding whether a cross-layer
write should expire on a later frame.

Three new regressions cover parameterless initialization returns, persistent
initialization writes, separate instances for identical sources on different
properties, and arrow updates after another script writes their property.
All **134 Swift tests in 18 suites**, three script fixtures, and five Python tests
pass. The [heavy runtime check](../CompatibilitySuite/reports/pass19-property-lifecycle/summary.json)
completes with 112 unique failure lines, unchanged from pass eighteen; those
remaining animation/media/scene APIs still need implementation. Runtime timing
remains affected by concurrent validation.

The frozen app is
`259429a2a9d0ab0bb4e6f2a3e53916705d5974b98779439d3ab38f97c96fd52f`.
All seven canary lanes complete without unexpected failures, retaining the known
3D-model partial reports. The script manifest now also includes
`3497488774` (five scenes) to exercise shared-library startup, Vec4 values, property
lifecycles, and sustained rendering. A successful capture still does not accept
its known visual defects or remaining API errors.


## Property timeline playback (pass twenty)

Property timelines now have persistent playback state shared by script bindings
and the existing curve evaluator. The documented `getAnimation` lookup supports
names and the current property, with frame seeking, rate, play/pause/stop, and
metadata. Single, loop, mirror, reverse playback, start-paused, global pause, and
separate scene instances are covered. Seeks synchronously sample the property,
so a script can read the new value immediately; a seek also supersedes an earlier
manual write to the same property. Skeletal animation layers use a separate API
and remain incomplete. Windows endpoint conventions have not been measured.

All **140 Swift tests in 19 suites**, three script fixtures, and five Python tests
pass. The [heavy runtime check](../CompatibilitySuite/reports/pass20-timeline-controls/summary.json)
completes twelve measured frames with 98 distinct failure lines, down from 112
in pass nineteen. Its 530.27 ms average frame-packet time overlaps rendering
validation, so it is not an isolated performance comparison. Remaining errors
include animation-layer, media, and other scene APIs.

The frozen app is
`9c6b49324898969d4f09e2845f71fb9cbcbff8cadc0c83684778fd86ab35d1ce`.
All seven canary lanes complete without unexpected failures, retaining known
3D-model partials. The pass-fourteen full corpus sweep also
continues; neither run establishes Windows visual equivalence.


## Published presets and web property delivery (pass twenty-one)

The app now resolves published presets through their installed sibling workshop
dependencies. It preserves preset titles, previews, property storage identity,
and authored defaults, including nested presets and preset-owned image files.
Missing dependencies and dependency cycles produce specific loading errors.
Absolute texture paths now reach Metal's image loader, covering imported and
preset-owned images outside the dependency folder. Host-level preset settings
(such as alignment and color correction) remain unapplied and are reported as
`preset-options` partial support in scene captures.

Web property parsing now reads `general.properties`, preserves numeric combo
values and labels, and sends initial and changed events using JSON serialization.
Control characters and malformed/nonfinite slider values cannot break the event.
This follows the documented [web user-property interface](https://docs.wallpaperengine.io/en/web/customization/properties.html).

All **148 Swift tests in 22 suites** pass, including live WKWebView initial/change
delivery, preset dependency/default handling, and a Metal pixel check using a
texture outside the dependency root. The frozen app is
`6fedfcc8f1c9c237a3090947f649f16b30b8f861534fe8fdacfaf61f44ea6164`.
Its initial samples/workshop/text lanes pass; the heavy script scene exceeded
the 90-second limit on both attempts under concurrent validation. That intermediate
run stopped; pass twenty-two validates the combined changes and the two locally
resolvable scene presets (`2835508488` and `2984332953`). The third preset (`2984368737`)
requires missing dependency `884307090`; it cannot be rendered from this corpus.
Web directory properties, media integration, playback controls, and host preset
options still need work. This is partial preset support, not visual acceptance.


## Mismatched shader varying widths (pass twenty-two)

The pass-fourteen full sweep found a skipped topographic effect in scene
`3129087373`: a vec2 vertex output linked to a vec4 fragment input produced an
invalid Metal assignment. Interface normalization now also handles wider
fragment declarations, preserving produced components and supplying zero for
absent components. The affected shader only reads the produced xy coordinates;
Windows values for absent components remain unverified.

All **149 Swift tests in 22 suites**, three shader snapshots, and three script
fixtures pass. Four added Metal pixel cases cover vec2/vec3 producers and
vec3/vec4 consumers. A [two-frame local capture](../CompatibilitySuite/reports/pass22-varying-interface/lofi.png)
completes without shader errors or skipped layers. Visual review still shows
strong distortion in the scene, and the heavy scene's pass-twenty capture still
has layout defects. Successful compilation does not settle those issues.

The frozen app is
`7b2b028d251fc9949abd37a1783fd477b18c43d3ad822988fbe67d102bfd193f`.
All eight lanes complete without unexpected failures: samples (2 pass, 1 known
3D partial), workshop (20 pass), text (3 pass), scripts (5 pass), shaders (7 pass,
2 known 3D partials), materials (4 pass), particles (5 pass), and presets (2
`preset-options` partials). Each report retains build identity. This driver
snapshots its manifests so subsequent catalog changes cannot alter a frozen run.


## Web playback lifecycle (pass twenty-three)

Web timer/animation-frame handles now stay numeric and cancellable across
pause/resume. Native scheduling is canceled while paused; remaining timeout
delays and callback arguments are preserved. Repeating timers handle cancellation
and pause/resume inside callbacks without duplicate scheduling. Loading remembers
a pending pause, and stopping then playing reloads the wallpaper instead of
resuming the blank teardown page. Media suspension uses WebKit's public
`setAllMediaPlaybackSuspended` API; audio/video state has not yet been verified
with a media fixture. CSS/Web Animations, mute, and media integration remain open.

The regular run discovers **155 Swift tests in 24 suites**, with the opt-in local
web corpus probe skipped; all other tests pass. Five Python checks and three
script fixtures also pass. Timeout reports now say `timeout` and retain the
observed backend rather than claiming a process crash. Historical reports are
left unchanged. The frozen application is
`dda0624a8579305eb4a4243e7bd045f6467286b1459c92d7bb3712f808deca67`.
Shared scene code is unchanged from pass twenty-two, whose rendering lanes
subsequently completed with the known 3D/preset partials.

The opt-in [real web probe](../CompatibilitySuite/reports/pass23-web-playback/report.json)
loads `860265906`, renders a [2560×1440 screenshot](../CompatibilitySuite/reports/pass23-web-playback/web.png),
delivers all 15 properties, holds its timer counter at 11 during pause, and
advances it to 17 after resume. It fails its no-script-errors assertion because
the unmodified wallpaper contains a malformed second `wallpaperPropertyListener`
object. An [independent Node syntax check](../CompatibilitySuite/reports/pass23-web-playback/authored-syntax-check.log)
of that original inline block fails at the same semicolon. The local wallpaper
files are unchanged. The screenshot shows the star field, clock, spectrum circle,
and snow; the authored ripple-property block remains broken.

Pass twenty-one's heavy scene timed out twice at 90 seconds under concurrent
validation. Pass twenty-two subsequently completes that same canary in 78.47
seconds, averaging about **1.00 fps** in its short benchmark. This is still a
serious performance gap, not acceptable Windows performance parity. The old
pass-fourteen full corpus sweep continues finding additional cases.


## Extended puppet bone indices (pass twenty-four)

The 80-byte puppet vertex layout now reads all four uint32 bone indices at
offset 40. The old layout read bytes from the final index instead, assigning
weights to incorrect bones. The layout was checked against the GreatWhite and
Waves models in eligible scene `3229704729`. A weighted deformation regression
uses separate bones and proves the expected translated position. All regular
Swift tests pass (156 discovered, one opt-in web probe skipped).

The frozen application is
`47bc8f85a3c52bc47c84787111143a430f2526b0b35278bba54f9b04eb23dc2a`.
All eight canary lanes complete without unexpected failures. `3202712214` also
passes in this run's ten-scene shader manifest, confirming the second
varying-width failure from the older full sweep is fixed. Known 3D and preset
host-option partials remain.
An [eligible direct-model inventory](../CompatibilitySuite/reports/pass24-puppet-indices/direct-model-inventory.json)
finds ten direct model paths across three scenes. Static meshes, multi-material
models, depth, perspective, and full 3D skeletal transforms remain incomplete.

## User-selected scene textures (pass twenty-five)

Material `usertextures` entries refer to property names. The runtime now resolves
those properties to selected file paths and replaces the appropriate authored
texture slots. Empty or missing selections keep the authored texture. Changes
apply live, including to secondary samplers and images with effect chains.
Four Metal pixel cases exercise selecting an external image, clearing the
selection, and selecting it again. All regular Swift tests pass (157 discovered,
one opt-in web probe skipped), along with three script fixtures and five Python
checks.

The frozen application is
`ec8e120c5de12d8218c5c048bd2d6e6c2354621d7ea2d1e2a7195f1cc8ee7142`.
A [preset capture](../CompatibilitySuite/reports/pass25-user-textures/preset.png)
now shows the selected street background instead of the instructional image.
The capture also exposes flipped/clipped text and a black rectangle behind the
switch. These are separate rendering defects and are not accepted as parity.
All eight canary lanes complete without unexpected failures on this frozen build,
retaining the known 3D and preset host-option partial reports.

## Text orientation, layout, and compositing (pass twenty-six)

Text rasterization now keeps Core Text's upright coordinate system and normalizes
line baselines before applying top/center/bottom alignment. Text quads are centered
on their layer origin, consistent with the local centered clock layers. Authored
RGB values use one explicit color space; premultiplied Core Graphics pixels are
converted to the straight color expected by scene effects. The final blend applies
opacity once and preserves coverage alpha. Whitespace is preserved in nonempty
text, and the raster cache key includes shadow and block alignment settings.

Text effects now use a clip-space transform for their clip-space geometry. Ordinary
intermediate passes preserve straight color, and the already rasterized tint is
not applied a second time through `g_Color4`. Six pixel cases reproduce the old
failures and verify upright asymmetric glyphs, all vertical alignments, centered
placement, exact RGB/50% opacity, and pixel-equivalent zero/one/two copy effects.
All regular tests pass (159 discovered across 26 suites; one opt-in web probe
skipped). The frozen app is
`482defa44762070a1c1361fe1884b2741d210350e5e30eb79f60b277afe19eaa`.

The [same preset capture](../CompatibilitySuite/reports/pass26-text-rendering/preset.png)
now has readable upright clock/date text. The black rectangle remains and is
being traced separately to an unpopulated compose-layer texture used by a clipping
mask. Samples/workshop/text/preset lanes complete without unexpected failures.
Dynamic text sizing, screen anchors, and exact Windows font metrics still need
work; text paint order is addressed in pass twenty-eight.

## Compose-layer capture and local effects (pass twenty-seven)

Compose layers now honor their authored size and world transform when sampling
the existing scene. The base pass fills the layer's named composite texture even
when a visible layer has no effects. A final copy places that capture back into
the scene; effect-bearing compose layers composite into their local region.
Fullscreen layers retain their separate screen-space behavior. The stock shader's
paired HLSL coordinate adjustments are also applied for Metal texture orientation.

Six pixel cases cover hidden/visible captures with zero/one/two effects, checking
the sampled scene region, orientation, consumer texture, and untouched background
on consecutive frames. All regular Swift tests pass (160 discovered across 26
suites; one opt-in web probe skipped), plus three shader and three script fixtures.
The frozen app is
`fb35356a9b5f19be66e383ffe5dca70c2e0010ee4b452c77f53804a4e203e674`.

The [preset capture](../CompatibilitySuite/reports/pass27-compose-layers/preset.png)
now removes the black clipping-mask rectangle and places the audio bars in their
local region. This is a visual improvement verified against the preceding local
captures, not a Windows reference comparison. All eight canary lanes complete
without unexpected failures, including `3202712214` and newly discovered
`3435049131` in this run's eleven-scene shader manifest. Both additional shader
cases pass; the known 3D and preset host-option partials remain.

## Text paint order (pass twenty-eight)

Text now participates in the authored render order alongside images and particles.
Previously, all plain text was drawn after every image, followed by all text with
effects. Later foreground images could not cover text, and scene effects could
not process text authored before them. Plain text now blends in place without a
full-scene copy; text effects retain separate input/output textures.

Six Metal cases cover text before/after an opaque foreground image with zero,
one, or two text effects. All regular tests pass (161 discovered across 26 suites;
one opt-in web probe skipped). The frozen application is
`b6dc1aae37a2af8df349477057d1e079db5582bf0b456793834a8fe90dde569e`.
Samples/workshop/text/preset lanes complete without unexpected failures. No public model or C bridge layout
changed in passes twenty-four through twenty-eight.

## Font scale and padding (pass twenty-nine)

[Measurements of 28 authored labels](../CompatibilitySuite/reports/pass29-text-metrics/font-measurements.json)
across three eligible scenes show saved widths about 4.1 times the advances at
the previous Core Text point size. Decima Mono's 12pt and 8pt labels match exactly
at 300 DPI; other sizes/fonts differ slightly with glyph advance rounding. The
renderer now converts scene points at 300/72 pixels per point. This is inferred
from the local corpus, not a Windows raster comparison. Padding expands the
texture and centered quad instead of shrinking the content area, consistent with
the documented [text-layer padding semantics](https://docs.wallpaperengine.io/en/scene/scenescript/reference/class/ITextLayer.html).

An initial capture exposed a missing date after the scale correction. Core Text
can reject integer-rounded line boxes; a two-pixel allowance in the layout frame
keeps such lines while baseline normalization preserves the original texture
bounds. The [corrected capture](../CompatibilitySuite/reports/pass29-text-metrics/rounded/preset.png)
shows the full-size clock and date. Four font-scale/padding cases and four
rounded-line-box cases cover this behavior. The synthetic text demo now uses
scene point units and centered origins.

All regular Swift tests pass (163 discovered across 26 suites; one opt-in web
probe skipped), together with three shader fixtures, three script fixtures, and
five Python checks. The frozen application is
`cb8dcae6421a242f4846d85563b1cff67ae2eb247e7b37ff1e1a15650b8e57fb`.
Samples/workshop/text/preset/text-demo lanes complete without unexpected failures. Dynamic content sizing,
Windows glyph hinting, screen anchors, and the unbounded text raster cache remain
open; this change does not establish exact typography parity.

The pass-fourteen full sweep completed on its older binary: 413 passes, three
known 3D partials, three shader failures subsequently fixed and checked in pass
twenty-seven, and two 90-second timeouts. Current builds render `3497488774`
slowly; `2837642303` still times out at 90 seconds in the pass-twenty-nine
[recheck](../CompatibilitySuite/reports/run_2026-09-12T20-02-52-966829Z_c1072166.json).
The [heavy scene capture](../CompatibilitySuite/reports/pass29-text-metrics/heavy/heavy.png)
shows improved layout but still distorted character meshes, repeated edges, and
placeholder clock/media content. Smoke passes do not establish visual equivalence.


## Web document navigation and teardown (pass thirty)

Authored document navigation now receives the current wallpaper properties and
playback state. Previously only the initial WKNavigation was tracked, so reloads
or `location.href` changes could finish without property or pause delivery. Stop
and immediate restart distinguish the teardown navigation from the new wallpaper;
the injected heartbeat on the stopped blank page is also suspended.

A real WKWebView test covers paused navigation, property updates, resume, and
immediate stop/restart. The stopped-page test waits for actual blank-document
readiness and pause state. All three lifecycle tests and the regular suite pass
(164 discovered across 26 suites; one opt-in local web probe skipped). The frozen
application is `6c9c93dec57cf6b0110853d6c54ae63f49299fb1ffefa475fc475c96b5c6d953`;
scene tool hashes match pass twenty-nine. The known authored syntax error in the
local web wallpaper remains separate from these host lifecycle fixes.


## Scene copy avoidance (pass thirty-one)

Visible image layers now draw onto the existing scene when their final compiled
shader does not sample that scene. Scene-reading blend passes retain separate
input/output textures, as do chains with later commands that may consume the
original input. Hazard detection follows actual sampler reflection and the same
name/path/WE-slot resolution used for drawing; resolution-only uniforms do not
force a copy.

Six new cases cover active versus optimized-out samplers through name, path, and
slot overrides, including WE texture 1 reflected at Metal slot 0. All existing
image/effect/compose/blend pixel cases and the full debug suite pass (165 tests
across 26 suites; one opt-in web probe skipped), plus three shader and three
script fixtures. The frozen debug application is
`debb917c7aa1464aa282a9fd9c54a1f627f8c8beb4dca2b2cdf74504b2ee0ab6`.

AGE `2837642303` now completes the unchanged 90-second debug smoke budget in
87.7 seconds, with no reported shader/script failures. Its measured 0.77 FPS is
still poor. A two-frame fixed-step capture is pixel-identical to the preceding
build across every RGBA channel. The app preset capture also retains the corrected
text and compose-layer output. The standalone snapshot tool does not resolve
published presets; its attempted preset captures report unsupported and were
replaced with an app capture.

[Comparison and profile artifacts](../CompatibilitySuite/reports/pass31-scene-copies/age-pixel-comparison.json)
are retained with frozen build hashes. The debug CPU sample points primarily to
particle simulation/rendering. All eight debug scene lanes complete without unexpected failures. All 165 tests also pass in a fresh optimized release build. Its app hash is
`c381c3d9b7ca9475b5d3d008d292f2b54a9acf4625904b0976f5c9566b0a403b`.
AGE completes in 52.9 seconds at 1.90 FPS (471ms average CPU time) while a debug
canary lane also runs. This is still slow, but the distinction matters: `run.sh`
launches release, while historical canary runs used debug binaries.


## Particle scene copy avoidance (pass thirty-two)

Particle layers now use the same active-sampler hazard check as image layers.
Every material pass and descendant particle system is checked before any part of
the layer is drawn, preserving the original scene for refraction and other scene
reads. Atlas and shader combo preparation is shared between the check and draw.
Ordinary sprite/trail layers render in place without a full-scene texture copy.

Three new pixel cases check scene reads in the first pass, a later pass, and a
child system, across two frames. All 166 tests pass in debug and release (26 suites; one opt-in web probe skipped).
The debug app hash is `5b4e19100b6491be1555e72c0265073d661be7def7280fb06154f45635e72a11`;
the release app is `8870edab83a49551ae2cf50441daaf39f2e3bc45b436071e38db5de3cd725509`.
AGE's fixed two-frame RGBA capture again matches the preceding build exactly.

The release AGE run completes in 41.2 seconds at 2.36 FPS and 373ms average CPU
time; the previous release run took 52.9 seconds at 1.90 FPS. Scene `3497488774`
completes in 60.7 seconds at 1.84 FPS and 509ms average CPU time, versus 66.6
seconds/1.81 FPS/511ms before. These runs overlap another canary lane and are not
isolated performance measurements. Both scenes remain much too slow for parity.
[Pixel comparison](../CompatibilitySuite/reports/pass32-particle-copies/age-pixel-comparison.json)
and separate debug/release build hashes are retained. All eight debug canary
lanes complete without unexpected failures after pass thirty-one.


## CSS and Web Animation playback (pass thirty-three)

Host pause now freezes CSS animations, CSS transitions, and Web Animations as
well as JavaScript timers. Running animations resume from their held time;
animations paused by the author remain paused, while canceled/finished animations
stay stopped. DOM changes and animation API calls catch animations created during
pause. Pending pauses are resolved without requiring a rendered frame, so an
occluded wallpaper does not wait indefinitely for animation readiness.

The new real WKWebView regression reproduced running animations after pause.
It now passes with existing/new CSS animations and transitions, forward/reverse
Web Animations, explicit play/pause, cancellation, finishing, stable held times,
and authored CSS pause changes. All 167 tests pass in debug and release across
27 suites (one opt-in corpus probe skipped). The frozen app hashes are
`7a4dc143b7374f1d4015a6036f717053a4177c1ada2270a5c0f2bf5dda116e76` (debug) and
`95378ed595075608e724f39c61128630b6dda06cf3482ec60d73d4bc7d42b75f` (release).
Scene binaries match pass thirty-two.

This uses WebKit's documented [common animation model](https://webkit.org/blog/10266/web-animations-in-safari-13-1/).
Wallpaper Engine [fully freezes the wallpaper process](https://docs.wallpaperengine.io/web/api/propertylistener)
on Windows; this host implementation does not yet establish that broader contract
for workers, child frames, closed shadow roots, or arbitrary asynchronous work.
Actual mute and the missing media APIs remain open.


## Puppet clip visibility and blend amount (pass thirty-four)

A disabled full-weight puppet animation no longer hides the entire image. Clip
visibility determines whether that pose is applied; node/parent visibility still
controls the image. An authored clip list with no active entry keeps bind geometry
instead of playing its first disabled clip. Fractional blend amounts interpolate
bone poses before skinning, preserving rigid rotations rather than shrinking the
mesh by averaging already deformed vertices. The existing default animation
behavior for a model with no authored clip list is unchanged.

The local heavy scene contains 58 nodes with animation layers, 50 with every
layer explicitly disabled. Six generated MDL pixel cases reproduce visibility
and weight failures; a separate rotation test checks the unit-circle result of
half blending. All 169 tests pass in debug and release across 27 suites (one
opt-in corpus probe skipped), plus three shader, three script, and five Python
checks. The frozen hashes are
`1e734ebd4c74ee042bed68104d2ec71b3f4504a5ed18e1d3c61871d69456475e` (debug app) and
`8f2dfdc3215d76d7893ae3ea2f21b8c6934e8a9141dbc6701277c5f6831f47da` (release app).

This follows the documented [animation-layer visibility contract](https://docs.wallpaperengine.io/en/scene/scenescript/reference/class/IAnimationLayer.html).
Fixed two-frame heavy captures show only the authored startup cover, so they do
not establish a visible improvement. The later release app capture completes in 28.9 seconds and is retained under
`pass34-puppet-visibility/heavy-app`. Visual inspection shows restored foreground
foliage but still malformed character parts, repeated scene edges, and placeholder
clock content. All eight scene lanes complete without unexpected failures. Multiple simultaneous clips, additive blending,
skeletal playback controls, true bind matrices, animated scales, and full 3D
skinning remain incomplete.


## Puppet animation section discovery (pass thirty-five)

The decoder now follows skeleton section boundaries and validates animation
headers beyond controller/constraint metadata. MDLA0006's nominal 35-byte clip
record is recognized. The heavy scene's 53 unique models previously decoded zero
clips; they now decode 1,263, resolving every authored animation reference in its
58 puppet nodes. The generated pixel cases also exercise the second clip beyond
extended skeleton metadata and a misleading non-header string.

All 169 tests pass in debug and release. Frozen app hashes are
`4d0622701787b0d561c77cd1a97b2844866a370ffe1b4838b6d7507a2e23ca9c` (debug) and
`668cd9f7c5b78d5730ee8255fa6d2500175f8bbd6190bf56a7f89ad9294426e7` (release).
The later heavy app capture completes in 29.2 seconds; inspection still shows
malformed character parts, repeated scene edges, and placeholder clock content.
All eight canary lanes complete without unexpected failures.

Broader read-only extraction covers 331 unique skeletal models from the eligible
scene catalog. Compared with 29 clips in 19 models previously, this build decodes
1,608 clips in 288 models. It exposes 34 decode errors in other record layouts
(previously one error, with most affected models silently loading zero clips).
These failures are retained in `pass35-puppet-clips/corpus-after.json` and are the
next parser target. Clip counts establish structural discovery, not correct
motion, opacity, blend composition, or Windows visual parity.


## Variable puppet animation records (pass thirty-six)

Animation records now recognize the minimum trailer for MDLA0001 through 0006
and validate the complete following clip track table beyond optional metadata.
The parser no longer interprets long opacity/channel records or imported sequence
metadata as another animation. Searching is bounded by the declared animation
section; malformed/truncated following tracks fail explicitly. A guessed extra
byte before animation names was removed after checking the corpus layout.

All 331 unique skeletal models now decode without errors, yielding 1,723 clips in
322 models; nine have no animation section. An independent raw-record probe agrees
on every clip ID. GreatWhite's four clips and Waves' single clip now load too,
although direct 3D model rendering remains incomplete. This does not implement the
optional channels that are skipped between pose records.

The 48 generated pixel scenarios span all six record versions, 18-byte sequence
extensions, metadata exceeding 190KB, visibility, blend amount, and selection of
the second clip. Additional cases reject truncated tracks and a section boundary
before the pose data. All 169 tests pass in debug and release across 27 suites
(one opt-in web probe skipped). Frozen app hashes are
`fcba4e727a03b27a10635d05e1a225affb3e2166512fadd5e802cbdd406e3d1b` (debug) and
`8aa2b7e726020c948c8054d2c639d4d31cae9589a8d8667f42561df9f0f97382` (release).
All eight scene lanes complete without unexpected failures after pass thirty-five. Inventory, independent
record measurements, and decoder results are retained under
`CompatibilitySuite/reports/pass36-puppet-records`.


## Stored puppet bind transforms and full bone poses (pass thirty-seven)

Puppet skinning now reads each bone's stored local bind matrix, follows the parent
chain, and applies the inverse world bind matrix. It no longer treats every clip's
first frame as a new bind pose. The decoder retains vertex depth and all nine
pose components. X/Y/Z rotations, translation, and signed scale affect the skinned
image; fractional clip weights blend translation/scale and quaternion rotation
before skinning. Zero animated scale retains its rotation during blending.

Across 322 animated corpus models, 177 have a first pose that differs from the
stored bind matrix, eight use non-unit first-frame scales, and 18 have X/Y
rotation. All parent tables inspected are ordered before their children. The
probe samples all 1,723 clips at three times (5,169 combinations) without decode
errors or non-finite positions. These are numerical checks, not a visual-parity
metric; some authored animations have large displacements requiring inspection.

New unit cases cover bind-versus-first-frame differences, animated non-uniform
scale, parent rotation acting on child depth, vertex depth, zero/negative scale,
and fractional blend. The rendered fixture checks a non-identity stored bind
matrix, while the existing rigid-rotation test still passes. All 172 tests pass
in debug and release across 27 suites (one opt-in web probe skipped), plus three
shader fixtures, three script fixtures, and five Python checks. Frozen hashes:
`a2ae2dbc43f4fb620110bf39750ba2cbc7132767eee1d8a3ce2ec21b531bb701` (debug app),
`22f47a3901f09dbc3ee072a35ad4575278dabc65fe80fac819d9a19a9f33d2ae` (release app).

The later heavy app capture completes in 29.0 seconds and was visually inspected.
Malformed character parts, repeated scene edges, and placeholder clock content
remain; this capture does not establish correct authored composition or motion.
All eight scene lanes completed without unexpected failures. The reports and before/
after deformation measurements are in `pass37-puppet-transforms`.

This remains the puppet image path: it projects skinned positions onto the image
plane and does not implement direct 3D model drawing, depth, or perspective.
Multiple/additive clips, single-shot timing, skeletal SceneScript playback APIs,
constraints, and optional opacity channels are still open. The current image
renderer selects only the first active animation layer. Those limitations must
remain visible while evaluating the newly decoded clips.


## Skeletal animation properties and script owners (pass thirty-eight)

Animation-layer rate and blend now retain user bindings, value scripts, timelines,
and stable runtime keys. Dictionary values previously fell through plain numeric
parsing and often became zero. Missing rate/blend values now use one. Serialized
legacy descriptors preserve their numeric values and gain writable property
bindings when decoded.

Each authored animation layer has a persistent script object with its read-only
custom name. `getAnimationLayer(nameOrIndex)` and `getAnimationLayerCount()` return
these objects in authored order. Property scripts receive the animation as
`thisObject` and its image as `thisLayer`; writes persist and stay independent
between layers. Animation property libraries follow authored scene/layer order.
This follows the documented [image-layer lookup](https://docs.wallpaperengine.io/en/scene/scenescript/reference/class/IImageLayer.html)
and [animation-layer properties](https://docs.wallpaperengine.io/en/scene/scenescript/reference/class/IAnimationLayer.html).

The new tests initially reproduced seven failures. All 176 tests now pass in
fresh debug and release builds across 27 suites (one opt-in web probe skipped),
including legacy decoding, retained references, user changes, correct property
ownership, and script order. Three shader fixtures, three script fixtures, and
five Python checks pass. Frozen app hashes are
`7d64156d1b3a25cf8e2df5960d1ef3ec5ca093fbe180cb6eba178858304e2677` (debug) and
`3e9e199fc0ac4df607ee9283afb715d046c89126e3936574030967f53ac41a80` (release).
An initial legacy-test fixture addressed the wrong serialized nesting; it was
corrected. The initial release attempt detected an edited test file during
compilation; the final unchanged-source rerun passes. All eight scene lanes complete
without unexpected failures after pass thirty-seven.

The later heavy capture completes in 29.1 seconds and remains visibly malformed.
Its local preview shows the intended assembled character. Fifteen scene nodes
have an `attachment` field currently ignored by scene loading/runtime transforms.
The placeholder puppet's MDAT0001 section decodes ten named anchors: a UInt16
count followed by a UInt16 bone index, NUL-terminated name, and 64-byte local matrix
per entry. Their bind origins range from roughly Y=-429 for legs to Y=528 for the
head, substantial offsets absent from child transforms. The section ends exactly
at MDLA. These measurements are retained in
`pass38-animation-properties/attachment-investigation.json`; integrating animated
attachments is a priority alongside playback controls.

Skeletal play/pause/stop/seek, ended callbacks, clip metadata, continuous timing
through rate changes, multiple/additive clip composition, and bone/attachment APIs
remain incomplete. Property access alone does not establish IAnimationLayer parity.
The runtime needs the same decoded skeleton/clip data as rendering to implement
those features consistently; that shared-data change remains to be done.


## Animated skeletal attachments (pass thirty-nine)

The scene loader preserves named and indexed attachments. The shared puppet
model decoder now reads MDAT anchors, and runtime transforms place attached
children at parent-world × animated-bone × attachment-local × child-local.
Descendants inherit that transform. Unknown anchors retain ordinary parenting;
disabling all authored clips uses the stored bind pose. The renderer and runtime
share one scene-scoped decoded model cache, avoiding duplicate asset decoding.
The benchmark tool now supplies the same asset roots as rendering.

The eligible corpus contains 74 attachments across 37 unique models. All 331
unique skeletal models decode successfully with 1,723 clips. Independent MDAT
record inspection agrees with each declared section boundary. New tests cover
named/indexed anchors, animated translation under parent scale and rotation,
descendants, global pause, disabled clips, unknown anchors, and serialization.
All 178 tests pass in fresh debug and release builds across 28 suites (one opt-in
web probe skipped), plus three shader fixtures, three script fixtures, and five
Python checks. Frozen app hashes:
`437dd537d1732361d40eee185ddb7d5311caaf93959ebb6b09883eb693f94c5d` (debug),
`efa2bbf9bae11d38a11e8f8c25bf5e703c9cf3f75a47b2511fc1bd13d0ce1cdc` (release).

The heavy scene app capture completes in 29.0 seconds. Visual inspection shows
the character's previously collapsed head, limbs, skirt, and basket assembled
in their expected relative positions, consistent with the local preview.
Background edge artifacts and placeholder clock content remain. This is a
specific visual improvement, not proof of Windows equivalency. Captures,
inventories, and immutable build manifests are in `pass39-attachments`.
All eight scene lanes complete without unexpected failures.

Attachments currently sample the same first active clip as image skinning.
Multiple/additive clip composition, playback controls, continuous timing, and
SceneScript bone/attachment APIs remain open. Direct 3D rendering remains partial.


## Independent skeletal playback clocks and controls (pass forty)

Authored skeletal layers now integrate their own frame positions. Changing rate
no longer multiplies the entire scene elapsed time, and mesh skinning and attached
children consume the same explicit sampled frame. The decoder retains single-shot,
loop, and mirror modes. Single-shot clips hold their final pose and stop; reverse
playback and seeking preserve their own position. Explicit seeks can reach the
stored endpoint without immediately wrapping it to zero.

Persistent animation objects expose `fps`, `frameCount`, `duration`, `play`,
`pause`, `stop`, `isPlaying`, `getFrame`, and `setFrame`, following the documented
[IAnimationLayer interface](https://docs.wallpaperengine.io/en/scene/scenescript/reference/class/IAnimationLayer.html).
Rate/blend/visibility still use the existing writable property bindings. A hidden
clip continues advancing independently; visibility only controls pose contribution.
Global pause freezes clocks without overwriting their individual playing state.
Script rate changes apply to subsequent frame intervals; user-bound rates refresh
before advancing the current frame. Models unavailable through the configured asset
roots keep the existing elapsed-time fallback and do not invent clip metadata.

All 331 eligible unique models decode without errors. The independent raw record
inventory contains 1,629 loop, 79 mirror, 13 single-shot, and two empty-mode clips
(the latter retain loop fallback). Every clip's bone tracks contain one additional
endpoint sample beyond the declared frame count, now reflected in runtime metadata.
The renderer's single-shot path previously treated these 13 clips as loops.

All 184 tests pass in fresh debug and release builds across 29 suites, with one
opt-in local web probe skipped. Tests cover retained handles, metadata, per-layer
and per-scene isolation, live user/script rate changes, single-shot completion,
reverse/mirror/loop playback, clamped/invalid seeks, exact endpoint sampling,
attachment transforms, and pixel rendering through pause/seek/resume/stop.
Three shader fixtures, three script fixtures, and five Python checks also pass.
Frozen app hashes:
`f150804797efbce39b6047f87886f8b043c490e91861754e3675dbf6da775c80` (debug),
`7fca79c955302d8bd20630a9cd7637bbbc244af54821c85cb7475b1304de3cca` (release).
The scoped diff was reviewed; no production dependency or unrelated refactor was added.

The release heavy-scene capture completes in 29.0 seconds and retains the assembled
character. Background edge artifacts and placeholder clock content remain. Its 97
reported script failures have the same categories/counts as pass thirty-nine; the
new basic playback methods alone do not resolve its wider library/API dependencies.
All eight frozen canary lanes complete without unexpected failures. A new immutable
421-scene release discovery sweep is running, with the four excluded IDs and
excluded directory asserted absent. The discovery sweep is not yet a completed
compatibility result. Artifacts are in `pass40-skeletal-playback`.

Ended callbacks, named animation events, dynamic animation creation/destruction,
multiple/additive clip composition, automatic blend-in/out, constraints, optional
channels, and SceneScript bone/attachment APIs remain open. Direct 3D rendering
and broader application quality-of-life parity are still incomplete.


## Shared-library caller context (pass forty-one)

`thisLayer` and `thisObject` now resolve from the active script owner instead of
being captured as local variables in the wrapper of a shared library. Functions
and constructors exported through `shared` can therefore act on the calling image
or animation layer. Explicitly saved references remain stable objects. Timer
callbacks inherit their dispatching script's context, and shutdown restores each
owner before invoking its destroy callback.

This is grounded in the documented SceneScript globals and the local library's
use of them; no Windows reference execution was available. The heavy wallpaper's
shared sway functions previously searched the library layer for caller animations,
which produced undefined handles. Three new tests initially reproduced seven
failures. Full validation then caught a standalone callback regression, fixed by
restoring the retained callback object before each invocation. A fourth test
covers separate owner contexts during shutdown.

All 188 tests now pass in debug and release across 29 suites (one opt-in local web
probe skipped), plus three shader fixtures, three script fixtures, and five Python
checks. Frozen app hashes:
`bfe98799a36233dda8a3bbc2ba2f2512cd9de52d5ec35889a1b1fbad92c6513c` (debug),
`10d1853e2214c94eeeb81462c37c92487eecbfc73e30e121a82b66483132d131` (release).
The scoped source/test diff is retained in `pass41-scene-call-context/scoped.patch`.
No production dependencies were added.

The heavy release capture completes in 16.3 seconds. Its reported script failures
fall from 97 to 47: undefined animation `.play` handles fall from 52 to two.
The character remains assembled, and additional authored animations now execute.
The image also becomes excessively bright; this changed visual state is unresolved
and must be checked along with background edge artifacts and placeholder clocks.
Capture durations are not isolated performance benchmarks. Before/after failure
lists and captures are retained under `pass41-scene-call-context`.

The remaining script categories are 21 undefined `multiply`, 15 non-function calls,
eight undefined `addTask`, one missing `MediaPlaybackEvent`, and two undefined
`play` handles. The two latter cases likely involve the still-missing ended-callback
interface used by animation scripts to identify their owner; this is a lead,
not a verified diagnosis. Shared engine/input context, named animation events,
ended callbacks, multiple/additive clips, and the other recorded rendering/QoL
gaps remain open. Eight pass-forty-one scene lanes are queued after the pending
pass-forty full sweep to avoid concurrent benchmark load. Those runs are pending,
and this pass does not establish visual parity.


## Bound property scripts and actionable diagnostics (pass forty-two)

An unconditional user-property binding no longer bypasses its attached script.
The current user value supplies the script input, while module initialization,
callbacks, and per-frame updates still execute. This restores shared libraries
attached to user-controlled visibility, including the heavy scene's clock and
media libraries. Subsequent frames retain the script's output; changing the user
property supplies the new input without resetting its module.

The native host implements the documented `console.log` and `console.error`,
converting arguments to strings and joining them with spaces. Authored optional
missing-event reports no longer throw because `console.error` is absent.
Script exceptions retain bounded call stacks with stable scene/property owner
labels; error deduplication uses the original message so dispatcher differences
do not repeat the same failure. A throwing stack accessor preserves the original
error and does not poison later evaluations.

Two binding tests initially reproduced seven issues. All 193 tests now pass in
debug and release across 29 suites (one opt-in local web probe skipped), plus
three shader fixtures, three script fixtures, and five Python checks. Frozen app
hashes are `ccf51134fb240c138954f97556158903adc54b4e7276f7d72925e5cccafbb160`
(debug) and `61ad98adc0021d361378c33bfee3a839d6fb31ec333d1b8ebd21d5275b9972cf`
(release). The scoped diff and initial/updated runtime traces are retained under
`pass42-bound-scripts`. The initial diagnostic build used an incorrect QuickJS
function signature, corrected before successful validation. No dependencies added.

The heavy release capture completes in 15.8 seconds and visibly replaces the
12:34 placeholder with live clock content. It reports 29 script failures, down
from 47: 21 initial parallax-library multiply failures, six undefined animation
play handles, and two missing MediaPlaybackEvent references. Authored missing-event
console messages remain visible. Excessive brightness and background edge
artifacts persist. The capture ran alongside discovery work and is not an isolated
performance measurement. Eight frozen canary lanes are queued after pass forty-one;
they are not yet a completed result. Windows visual parity remains unverified.


## Skeletal animation-ended callbacks (pass forty-three)

Skeletal animation objects implement `addEndedCallback`, as documented by the
[IAnimationLayer API](https://docs.wallpaperengine.io/en/scene/scenescript/reference/class/IAnimationLayer.html).
Playback clocks report end crossings separately from seek/play/pause/stop commands.
Callbacks run in their registering script's frame context after the updated clip
state arrives, so they can observe completion, restart playback, and mutate their
own image or animation layer. Init-only scripts receive their callbacks too.

Registrations made during a callback begin with the next clock interval. A failing
callback does not discard later callbacks or replay completed ones on a retry.
Shutdown clears registrations and pending events. Large intervals keep compact
backlogs, dispatching at most 1,024 callbacks per script per frame. End counting
covers single-shot, repeated loop, and reverse playback. Mirrored clips emit at
the far endpoint once per out-and-back cycle. That interpretation and exact
cross-owner ordering remain unverified against Windows; no reference machine is
available. Named animation events and dynamic clip creation remain separate gaps.

Four initial tests reproduced 13 issues. Seven new tests now cover callback owner
context, restart from completion, animated-property ownership, hidden/paused
playback, seeks/stops, repeated and reverse end crossings, errors, registration
timing, bounded backlogs, scene isolation, and shutdown. All 200 tests pass in
both debug and release across 29 suites (one opt-in local web probe skipped),
plus three shader fixtures, three script fixtures, and five Python checks.
The scoped diff was reviewed and adds no dependencies. Frozen app hashes:
`e83a978cde1386d45ab26e122a2fb688238d3e8ac21a54d9eb277406fbb362d6` (debug),
`6d2d71eed742c3aa7aebcb22a9006959dd242996f16a6db4c874d01d15d2ef6b` (release).

The heavy release capture completes in 16.0 seconds. All six undefined animation
play handles disappear because the authored owner-detection check now recognizes
its skeletal animation object. Reported script failures fall from 29 to 23:
21 initial parallax-library multiply failures and two missing MediaPlaybackEvent
references. Visual inspection retains the assembled character and live clock;
excessive brightness and background edge artifacts remain. The capture duration
is not an isolated performance benchmark. Artifacts and stack traces are retained
under `pass43-animation-callbacks`. Eight frozen canary lanes are queued after
pass forty-two and are not counted as completed results. The 421-scene pass-forty
release sweep is still running. Rendering, SceneScript, direct 3D, media, and
broader desktop quality-of-life parity remain incomplete.


## Direct model geometry and depth (pass forty-four)

Direct `.mdl` layers now render their actual three-dimensional triangles instead
of falling through to image/OBJ geometry. The loader preserves each mesh's
material and creates independent material/script owners for additional sections.
A bounded decoder handles the MDLV0019, MDLV0021 and MDLV0023 layouts found in all
ten eligible local direct models, retaining thirteen material sections, normals,
signed tangents, UVs, UInt32 bone indices and weights. Unsupported layouts and
nonempty mesh metadata remain explicit decoder errors. This inventory does not
establish support for every MDLV variant outside the local corpus.

The native path supplies model/view/projection and normal matrices, model-space
geometry, authored depth testing/writing and culling, plus CPU skinning that keeps
vertex Z and transforms normals/tangents. Shader skinning is disabled after CPU
skinning to avoid applying the palette twice. Static GPU buffers are cached.
Full 3D scenes share depth across models. Models in a 2D composition retain depth
within their own material sections; depth is cleared between layers to avoid
comparing incompatible orthographic and perspective values. This follows the
local composition evidence and remains an interpretation pending Windows
reference rendering. Perspective layers share the 2D pixel plane, including its
FOV override, and their far range includes the camera offset needed for large
scene dimensions. The official [3D model introduction](https://docs.wallpaperengine.io/en/scene/models/introduction.html)
and [custom geometry guide](https://docs.wallpaperengine.io/en/scene/scenescript/tutorial/models.html)
confirm the distinction between 2D pixel coordinates and 3D units.

Eight new tests cover all three binary versions, multiple material sections,
malformed buffers, depth independent of draw order in a 3D scene, camera
translation, mixed projection in a 2D composition, animated depth/blend, 4K
pixel-plane clipping, and per-pass depth-state cache isolation. The last review
regression reproduced incorrect testing and writing when a shared material
reused an earlier pass's depth state; both flags now participate in the cache key. The mixed-projection and large-plane regressions failed
before their respective fixes. All 208 tests pass in debug and release across
30 suites (the opt-in local web probe remains skipped), plus three shader
fixtures, three script fixtures, and five Python checks. No dependency was added.
The scoped source/test diff is retained in `pass44-direct-models/scoped.patch`.
Frozen app hashes are `d6797f0d279227fc25fece5da94bdc55c94835c9eea7f1131539db4e667995b7`
(debug) and `f0936a97643867ce05c08bef8c41e742d12c7b8ac63166c36d01319e43f2f805`
(release).

The initial three real-app captures all completed. The boat capture first showed
only water: the orthographic coral's depth occluded the perspective boat and
sharks. After depth isolation, the boat appears in the final frame and all five
sharks appear at their model stage. The sharks survive the tint (366), Water (477) and Waves (772) stages,
but disappear at Water Depth (645), whose tint and workshop fog effects remain
to be investigated. Reflection `_rt_MipMappedFrameBuffer` and mip information remain unbound;
particle-instance and attachment script calls also fail in this scene. Static
models no longer produce unnecessary puppet-decoder warnings during script
setup. Falling Deeper's shard meshes and Miku StarryRiver's ring meshes render,
but their full visual fidelity is unverified.

`direct_model_scene_canaries.json` retains these three scenes. All three initial release
screenshot/benchmark checks completed with their expected `3d-models` partial
status and no launch/render errors. That build preceded the final cache-key
review fix; final debug/release suites both pass, and all three final release
model checks also rendered and benchmarked with their expected partial status. Nine frozen debug lanes remain queued after
pass forty-three and are not counted as completed results. The
421-scene pass-forty discovery sweep is also still running. All direct-model
scenes deliberately retain `3d-models` partial status: per-model effects,
reflection targets, camera objects, morphs, animation layering and visual
calibration still need work. Broader SceneScript, media and desktop quality-of-life
parity remain incomplete. Application wallpapers remain excluded.


During this pass, the ongoing pass-forty discovery sweep reported a black/flat
capture for `3162163215` (Glow Of City [4K]) despite successful launch and
benchmarking. A targeted rerun on the final pass-forty-four release build rendered
and benchmarked successfully: 2,663,344 visible pixels and mean luminance 24.60.
All four script API errors persist. The original failure is retained; this single
rerun does not establish whether the older failure was intermittent or affected
by intervening fixes. Evidence is recorded in `pass44-direct-models/discovery-followup.json`.


## Scene reflection mipmaps (pass forty-five)

Shaders requesting `_rt_MipMappedFrameBuffer` now receive a separate snapshot
of the current scene with generated mip levels. The renderer prepares it before
opening a draw encoder and reuses its allocation when size/format are unchanged.
Image layers, image effects, text effects, direct models, and sprite/trail
particle materials (including children) use this path. Later layers and later
frames refresh their snapshot. Particle materials share the snapshot captured
before their layer is drawn; exact Windows snapshot timing remains unverified.

Material binding supplies `g_TextureNMipMapInfo` from the texture's highest mip
index, including when the compiler removes an otherwise unused sampler. It
honors authored texture slots, shader defaults, and effect `bind` overrides.
Samplers interpolate mip levels. Generation uses Metal's
[generateMipmaps](https://developer.apple.com/documentation/metal/mtlblitcommandencoder/generatemipmaps(for:))
blit operation and [linear mip filtering](https://developer.apple.com/documentation/metal/mtlsamplermipfilter/linear).
The stock reflection helper's guarded normal-Y inversion now uses Metal's
texture orientation, alongside the existing screen-coordinate adaptation.

Five new GPU tests cover ten renderer/binding combinations, sharp versus rough
sampling, frame refresh, successive reflective layers, optimized-out samplers,
normal orientation, and explicit effect bindings versus previous-chain input.
The initial missing-target tests failed before implementation; the normal-Y
regression independently reproduced sampling the wrong half of the scene.
All 213 tests pass in debug and release across 31 suites (one opt-in local web
probe skipped), plus three shader fixtures, three script fixtures, and five
Python checks. No dependency was added. The scoped source/test diff and logs
are retained in `pass45-scene-reflections`. Frozen app hashes:
`93e04c1cae3858500db27f7aa63bd2d57bdd3cd169ebe912be3858e0b116ff6d` (debug),
`60f7b2704929e22b27d5b380baf22235c47986a5d3de128952e53d3640b5f1fc` (release).

Matching two-frame captures of all six reflection scenes complete on the prior
release and current debug build. Reflection samplers now bind scene dimensions
(2560x1440 through 5120x2160), and all missing-reflection/mip-information warnings
disappear. The images were inspected: boat/shard geometry remains present;
existing blur, dark lighting, composition and script issues remain. Pixel
comparisons are retained but do not isolate wall-clock-dependent script changes.
The six scenes are now a permanent reflection canary catalog. All six release app
screenshot/benchmark checks completed with no render/launch errors: four passed,
and the two direct-model scenes retained their expected partial status. Ten frozen
debug catalogs are queued after pass forty-four and are not counted as completed
results.

The initial water-depth investigation found the boat scene's sampled tint
pixels match its authored multiply/color/alpha formula. No tint change was
justified; the workshop fog and visual visibility of underwater sharks remain
unverified. The reflection fix does not resolve those separate concerns.

The pass-forty 421-scene discovery sweep completed during this pass: 417 passed
its launch/render/benchmark checks, three were expected direct-model partials,
and `3162163215` produced a black/flat frame. Its successful pass-forty-four
rerun remains a follow-up result, not proof the intermittent failure is fixed.
These counts measure automated checks, not full Windows visual fidelity.
Rendering, SceneScript, media and desktop quality-of-life parity remain open;
application wallpapers remain excluded.


## Legacy four-light packing (pass forty-six)

Legacy generic shaders read four light positions and reconstruct the fourth
light's RGB from the W components of three `g_LightsColorPremultiplied` vectors.
The renderer previously put the first three lights' intensities into those W
components, creating a phantom fourth light even with only one visible light.
It also supplied short arrays when fewer than four lights were present.
The binder now packs the actual fourth light's premultiplied color, pads all
unused entries with zeros, and supplies full legacy buffers for unlit scenes.
Modern per-type light uniforms retain their existing behavior.

A GPU regression using the stock consumer layout failed in four of its original
five count cases, recording ten pixel errors. The corrected version passes ten
count/visibility combinations, covering zero, one, three, four and five lights,
hidden-light filtering, intensity multiplication and the legacy four-light cap.
All 214 tests pass in debug and release across 32 suites (one opt-in local web
probe remains skipped), plus three shader fixtures, three script fixtures and
five Python checks. No dependency was added. The scoped source/test diff and
logs are retained in `pass46-legacy-lighting`. Frozen app hashes:
`2e565af90d3c7a01283f8888ccf226dfd5f4022c5f81b2be109f40c383685251` (debug),
`24f50010602fe116ef4a66f8ad538dd7dff1c25631bf3bc5bf8d7100db888d21` (release).

The two scenes with legacy-light fallback warnings (`2961625527` and
`3112097349`) render without those warnings. Their default captures differ from
the prior release only within clock regions. A temporary project copy selects
Sanamisa Splash's authored `backgroundstyle="2"` (Dual Colors), activating its
two lights without changing the Workshop files. Matching before/after captures
show the phantom highlight removed. This confirms the binding correction;
complete lighting fidelity, light-space coordinates and other material effects
remain unverified. All three release app screenshot/benchmark checks pass with
no render/launch errors. The temporary fixture recipe and exact project copy
are retained alongside the reports.

A read-only inventory of all 421 eligible scene descriptions found 92 lights
across 25 scenes: 54 `lpoint`, two legacy `point`, seven `ldirectional`, 17
`ltube` and 12 `lspot`. All these authored type names map to the parser's existing
supported types; this audit did not establish their lighting fidelity. The
previously queued pass-forty-one eight catalogs have now completed with their
expected pass/known-partial results. Pass forty-two is advancing, followed by
the frozen later builds. Ten pass-forty-six catalogs are queued after pass
forty-five and are not counted as completed. Full Windows equivalency remains
open across rendering, SceneScript, media and desktop quality-of-life features.

## Modern scene-light bindings and light-space matrices (pass forty-seven)

The renderer now supplies the scene's `LIGHTS_POINT`, `LIGHTS_SPOT`, `LIGHTS_TUBE`
and `LIGHTS_DIRECTIONAL` compile-time counts. Previously the stock modern light
loops compiled out even when a material enabled lighting. Hidden lights retain
stable array slots with zero colors, so scripted visibility does not change the
compiled uniform layout. `SCENE_ORTHO` follows the scene's projection mode.
The default `SHADERVERSION=62` selects the color/intensity branch present in the
supplied generic3 shaders; an explicitly authored value is preserved. This is
a local shader ABI choice, not a verified current Windows engine version.

Image model matrices now describe authored world coordinates, matching light
positions. Scene centering moves into the view-projection matrix, preserving
geometry placement. Normals use the inverse transpose of the model basis.
Base images rendered through an effect chain use the stock `PRELIGHTING` path
and alternate matrices to retain their world coordinates and full-scene screen
coordinates while drawing into a layer texture. The spotlight cone's two
cosines are packed in the order required by the stock `smoothstep` expression.

The initial real-scene probe exposed a missing `CASTU` shader helper after the
light loops became active. Some layers disappeared despite successful tool
exit codes. Adding the unsigned cast restores those layers; the regression
fixture now uses the actual unsigned loop syntax. The three shader snapshots
were updated only for this header macro; all other snapshot fields are identical.
Six lighting regression methods cover thirteen cases: all light types, dynamic
visibility, world positions, rotated normals, offscreen prelighting, intensity,
and spotlight center/edge attenuation. The original cone test failed with twelve
pixel errors; the unsigned-loop test failed with thirty-six. Both now pass.
All 220 tests across 33 suites pass in debug and release, along with three shader
fixtures, three script fixtures and five Python checks. The optional local web
corpus probe remains skipped because its authored malformed JavaScript was
already isolated; synthetic web tests pass.

`CompatibilitySuite/lighting_scene_canaries.json` retains all 25 eligible scenes
with authored lights. All 25 two-frame debug captures complete without shader
compilation failures or skipped image layers. Visual review confirms the missing
layers return in Ethereal and WLOP piano3. Their existing darkness, orientation
and blur problems remain open. Release app screenshot/benchmark checks report
22 passes, two expected `3d-models` partials, and one failure: Glow of the City
(`3162163215`) is still captured as black. Its four known script errors remain.
This reproduces the earlier intermittent black-frame problem; the pass-forty-four
successful capture did not prove it fixed. Neither clean logs nor a nonblack
screenshot establishes visual parity.

Evidence, manifests, logs, authored light metadata and the scoped diff are in
`CompatibilitySuite/reports/pass47-scene-lighting`. Frozen app hashes are
`d1023e4a17fd25d8a46fd2bfc6fa0ea0e14c5a98fcd3412871732a41e244e542` (debug) and
`8b6bd269106eb79d005091dca7bc746335d6e82589d9268bfe8f4b315b6c1940` (release).
Passes forty-two and forty-three completed their eight catalogs with expected
pass/known-partial results. Pass forty-four stopped on Neon Sunset's unsupported
`MDLV0014` models; the dependent forty-five/forty-six runners exited without
running their catalogs. Eleven catalogs now run on the frozen forty-seven
release, recording failures while continuing so one failure does not hide other
results. They are not counted as complete here.

Further light-geometry work is required. All 17 authored tube lights use
`controlpoint` endpoints, which the loader currently ignores in favor of an
invented length. Directional/spot orientation and inherited parent rotation,
attenuation, shadows, cookies and volumetrics remain unverified or incomplete.
Official [shader variables](https://docs.wallpaperengine.io/en/scene/shader/variables.html)
document the world/effect/layer matrix meanings, and the
[light documentation](https://docs.wallpaperengine.io/en/scene/lighting/lights.html)
describes the two tube endpoints. These references guide implementation; they
are not substitutes for Windows comparison renders. Full parity remains open.

## Legacy direct-model layout and perspective snapshots (pass forty-eight)

Neon Sunset's two `MDLV0014` assets now decode and render. That format stores
its vertex layout in the file header and begins each mesh's vertex buffer
immediately after the material metadata. The newer supported versions instead
include per-mesh bounds and layout values. The decoder now distinguishes these
layouts while retaining vertex/index validation and separate material sections.
The actual grid contains 2,601 vertices / 5,000 triangles, and the sun contains
four vertices / two triangles. Their hashes and decoded counts are retained in
`CompatibilitySuite/reports/pass48-legacy-models/verification.json`.

Existing regressions now include the older format for multiple materials,
truncation, invalid indices, nonfinite coordinates, GPU rendering and depth
ordering. They failed against the old decoder and pass with the format change.
All 220 tests across 33 suites pass in debug and release, with three shader
fixtures, three script fixtures and five Python checks. No dependency or public
model-layout change was introduced. The optional local web probe remains skipped
for the previously documented authored JavaScript error.

The snapshot tool also now falls back to 1920×1080 when a scene has no positive
authored dimensions. Previously these perspective scenes produced 1×1 captures;
the initial before/after images in this report are therefore retained only as
evidence of that tool defect, not visual validation. Corrected debug and release
captures have verified dimensions, identical pixels, visible sun/grid geometry,
and no skipped-model or shader-compilation errors.

The restored geometry exposes a separate transparency issue: the sun is drawn
before the grid and its transparent rectangle writes depth, leaving a rectangular
hole in the grid. Transparent 3D sorting/composition remains incomplete, so
`3d-models` partial status is preserved. Sample and direct-model application
catalogs are queued after pass forty-seven's eleven catalogs; they are not yet
counted as completed. The frozen final app hashes are
`ac40dc6491080083ff3e571b72e2526e565dd9df7854832c5382d8b7f88130e0` (debug) and
`d2158f007cfbfb1f838750bfa046e9741484483834b62ddcf5dcfdb0fcd9e55e` (release).
Use the `pass48-final` tool paths for the corrected snapshot dimensions; the
earlier `pass48-bin` snapshot executable predates that tool fix.

## Transparent model composition (pass forty-nine)

Neon Sunset's transparent sun no longer writes a rectangular hole into the grid.
Perspective scenes now draw opaque model sections first, then translucent and
additive sections from far to near using each section's transformed geometry
center and camera direction. This also handles multiple materials within one
model and rotated cameras. Material passes retain their ordering, explicit
texture dependencies take precedence, and painted layers/fullscreen effects
separate model batches. The 2D composition path keeps its existing paint order.

Two new test methods cover eight opacity/order/camera combinations and a
framebuffer producer-consumer dependency. The corrected opacity fixture fails
with twelve pixel mismatches before the renderer change and passes afterward.
All 222 tests across 33 suites pass in debug and release, alongside three shader
fixtures, three script fixtures and five Python checks. The optional local web
probe remains skipped for its previously documented authored JavaScript error.
Debug and release Neon captures are 1920×1080 with identical pixels. The sample
and direct-model app catalogs complete with two passes and four expected
`3d-models` partials, no unexpected failures or skipped layers. Sorting material
sections does not yet solve intersecting transparent triangles or establish
complete 3D support.

Evidence and the scoped diff are in
`CompatibilitySuite/reports/pass49-model-transparency`. Frozen application hashes
are `0205578f43bd88f19ba1e5f750827e14687281d6052f32712d68f9d5694e111b`
(debug) and `833aa88724c217c25a2e7641f21c570f51fef7758796c8f37718534c2eb5e3e3`
(release). Previously queued pass-forty-seven validation has also completed:
85 overlapping checks, 73 passes, 11 expected partials and the single legacy Neon
failure subsequently fixed by pass forty-eight. Pass forty-eight's two catalogs
completed with two passes/four expected partials and no errors.

Glow of the City's black startup now has an authored explanation. With its
default intro enabled, a brightness animation remains near -1 for five seconds
and reaches 0 at six seconds. Controlled snapshots at 0.033 and 8 scene seconds
show black and visible output respectively. The previous frame-count captures
varied with render speed, explaining their different black-frame results.
The eight-second probe uses coarse timesteps and is evidence for the property
timeline only. Capture scheduling still needs a scene-time threshold, while
this scene's known script errors and visible text/quality differences remain.
Full Windows parity is still unverified and incomplete.

## Captures after authored intros (pass fifty)

The app accepts `--screenshot-time`, and fixture catalogs can request it with
`screenshot_time`. Both the frame-count threshold and minimum elapsed scene
time must be reached before saving a motion-reference frame. The final capture
follows 24 frames later. Scheduling uses the runtime packet's clock, so asset
loading, skipped drawables or a longer subsequent benchmark do not substitute
for scene playback. Capture sidecars record both timeline positions and the
rendered frame count. Existing fixtures retain their zero-time default.

Glow of the City's two catalog entries now request seven seconds, based on its
six-second authored brightness intro. Debug captures record reference/capture
times of 7.000/8.800 seconds; release records 7.035/8.635. Both render checks pass.
Its four known script API errors remain visible as `issues_detected`; text and
overall visual quality still require work. The fixture change neither disables
the intro nor exempts black or flat frames from failure.

224 Swift tests across 34 suites pass in debug and release, with seven Python
checks. Tests cover independent frame/benchmark settings, invalid or nonfinite
thresholds, forwarding the option and retaining black-frame failures. The scoped
diff, manifests, logs and app reports are in
`CompatibilitySuite/reports/pass50-capture-timing`. Frozen app hashes are
`79537311431e81e33445508f2b7d32c7cdc8dcb21def87510d3c90c403a8ed9d` (debug) and
`df6b6ca0524e99acdb4ff4a6085ca777af7366a810032e9edffee80521be654a` (release).
The opt-in local web probe remains skipped for the documented authored syntax
error. Sample, workshop and direct-model release catalogs completed: 26 checks,
22 passes and four expected `3d-models` partials, with no unexpected failures.
Full Windows equivalence remains open.

## Authored tube-light endpoints (pass fifty-one)

The renderer now uses authored tube `controlpoint` offsets instead of inventing
a centered segment of length 100. The loader preserves controlpoints and light
scale, SceneScript exposes both properties, and runtime evaluation transforms
the animated endpoint through the light and its parents. Shader uniforms use
the light origin and resulting endpoint. This applies to 17 tube lights in nine
eligible scenes. Older serialized descriptors and scenes lacking controlpoints
retain the existing length fallback.

The GPU regression originally produced 18 pixel errors and could not assign
`thisLayer.controlpoint.x`. All four static/scripted start/end cases now pass.
Additional tests cover timeline animation, pause/resume, parent rotation/scale,
frame serialization and legacy decoding. Fresh debug and release builds each
pass 227 tests across 35 suites, plus three shader fixtures, three script
fixtures and seven Python checks. The optional local web probe remains skipped
for its documented authored syntax error.

Matching two-frame local snapshots show Relax Cafe's complete illuminated sign
where only part was lit before. Debug and release pixels match in all three
probes, without skipped layers or shader failures. Beyond and Odyssey are
unchanged at this early time. Scene inspection identifies opening animations:
Beyond has moving camera panels and a ten-second blur fade; Odyssey has a
four-second black solid fade. The four release catalogs completed with 51 checks:
45 passes and six expected `3d-models` partials, with no unexpected failures.
All six 360-frame captures at 1/30 second completed without render errors.
At 12 seconds, Relax Cafe retains its corrected complete sign; Beyond and
Odyssey are pixel-identical before and after this fix. Visual inspection still
shows Beyond's overexposed foreground and Odyssey's displaced panels/dark
subject. These are unresolved quality gaps, even though capture checks pass.

Artifacts and the scoped diff are in
`CompatibilitySuite/reports/pass51-tube-endpoints`. Frozen app hashes are
`b5f0965cce26cac9c2c31bf0a150d00ca8e4694052aa9e8e67e3c245bbf11e6a` (debug) and
`caeae2e4948db85b2105f8c0f01e0e894ce97d512c561f9e16deaf64b192e056` (release).
The official [light guide](https://docs.wallpaperengine.io/en/scene/lighting/lights.html)
describes the two endpoints and animation support. Endpoint geometry does not
complete attenuation, directional orientation, shadows or full visual parity.

## Authored 2D camera zoom (pass fifty-two)

The loader and runtime now retain `general.zoom`, including property links,
timelines and bound scripts. Frame packets carry evaluated magnification; old
serialized packets default to one, and invalid/nonpositive zoom falls back to
one. Images, material sprites, rope particles, text and embedded models apply
it in the camera projection without changing layer or light world coordinates.
Prelighting retains the projected screen UVs, while text effects composite with
zoom once. Text and rope draws share the scene projection, including automatic
viewport sizing and the existing camera-eye translation. Full 3D scenes ignore
this setting, consistent with the official
[camera transform reference](https://docs.wallpaperengine.io/en/scene/scenescript/reference/class/CameraTransforms.html).

The eligible 421-scene audit found 36 nonunit literal values, five animated
settings and five user-property links. Those 46 entries are retained in
`CompatibilitySuite/camera_scene_canaries.json`. No excluded wallpapers were
opened. Fresh debug/release builds pass 235 tests in 36 suites; three shader
fixtures, three script fixtures and seven Python checks also pass. The new
GPU regressions fail before implementation and pass after correcting the test
fixture's particle size and clear color. Coverage includes zoom in/out, image
world lighting, prelighting UVs, text copy effects, auto projection, sprite/rope
geometry, 2D perspective models, 3D exclusion, script/timeline control,
pause/resume and old serialized data.

Four matching local before/after capture pairs change as expected, and every
new debug capture is pixel-identical to its release counterpart. All eight new
captures complete without skipped layers or shader/script failures. They probe
Moon Kiss, Summer Railway, Sunset Location and Beyond at recorded simulation
times, including active zoom animations. Summer Railway's wider view exposes
an album-cover rectangle backed by the unavailable `$mediaThumbnail`, plus a
gray bottom edge associated with its existing camera-eye translation. These
remain integration/quality issues; the captures do not establish visual parity.
Camera paths, dynamic camera-transform APIs and cursor world projection remain
open as well.

Samples, workshop, direct-model, lighting, text and camera release catalogs
completed 100 checks. Two fail: the same scene, Alone (`3371714429`), captures
almost solid white in the lighting and camera catalogs. The other results
include the expected 3D partials; see `catalog-validation.json` and
`completed-catalog-summary.json`. A normal 480-step capture remains white at
16 seconds, after the authored blur intro, so the failure is not waived as
capture timing. The same directory contains scoped diffs,
logs, before/after pixels, corpus settings and next-investigation evidence.
Frozen app hashes: `67f49f4f277706e7df8c7b608aa94d52aa4fda70def59843e86f3ba98e7cb98c`
(debug), `c456b0dc95fd2ac62ef84e40ccb28dc4ae010aa4c49ff9ec0f413fcc5b80de46`
(release). Full Windows equivalence remains active.

## Image material instances and named textures (pass fifty-three)

Each image now applies its authored `instance` texture slots, shader combos
and constants to its referenced material without changing sibling images.
Named bindings retain their category: user selections resolve as textures,
unavailable media thumbnails are transparent, and shortcut properties keep the
authored image fallback. System textures and shortcut icons are reported as
partial support; OS media providers and callbacks are still missing.

The eligible 421-scene audit contains 292 image instances in 85 scenes, now
listed in `CompatibilitySuite/instance_scene_canaries.json`. Debug and release
pass 237 tests in 37 suites, three shader fixtures and three script fixtures;
seven Python checks pass. The new GPU regression exercises overrides, sibling
isolation, live constants and four binding types with and without effects.
Older serialized bindings still decode.

All three real debug/release capture pairs match exactly. Summer Railway's
unavailable-media rectangle disappears, while the gray camera edge remains.
The shortcut scene keeps its authored fallback. Newly active material and media
bindings in `3042793806` change the image substantially; dark content and
displaced panels still require investigation. This is not a Windows-verified
visual improvement. Samples, workshop, models, lighting, text and instances
catalogs completed 139 checks: 49 pass, 89 known partials and one Alone white-frame
failure. All 85 instance entries render without reported errors, which did not
detect Fallen Tower's visual regression. Pass 55 isolates its foreground-bird
composition instance. The Alone failure was retained for the pass 54 fix.

Artifacts, reproduction commands and the scoped diff are in
`CompatibilitySuite/reports/pass53-material-instances`. Frozen app hashes:
`f033a53c5082f9e7644f4d6ffb9cdda8d74a861a7aa1c0e96ff53102df097f41`
(debug), `03c73ad788b3a7d9b1fe8eef0bd518e56112105f74bd0f0b1789c13af0bb2bac`
(release). Full equivalence remains open.

## Modern light radius and falloff (pass fifty-four)

Alone's almost-white capture was caused by lighting, not its intro or bloom.
The external generated LightingV1 shim squared brightness, discarded authored
falloff exponents and used a spotlight cone cosine as its radius. The supplied
modern PBR helper accepts radius/exponent attenuation; the older helper uses
inverse-square attenuation. A controlled temporary shader probe using linear
brightness and the authored exponent restored the city image.

The native shader preprocessor now supplies its own `#require LightingV1`
library. Authored `#include` contents remain separate. Point, spot and tube
lights receive independent radius/exponent uniforms; all light types apply
linear brightness in this library. Legacy shader uniform packing is preserved.
The loader, property/script runtime and frame packets retain animated exponents,
with a default of two for old data. Degenerate tube segments and equal spot
cones are handled. Shadow-casting lights now report `light-shadows` partial
support. Four authored lights in the 25-scene lighting catalog request shadows.
Shadows, projected cookies, volumetrics and full directional orientation remain
open. Exact Windows brightness is not established by this inferred local ABI.

Debug and release pass 241 tests in 38 suites, three shader fixtures and three
script fixtures; seven Python checks pass. Fifteen normal-step before/after and
release captures complete without logged render errors. At 16 seconds Alone
retains detail. At 12 seconds Beyond's previously white foreground character
is restored, while rotated black corners remain. Relax Cafe has a brighter
interior but still shows crisscross red particles. Odyssey's displaced panels
remain. Four debug/release pairs match exactly; a repeated release capture also
shows small localized variation in Relax Cafe, so it is not claimed identical.
The five app catalogs completed 54 checks against the frozen release build:
36 pass and 18 expected partials, with no unexpected failures. The original
Alone white-frame failure is resolved in the lighting app catalog.

Evidence, scoped source diffs, diagnostic variants and commands are in
`CompatibilitySuite/reports/pass54-lighting-investigation`. Frozen app hashes:
`a61b5fea83e72537675ee4ff10b6bb61c4e3d586fd4b3ffd9f0cef09fe8d5bb0`
(debug), `8ad64f13dc74298d336a84cbf328faeb1a9bfab37b9fe1cbfb67c8d475ed0fd9`
(release). Full rendering and QoL equivalence remains active.

## Hidden composition capture ordering (pass fifty-five)

Fallen Tower's foreground-bird instance exposed a hidden-layer ordering bug:
its composition producer captured later backgrounds because it was rendered
only when the consumer requested it. The pass graph now determines all required
nodes first and keeps their authored order while enforcing dependencies. Hidden
layers that are not needed remain excluded. Removing the bird instance alone
isolated the problem; media fallback and the separate hidden PBR instance were
ruled out by pixel-identical diagnostic variants.

Debug and release pass 242 tests in 38 suites, three shader fixtures and three
script-host fixtures. Seven Python checks pass on retry; the initial 0.5-second
timeout fixture failed to start under concurrent load, and its log is retained.
The graph and GPU regressions reproduced 13 assertions before the fix, then
passed with visible/hidden composition layers, intervening scene layers, zero
to two effects and two frames.

All 12 native before/debug-after/release captures complete without logged errors.
All four debug/release pairs match exactly. Fallen Tower's bright floating island
scene is restored; Summer Railway, Odyssey and Alone are unchanged. Existing
camera edges and Odyssey's displaced dark image remain unresolved. The six
release app catalogs completed 139 checks: 48 pass and 91 partial, without
capture failures. Script errors occur in 66 checks (including overlapping
catalog entries); these remain functional gaps despite successful rendering.

Evidence, scoped changes and commands are in
`CompatibilitySuite/reports/pass55-composition-order`. Frozen app hashes:
`ad5ff3fbb4f854504247a88a5175760533f2b76504052a81610bd575ae491c7c`
(debug), `13c0211159063863f802c24d4ad3a3a9a0ac57b011c4d59e48b49831791bc478`
(release). Application wallpapers are excluded. Full rendering/QoL equivalence
remains active, without a Windows reference machine.

## Static 2D camera view transforms (pass fifty-six)

The native renderer applied the orthographic projection's eye translation but
omitted the paired view matrix used by the local reference renderer. Adding
that view restores offset cancellation for forward-facing 2D cameras and honors
camera roll. Embedded models now share this convention, while full 3D camera
translation remains intact. Degenerate view axes have a finite fallback.

The safe 421-scene audit found 171 static 2D cameras with nonzero eye components,
including 133 with X/Y offsets. A dedicated camera-view catalog records them.
Debug and release pass 245 tests in 38 suites, three shader fixtures and three
script-host fixtures. Eight Python checks pass after removing the cleanup test's
0.5-second startup race and adding a timeout-before-startup case. Camera tests
cover images/effects, text, particles, models, roll and degenerate axes. The
initial text zoom fixture incorrectly tilted the camera; its target was fixed
without weakening its assertions. Failure logs are retained.

All 18 before/debug-after/release captures complete without skipped render
layers. A separate log audit retains one Falling Deeper script error and two
Fallen Tower renderer fallbacks in all three phases.
Summer Railway's gray bottom edge, Odyssey's large offset and Fallen Tower's
black border disappear. Odyssey remains dark; Beyond's rotated black corners
are unchanged. Four debug/release pairs match exactly. Falling Deeper differs
by at most two channel levels over a few mesh pixels; Miku differs in its live
clock/FPS displays. These results do not establish Windows visual parity.

Six release app catalogs are now running 225 checks, including the 171 camera
view scenes. The prior pass's app instance catalog completed first. Script
errors and renderer fallbacks are recorded separately from capture outcomes. Evidence,
commands and scoped changes are in
`CompatibilitySuite/reports/pass56-camera-investigation`. Frozen app hashes:
`e8c355bc682722ed0c874b3c0ecf278e529703d7af7c85fe591cafbf4b66a2e5`
(debug), `3f35b55b1c265970d77e5b87b30100bc1f117f54675465963fb8109b74f82199`
(release). Full rendering/QoL equivalence remains active; application wallpapers
remain excluded.

Pass 56 app validation completed: 225 checks across six catalogs, with 171
pass and 54 declared partial, no capture failures. Runtime diagnostics retain
script errors in 49 checks and renderer fallbacks in eight; catalog entries
overlap, and successful capture is not functional equivalence.

## Pass 57 — particle instances, density and simulation rate

Exposed retained `layer.instance` objects and correct instance script ownership.
Count now controls emission, including zero/fractional density; rate controls
integrated simulation, motion, aging and time-based effects, including children.
Ten new behavioral tests bring debug/release totals to 255 tests in 39 suites.
Both frozen builds pass three shader and three script-host fixtures; eight
Python checks pass. Initial sandboxed GPU tests were rerun with Metal access.

The safe audit identified 2,838 affected particle nodes across 323 scenes.
Twelve native captures complete; Odyssey's excessive bokeh density drops to its
authored factor and Falling Deeper's count error clears. Two debug/release pairs
are identical; the other two retain sparse mesh/effect differences. Control-point
writes now reach an instance object but still do not affect simulation, so their
absence from script-error logs is not evidence of functional support. Three boat
scene function errors and eight VHS/media errors remain. Odyssey's background
darkness is unresolved. Seven release app catalogs, 382 checks, are running.
Details and reproductions: `CompatibilitySuite/reports/pass57-particle-instances`.

## Pass 58 — particle control-point bindings and coordinate spaces

Bound all eight instance control points to the simulator, including Vec3 component
writes, user properties, scripts and timelines. World/pointer points use the full
inverse layer transform; point zero remains the system origin. Older serialized
descriptions keep writable offsets. Nine new tests bring both full suites to 264
tests in 40 suites. Both builds pass three shader and three script-host fixtures;
eight Python checks pass. Source hashes and all-product builds were verified.

The eligible asset audit found 564 nodes in 201 scenes. Eight new snapshots plus
four reused baselines complete; two debug/release pairs match exactly. The boat
trail positions now react to world-space points, but missing attachment queries
still produce white patches and three script failures. This is incomplete visual
support. VHS retains eight unrelated API/media errors. No snapshot tests cursor
movement; focused fixtures cover pointer coordinates with parent transforms.
Seven release app catalogs, 260 checks, are queued after pass 57. Child inheritance
and event-child coordinate behavior remain open. Reproduction and captured
limitations: `CompatibilitySuite/reports/pass58-particle-control-points`.


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


Pass 57's seven release app catalogs have now completed: 382 checks, 277 render
passes, 105 declared partials and no unexpected capture failures. There were
script diagnostics in 95 checks and renderer fallbacks in 18 checks. Catalogs
overlap, so these are not unique-scene counts or a full quality certificate.
The pass 58 driver has advanced from its wait into the app catalogs.


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


## Pass 61 — script owner execution order

Layer components now execute with their owning layer in authored order, preserving
numeric component indices. This removes first-frame shared-data errors and
one-frame delays when later layers consume material, effect, skeletal or particle
scripts. Four new tests fail against the previous scheduling and pass with the
fix. Debug/release suites each pass 285 tests in 44 suites; both frozen builds pass
three shader and three script fixtures, and eight Python tests pass.

The inline component-script audit covers 147 scenes, 719 nodes and 1,468 scripts.
Twelve new snapshots complete without skipped layers or binder fallbacks. VHS's
first-frame color error is gone in both builds, leaving its media-event error.
Odyssey, boat and sphere remain pixel-identical; other differences include known
sparse mesh/effect variation and clock/FPS text. Clipped text and red-line artifacts
remain. Saved placeholder text bounds are a concrete follow-up investigation.
Seven app catalogs, 206 overlapping checks, are queued after pass 60. Full Windows
parity remains incomplete. Evidence: CompatibilitySuite/reports/pass61-script-owner-order.


## Pass 62 — measured text layout and alignment

Text rasterization now measures the current string/font, applies explicit
width/row limits and ellipsis, and anchors the quad using its alignment through
effect chains. Saved placeholder dimensions no longer clip dynamic dates/days.
The texture cache retains only the latest value per layer, avoiding one retained
texture for every past clock value. Five new tests bring debug/release totals to
290 tests in 44 suites, all passing; both builds pass three shader and three script
fixtures, plus eight Python checks. No production dependencies were added.

The safe audit found 1,621 text nodes in 240 scenes, with 1,383 dynamic nodes.
Sixteen new captures and two extra baselines complete without skipped layers or
binder fallbacks. VHS and fireworks now display complete day/date strings; the
sky canary's Chinese weekday is restored. Four scene pairs remain pixel-identical.
VHS's existing media-event error and red-line artifacts remain. Live SceneScript
text styles/size queries, anchors, perspective text and other parity gaps remain.
Seven app catalogs (299 overlapping checks) are queued after pass 61. Evidence:
CompatibilitySuite/reports/pass62-text-layout/REPRODUCTION.md.

Pass 63 connects live text styles and synchronous SceneScript size reads to the
renderer. Font, padding, alignment and width/row controls now use normal script,
user-property and animation bindings. A shared Core Text layout engine gives the
runtime, scripts and Metal renderer the same current dimensions. Old serialized
text descriptions retain their defaults. Empty/zero-size text and oversized
measurement recovery have regression coverage. Eight new tests bring both full
Swift suites to 298 passing tests in 45 suites; shader/script fixtures and eight
Python tests pass. All 30 local before/debug/release snapshots complete with no
new diagnostics or visible regressions. Exact Windows text metrics and padding
semantics remain unverified. Seven app catalogs (299 overlapping checks) are
queued after pass 62. Evidence: CompatibilitySuite/reports/pass63-live-text/REPRODUCTION.md.

The pass 58 particle-control-point catalogs also completed: 260 checks, 183
render passes, 77 declared partials and zero unexpected capture failures. 68
checks retain script errors and 12 retain renderer fallbacks; these counts are
overlapping checks, not unique wallpapers or full-parity results.


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


Pass 61’s app catalogs completed: 206 checks, 105 render passes, 101 declared
partials and zero unexpected capture failures. Script errors remain in 86 checks
and renderer fallbacks in six. These are overlapping checks using the frozen
pass61 build, not unique wallpaper counts or a full-parity certificate.


Pass 66 separates scene initialization from initial property/media/timer/frame
callbacks, preserves scalar script-property strings, and implements live
`setParent` with detach, transform adjustment, visibility and puppet attachments.
Thirteen new tests bring both complete Swift suites to 329 passing tests in 49
suites. Both shader/script fixture sets and eight Python tests pass. All 20 final
debug/release canary snapshots complete with zero runtime script errors, skipped
layers or renderer fallbacks. The initialization canary drops from 21 runtime
errors to zero, including a separate first-frame check; ten authored console errors
remain. Its artwork stays visually stable, with only a one-level RGB difference
outside the changing clock. Broader lifecycle sequencing and Windows fidelity are
still unverified. Seven app catalogs, including all 421 approved scenes (480
overlapping checks), are queued after pass65. Evidence and limitations:
CompatibilitySuite/reports/pass66-scene-initialization/REPRODUCTION.md.


Pass 67 input/package checkpoint is locally accepted: both full Swift suites pass
341 tests, shader/script fixtures and eight Python checks pass, and the deduplicated
59-workshop plus three-sample app run has no unexpected capture failure (42 passes,
20 declared partials). Both prior package-load failures now pass in the app lane.
Eight scenes retain script errors and two retain renderer fallbacks. Ten final
no-input snapshots have no diagnostics; six exactly match pass66 and four differ
only in clock/FPS regions. Eight deterministic input captures complete; one hand
visibly responds, two scenes are unchanged and one differs only in clock text at
default settings. These do not verify physical desktop delivery or full authored
interaction. Windows fidelity and known visual defects remain open. Evidence:
CompatibilitySuite/reports/pass67-cursor-input/REPRODUCTION.md. Old pass62–66
schedules remain retired; the 362-scene integration remainder is not started.


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

The 358 disjoint milestone remainder is prepared in pass70-integration-sweep with
serial execution, immutable source/binary provenance and per-fixture resume. It
completes the existing 421-scene accounting with the 63-scene representative
result. Separate dependency-aware preset canaries remain outside that accounting.

## Frozen70 whole-corpus capture checkpoint

The pass70 integration sweep is complete and review-accepted for local capture accounting: its exact representative63 + remainder358 union contains 421 eligible workshop scenes, with 327 pass and 94 declared partial captures. There were no unexpected capture failures or skipped layers; 35 script-error IDs and 14 renderer-fallback IDs remain retained diagnostics. Three local samples are separate (2 pass / 1 declared partial). This is not Windows-reference, visual, interaction, authored-control, audio, or resource-performance acceptance. At that checkpoint, pass71 sound validation was pending; its completed result follows. Evidence: `CompatibilitySuite/reports/pass70-integration-sweep/verification-summary.json`.


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


## Pass 101 — script visibility completion (September 26, 2026)

The interrupted explicit-visibility fix is complete with bounded local acceptance.
Script-written booleans take precedence over saved combo conditions, restoring
3326873240's automatically selected background while preserving ordinary bindings,
value-script lifecycle and inherited parent visibility. The existing implementation
and three regression tests required no additional production edit in the completion
session. The saved negative run fails all three new tests; the resumed focused run
passes 59 tests. Both full configurations pass 537 executed tests in 91 suites
(543 registered, six existing opt-ins skipped), and shader/script fixtures pass.

Six original-scene mode configurations retain exactly one background over 18 frames.
The three samples, 25 established workshop canaries and affected original complete
29 reviewed native captures: 22 pass, seven declared partials, no unexpected
failures or added diagnostics. The original's night background is visibly restored;
its unrelated authored `scene`-global error remains. Original inputs are unchanged.
This is not a new full-corpus sweep, Windows comparison or live UI persistence
acceptance. Evidence: [pass101 completion report](../CompatibilitySuite/reports/pass101-script-visibility/README.md).
No commit was created. Work stopped after pass101 as requested.
