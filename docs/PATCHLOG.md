# PATCHLOG

Generated: 2026-04-03
Scope: `linux-wallpaperengine` working tree against upstream submodule commit `cb0a0f6e1e9a77f93ac702e15a5bd38acf931a88`

## Summary

### Scope

- Tracked files modified: 39
- New macOS-specific files: 16
- Total divergent files inventoried: 55

### By Intent Category

| Category | Count |
| --- | ---: |
| `metal-backend` | 23 |
| `input-injection` | 6 |
| `embedding-support` | 5 |
| `parser-fix` | 5 |
| `runtime-fix` | 5 |
| `shader-compat` | 4 |
| `platform-guard` | 4 |
| `audio-injection` | 2 |
| `other` | 1 |

### By Destination Module

| Destination | Count |
| --- | ---: |
| `NativeSceneRenderer` | 27 |
| `NativeSceneBridge` | 13 |
| `NativeSceneCompatibility` | 9 |
| `NativeSceneCore` | 5 |
| `delete` | 1 |

### Risk Distribution

| Risk | Count |
| --- | ---: |
| `high` | 21 |
| `medium` | 22 |
| `low` | 12 |

### Highest-Risk Divergences

1. `Render/Objects/Effects/CPass.*` plus `CPass.mm`: the fork now owns both the draw dispatch and a full Metal render-pass path, including manual uniform and texture binding.
2. `Render/Shaders/GLSLContext.*` plus `Render/Shaders/ShaderUnit.*`: shader compilation is no longer upstream-equivalent; it now includes MSL emission, slot reflection, `#require` loading, and sanitizer passes for malformed workshop shaders.
3. `Render/CTexture.*` plus `CTexture.mm`: texture upload behavior diverges in both correctness fixes and Apple-specific Metal paths, with video textures explicitly unsupported on Metal today.
4. `Render/Wallpapers/CScene.*` plus `Data/Model/Object.h` and `Data/Parsers/ObjectParser.*`: the fork added light-object parsing and runtime light arrays before upstream extraction work exists.
5. `Render/Objects/CParticle.cpp` plus `Render/Objects/Effects/CPass.*`: the fork now owns a Metal particle path with custom indexed geometry buffers and per-attribute bindings, which fixed a previously black-frame fixture but remains renderer-critical code.

## Modified Tracked Files

| File | Change | Category | Destination | Risk |
| --- | --- | --- | --- | --- |
| `src/WallpaperEngine/Application/ApplicationContext.cpp` | Added an embedding constructor that bypasses argv parsing and seeds wallpaper path, assets path, viewport size, audio, and mouse defaults directly. | `embedding-support` | `NativeSceneBridge` | `medium` |
| `src/WallpaperEngine/Application/ApplicationContext.h` | Declared the new embedding-focused `ApplicationContext` constructor. | `embedding-support` | `NativeSceneBridge` | `medium` |
| `src/WallpaperEngine/Application/WallpaperApplication.cpp` | Added Apple guards around browser and PulseAudio setup, introduced `setupForEmbedding`, exposed `getRenderContext`, and left screenshot capture unimplemented on the Apple path. | `embedding-support` | `NativeSceneBridge` | `high` |
| `src/WallpaperEngine/Application/WallpaperApplication.h` | Declared the embedding setup API and render-context accessor used by the host app. | `embedding-support` | `NativeSceneBridge` | `medium` |
| `src/WallpaperEngine/Audio/AudioContext.h` | Swapped the PulseAudio recorder include for the base recorder on Apple builds. | `platform-guard` | `NativeSceneCompatibility` | `low` |
| `src/WallpaperEngine/Audio/Drivers/Recorders/PlaybackRecorder.cpp` | Added `injectBands` to resample externally supplied frequency data into the upstream 16/32/64-band buffers. | `audio-injection` | `NativeSceneBridge` | `medium` |
| `src/WallpaperEngine/Audio/Drivers/Recorders/PlaybackRecorder.h` | Declared the external audio-band injection API. | `audio-injection` | `NativeSceneBridge` | `low` |
| `src/WallpaperEngine/Data/Model/DynamicValue.cpp` | Changed `vec3 -> vec4` promotion to use `w = 1.0` instead of `0.0`. | `runtime-fix` | `NativeSceneCompatibility` | `medium` |
| `src/WallpaperEngine/Data/Model/Object.h` | Added a native `Light` object model and supporting `LightType` and `LightData` structures. | `parser-fix` | `NativeSceneCore` | `high` |
| `src/WallpaperEngine/Data/Model/Property.h` | Changed text-property updates from a hard exception to a logged no-op for read-only labels. | `runtime-fix` | `NativeSceneCompatibility` | `low` |
| `src/WallpaperEngine/Data/Model/Types.h` | Added the `LightUniquePtr` alias so light objects can participate in the model graph. | `parser-fix` | `NativeSceneCore` | `medium` |
| `src/WallpaperEngine/Data/Parsers/ObjectParser.cpp` | Added parsing for `light` objects, mapped multiple light kinds, and promoted unsupported light payloads to better diagnostics. | `parser-fix` | `NativeSceneCore` | `high` |
| `src/WallpaperEngine/Data/Parsers/ObjectParser.h` | Declared `parseLight`. | `parser-fix` | `NativeSceneCore` | `medium` |
| `src/WallpaperEngine/Data/Parsers/WallpaperParser.cpp` | Made orthographic projection optional, defaulted missing dimensions to auto behavior, and raised the default near plane. | `parser-fix` | `NativeSceneCore` | `medium` |
| `src/WallpaperEngine/Input/Drivers/GLFWMouseInput.cpp` | Added external normalized cursor injection while preserving the original GLFW polling path when no injected position is present. | `input-injection` | `NativeSceneBridge` | `medium` |
| `src/WallpaperEngine/Input/Drivers/GLFWMouseInput.h` | Declared the cursor-injection API and stored an "injected position" state bit. | `input-injection` | `NativeSceneBridge` | `medium` |
| `src/WallpaperEngine/Input/InputContext.cpp` | Added mutable access to the active `MouseInput`. | `input-injection` | `NativeSceneBridge` | `low` |
| `src/WallpaperEngine/Input/InputContext.h` | Declared mutable mouse-input access. | `input-injection` | `NativeSceneBridge` | `low` |
| `src/WallpaperEngine/Render/CFBO.cpp` | Split framebuffer behavior by platform, allocated a Metal render target on Apple, and made texture-ID reads tolerant of pointer-backed textures. | `metal-backend` | `NativeSceneRenderer` | `high` |
| `src/WallpaperEngine/Render/CFBO.h` | Added the Apple Metal texture surface API and private Metal lifetime hooks. | `metal-backend` | `NativeSceneRenderer` | `medium` |
| `src/WallpaperEngine/Render/CTexture.cpp` | Added Apple-specific branching for Metal upload, defensive fallback decoding for malformed TEXB payloads, and NPOT compressed-texture fallback to sibling image assets when Metal cannot accept the packaged texture directly. | `metal-backend` | `NativeSceneRenderer` | `high` |
| `src/WallpaperEngine/Render/CTexture.h` | Added Apple texture accessors, switched the video-player type based on platform, and exposed the sidecar image fallback hook used by the Metal upload path. | `metal-backend` | `NativeSceneRenderer` | `high` |
| `src/WallpaperEngine/Render/CWallpaper.cpp` | Removed Apple-side video and web wallpaper construction, exposed the scene FBO as a Metal texture, and bypassed the OpenGL blit path on Apple. | `metal-backend` | `NativeSceneRenderer` | `high` |
| `src/WallpaperEngine/Render/CWallpaper.h` | Declared the Apple-only wallpaper Metal texture accessor. | `metal-backend` | `NativeSceneRenderer` | `medium` |
| `src/WallpaperEngine/Render/Camera.cpp` | Forced orthographic near planes to include `z = 0` geometry so 2D scenes are not clipped away. | `runtime-fix` | `NativeSceneRenderer` | `medium` |
| `src/WallpaperEngine/Render/Drivers/GLFWOpenGLDriver.cpp` | Added Apple-specific GLFW native bindings and hints while keeping Linux-only X11 details guarded. | `platform-guard` | `NativeSceneCompatibility` | `low` |
| `src/WallpaperEngine/Render/Objects/CImage.cpp` | Added Apple Metal buffer setup and render dispatch while preserving the original OpenGL path for non-Apple builds. | `metal-backend` | `NativeSceneRenderer` | `high` |
| `src/WallpaperEngine/Render/Objects/CImage.h` | Added Apple-side Metal buffer handles and helper methods for pass setup. | `metal-backend` | `NativeSceneRenderer` | `medium` |
| `src/WallpaperEngine/Render/Objects/CParticle.cpp` | Guarded the OpenGL particle path, added Apple-side custom indexed geometry submission, and restored Metal rendering for particle fixtures that previously returned early. | `metal-backend` | `NativeSceneRenderer` | `high` |
| `src/WallpaperEngine/Render/Objects/Effects/CPass.cpp` | Added Apple render dispatch, array-count-aware uniform uploads, per-scene light combo definitions, uniform population for point, spot, tube, and directional lights, plus custom Metal vertex/index buffer plumbing for nonstandard geometry layouts. | `metal-backend` | `NativeSceneRenderer` | `high` |
| `src/WallpaperEngine/Render/Objects/Effects/CPass.h` | Added Apple Metal state, buffer setters, the overload needed for array `vec4` uniforms, and owned custom-geometry bindings for Metal indexed draws. | `metal-backend` | `NativeSceneRenderer` | `high` |
| `src/WallpaperEngine/Render/Shaders/GLSLContext.cpp` | Disabled unsupported GL 4.20 packing on macOS GL output and added a full GLSL -> SPIR-V -> MSL compilation path with reflected Metal resource-slot parsing. | `shader-compat` | `NativeSceneCompatibility` | `high` |
| `src/WallpaperEngine/Render/Shaders/GLSLContext.h` | Added the MSL compilation result types and reflected vertex-attribute metadata. | `shader-compat` | `NativeSceneCompatibility` | `medium` |
| `src/WallpaperEngine/Render/Shaders/ShaderUnit.cpp` | Changed `#require` from comment-out to actual include loading, sanitized malformed conditionals and fragment varying writes, and relaxed combo parsing for float and string defaults. | `shader-compat` | `NativeSceneCompatibility` | `high` |
| `src/WallpaperEngine/Render/Shaders/ShaderUnit.h` | Declared the shader sanitizer passes. | `shader-compat` | `NativeSceneCompatibility` | `medium` |
| `src/WallpaperEngine/Render/TextureProvider.h` | Added an Apple-only virtual Metal texture accessor for renderer consumers. | `metal-backend` | `NativeSceneRenderer` | `medium` |
| `src/WallpaperEngine/Render/Wallpapers/CScene.cpp` | Defaulted zero-sized projections to viewport size, rebuilt runtime light arrays every frame, guarded OpenGL-only debug operations on Apple, and added Metal-side scene clears so captures do not inherit stale black render targets. | `runtime-fix` | `NativeSceneRenderer` | `high` |
| `src/WallpaperEngine/Render/Wallpapers/CScene.h` | Added public accessors for all per-scene light arrays and declared light-state update helpers. | `runtime-fix` | `NativeSceneRenderer` | `medium` |
| `src/WallpaperEngine/WebBrowser/WebBrowserContext.h` | Stubbed the browser context on Apple so CEF headers are not required when the embedded macOS build excludes web rendering. | `platform-guard` | `NativeSceneCompatibility` | `low` |

## New Files (macOS-Specific)

| File | Size | Purpose, upstream relationship, and dependencies | Category | Destination | Risk |
| --- | ---: | --- | --- | --- | --- |
| `CMakeLists-bridge.cmake` | 11,457 B | Standalone bridge build that replaces the upstream executable-oriented CMake entrypoint for the macOS host. Pulls in the shared engine sources, Apple frameworks, vendored shader libraries, and `Sources/CWEBridge/WEBridge.cpp`. | `embedding-support` | `NativeSceneBridge` | `medium` |
| `extract_pkg.py` | 7,058 B | Local developer utility for inspecting `.pkg` archives and dumping scene details. Does not replace a runtime component and should not survive extraction. Depends only on Python stdlib. | `other` | `delete` | `low` |
| `src/WallpaperEngine/Input/Drivers/SimpleMouseInput.cpp` | 606 B | Minimal injected-position mouse driver for embedded Apple rendering. Replaces GLFW polling when the host owns the event loop. Depends on `MouseInput.h`. | `input-injection` | `NativeSceneBridge` | `low` |
| `src/WallpaperEngine/Input/Drivers/SimpleMouseInput.h` | 946 B | Header for the embedded mouse-input adapter used by the Metal driver. Depends on `MouseInput.h` and `glm`. | `input-injection` | `NativeSceneBridge` | `low` |
| `src/WallpaperEngine/Render/CFBO.mm` | 1,732 B | Apple-specific Metal render-target allocation and teardown for `CFBO`. Extends `CFBO.cpp` and depends on Metal plus `CMetalDriver`. | `metal-backend` | `NativeSceneRenderer` | `high` |
| `src/WallpaperEngine/Render/CTexture.mm` | 8,406 B | Apple Metal texture upload path for static textures, including BC texture support, mip-chain handling, and padded sidecar image upload when packaged compressed textures are incompatible with Metal. Extends `CTexture.cpp` and depends on Metal, `stb_image`, and the upstream texture format enum. | `metal-backend` | `NativeSceneRenderer` | `high` |
| `src/WallpaperEngine/Render/Drivers/AVFoundation/AVGLPlayer.h` | 1,498 B | AVFoundation-backed video-player interface used in place of the Linux mpv path on Apple. Depends on OpenGL and AVFoundation-facing Objective-C++ implementation. | `metal-backend` | `NativeSceneRenderer` | `medium` |
| `src/WallpaperEngine/Render/Drivers/AVFoundation/AVGLPlayer.mm` | 7,865 B | AVFoundation video decode implementation that uploads frames into GL textures. Extends the upstream video abstraction but remains GL-based, not Metal-native. Depends on AVFoundation, CoreVideo, CoreMedia, and OpenGL. | `metal-backend` | `NativeSceneRenderer` | `high` |
| `src/WallpaperEngine/Render/Drivers/CMetalDriver.h` | 4,324 B | Apple `VideoDriver` replacement that accepts host-owned Metal device and command queue handles. Replaces the upstream GLFW driver in embedded use. Depends on `VideoDriver.h` and `SimpleMouseInput`. | `metal-backend` | `NativeSceneRenderer` | `high` |
| `src/WallpaperEngine/Render/Drivers/CMetalDriver.mm` | 2,865 B | Objective-C++ implementation of the embedded Metal driver, command-buffer lifecycle, frame timing source, and explicit render-pass clears used by Apple scene captures. Depends on Metal, QuartzCore, and `MetalOutput`. | `metal-backend` | `NativeSceneRenderer` | `high` |
| `src/WallpaperEngine/Render/Drivers/Output/MetalOutput.cpp` | 896 B | Minimal `Output` implementation for the Metal renderer, replacing the GLFW window output layer. Depends on `MetalOutputViewport`. | `metal-backend` | `NativeSceneRenderer` | `medium` |
| `src/WallpaperEngine/Render/Drivers/Output/MetalOutput.h` | 1,037 B | Header for the Metal output adapter. Replaces the GLFW output abstraction for embedded rendering. | `metal-backend` | `NativeSceneRenderer` | `medium` |
| `src/WallpaperEngine/Render/Drivers/Output/MetalOutputViewport.cpp` | 516 B | No-op viewport wrapper for the Metal path where context switching and swap calls are host-managed. | `metal-backend` | `NativeSceneRenderer` | `low` |
| `src/WallpaperEngine/Render/Drivers/Output/MetalOutputViewport.h` | 589 B | Header for the Metal viewport adapter. | `metal-backend` | `NativeSceneRenderer` | `low` |
| `src/WallpaperEngine/Render/Objects/CImage.mm` | 2,244 B | Apple Metal vertex-buffer allocation for `CImage`, mirroring the five geometry streams used by the GL path. Extends `CImage.cpp` and depends on Metal plus `CMetalDriver`. | `metal-backend` | `NativeSceneRenderer` | `high` |
| `src/WallpaperEngine/Render/Objects/Effects/CPass.mm` | 21,115 B | Core Metal render-pass implementation for scene/image draws, including MSL compilation, pipeline creation, uniform binding, texture binding, clip-space correction, and indexed/custom-geometry draw submission. Extends `CPass.cpp` and depends on Metal, `GLSLContext`, and the Apple texture/FBO helpers. | `metal-backend` | `NativeSceneRenderer` | `high` |

## Notes

- `docs/PATCHLOG_UNTRACKED.md` is now superseded by this consolidated file, but it remains useful as the original working notes for the untracked-file portion of the audit.
- The current divergence is renderer-heavy. Phase 1 should focus on making behavior measurable before Phase 2 starts moving ownership boundaries.
