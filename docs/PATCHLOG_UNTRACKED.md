# PATCHLOG — New Files (macOS-Specific)

## New Files

### `CMakeLists-bridge.cmake`

- **Size:** 273 lines
- **Purpose:** Standalone CMake build script that compiles the upstream C++ engine into a static library (`libwallpaperengine.a`) for consumption by the Swift Package Manager host app. Enumerates all common sources (parsers, audio, render, scripting) and conditionally adds macOS-specific sources (Metal driver, AVFoundation player, SimpleMouseInput) on Apple or GLFW/OpenGL sources on Linux. Configures vendored submodules (glslang, SPIRV-Cross, kissfft, quickjs, argparse), sets up include paths, links Apple frameworks (Metal, MetalKit, AVFoundation, CoreMedia, etc.), and copies the output `.a` into `build/lib/` for SPM.
- **Replaces/Extends:** Replaces the upstream `CMakeLists.txt` for the macOS bridge build. The upstream CMakeLists builds a standalone executable with GLFW/X11/PulseAudio; this builds a static library with no windowing system dependency.
- **Destination:** `NativeSceneBridge`
- **Key Dependencies:** Upstream CMakeModules (FindLZ4, FindFFMPEG, etc.), all upstream source files enumerated in the BRIDGE_SOURCES list, `Sources/CWEBridge/WEBridge.cpp` from the Swift package
- **Notes:** This is the build system linchpin. It must be kept in sync with any upstream source file additions/removals. The `spirv-cross-msl` target is linked here (not in upstream), reflecting the GLSL-to-MSL cross-compilation requirement. GLEW is linked on macOS only to satisfy unguarded GL symbol references in upstream files that are never reached at runtime on the Metal path.

---

### `extract_pkg.py`

- **Size:** 182 lines
- **Purpose:** Developer utility script that parses Wallpaper Engine `.pkg` archive files (PKGV0021 format), lists all embedded files, extracts `scene.json`, and dumps details about `foliagesway` effects and the "Fondo 5" layer. Used for debugging and understanding wallpaper scene structure during development.
- **Replaces/Extends:** New, no upstream equivalent
- **Destination:** `delete`
- **Key Dependencies:** Python stdlib only (`struct`, `json`). Hardcoded path to a specific wallpaper project.
- **Notes:** Pure developer/debug tool with a hardcoded local path. Not part of the runtime build. Should be deleted or moved to a `tools/` directory outside the submodule.

---

### `src/WallpaperEngine/Input/Drivers/SimpleMouseInput.h`

- **Size:** 34 lines
- **Purpose:** Header declaring `SimpleMouseInput`, a minimal `MouseInput` implementation for the embedded Metal driver. Receives normalized [0,1] cursor coordinates from the Swift host via `injectPosition()` instead of polling GLFW.
- **Replaces/Extends:** Replaces `GLFWMouseInput` on Apple platforms. Same `MouseInput` base interface, but no GLFW dependency.
- **Destination:** `NativeSceneBridge`
- **Key Dependencies:** `WallpaperEngine/Input/MouseInput.h` (upstream base class), `glm/vec2.hpp`
- **Notes:** Trivial adapter. The injection pattern is the right design for an embedded architecture where the host app owns the event loop.

---

### `src/WallpaperEngine/Input/Drivers/SimpleMouseInput.cpp`

- **Size:** 20 lines
- **Purpose:** Implementation of `SimpleMouseInput`. `update()` is a no-op (position is set externally), click status always returns `Released`, and `injectPosition()` stores the provided coordinates.
- **Replaces/Extends:** Replaces `GLFWMouseInput.cpp` on Apple platforms
- **Destination:** `NativeSceneBridge`
- **Key Dependencies:** `SimpleMouseInput.h`, `WallpaperEngine/Input/MouseInput.h`
- **Notes:** Click support is stubbed out (always Released). Will need real click injection if interactive wallpapers require mouse click handling.

---

### `src/WallpaperEngine/Render/CFBO.mm`

- **Size:** 50 lines
- **Purpose:** Objective-C++ extension of the upstream `CFBO` class, adding Metal texture allocation/deallocation for framebuffer objects. `initMetal()` creates an `MTLTexture` with `RenderTarget | ShaderRead` usage as the Metal equivalent of an OpenGL FBO color attachment. `destroyMetal()` releases it via ARC bridge transfer. `getMetalTexture()` returns the raw `void*` handle.
- **Replaces/Extends:** Extends `CFBO.cpp` — the upstream file handles GL FBO creation; this file adds the parallel Metal path. Both are compiled; the `.cpp` handles GL, the `.mm` handles Metal.
- **Destination:** `NativeSceneRenderer`
- **Key Dependencies:** `CFBO.h` (upstream), `CMetalDriver.h` (new), Metal framework, `CMetalDriver::currentDevice()` static accessor
- **Notes:** Uses `MTLStorageModePrivate` (GPU-only), which is correct for render targets. The manual `__bridge_retained`/`__bridge_transfer` pattern is used throughout the Metal files to cross the ARC/C++ boundary safely.

---

### `src/WallpaperEngine/Render/CTexture.mm`

- **Size:** 193 lines
- **Purpose:** Objective-C++ extension of the upstream `CTexture` class, adding Metal texture upload. Handles two paths: (1) stbi-decoded images (JPEG/PNG inside TEXB containers) decoded to RGBA8 and uploaded via `replaceRegion:`, and (2) raw/BCn compressed textures (DXT1/DXT3/DXT5 mapped to BC1/BC2/BC3) uploaded with correct block-compressed bytesPerRow calculations. Supports full mipmap chains. Includes a size-mismatch fallback that mirrors the GL path's stbi re-decode behavior.
- **Replaces/Extends:** Extends `CTexture.cpp` — upstream handles GL texture creation; this adds the Metal path. Both compiled.
- **Destination:** `NativeSceneRenderer`
- **Key Dependencies:** `CTexture.h` (upstream), `CMetalDriver.h` (new), Metal framework, `stb_image.h`, upstream `TextureFormat` enum from `Data/Assets`
- **Notes:** Most complex texture handling file. The `metalPixelFormat()` mapping covers the common WE formats but may need extension for exotic formats. Uses `MTLStorageModeShared` (CPU-writable) for static textures, which is appropriate for upload-once data. The BCn block size calculation is critical for correctness.

---

### `src/WallpaperEngine/Render/Drivers/AVFoundation/AVGLPlayer.h`

- **Size:** 49 lines
- **Purpose:** C++ header declaring `AVGLPlayer`, an AVFoundation-backed video texture player that decodes MP4 video and uploads frames to a GL texture via `glTexSubImage2D` each frame. Provides the same interface as the Linux `GLPlayer` so `CTexture.cpp` can select between them with `#ifdef __APPLE__`.
- **Replaces/Extends:** Replaces the Linux `GLPlayer` (mpv/FFmpeg-based video player) on Apple platforms
- **Destination:** `NativeSceneRenderer`
- **Key Dependencies:** `GL/glew.h` (for `GLuint`), OpenGL framework
- **Notes:** This is the GL-based video path. A Metal-native video player would be needed to eliminate the GL dependency entirely. The header comment notes "non-Metal path; Metal player pending."

---

### `src/WallpaperEngine/Render/Drivers/AVFoundation/AVGLPlayer.mm`

- **Size:** 221 lines
- **Purpose:** Objective-C++ implementation of `AVGLPlayer`. Contains an inner `WEVideoPlayer` ObjC class that: writes video bytes to a temp file, creates an `AVPlayer` with `AVPlayerItemVideoOutput` requesting 32-bit BGRA pixel buffers, loops playback via `AVPlayerItemDidPlayToEndTimeNotification`, and uploads frames to GL via `glTexSubImage2D` on each `render()` call. The C++ `AVGLPlayer` wrapper bridges across the ARC/C++ boundary using `__bridge_retained`/`__bridge_transfer`.
- **Replaces/Extends:** Replaces Linux's mpv/FFmpeg-based video player
- **Destination:** `NativeSceneRenderer`
- **Key Dependencies:** AVFoundation, CoreMedia, CoreVideo frameworks, OpenGL/GLEW (for texture upload), `WallpaperEngine/Logging/Log.h`
- **Notes:** Writes video data to a temp file because `AVPlayer` requires a URL source. A custom `AVAssetResourceLoader` could avoid this but adds complexity. The GL upload path (`glTexSubImage2D`) means this still depends on an OpenGL context. Handles pixel buffer row padding correctly via `GL_UNPACK_ROW_LENGTH`. Usage-count-based play/pause lifecycle matches the upstream pattern.

---

### `src/WallpaperEngine/Render/Drivers/CMetalDriver.h`

- **Size:** 113 lines
- **Purpose:** Header declaring `CMetalDriver`, the Metal-based `VideoDriver` implementation that replaces `GLFWOpenGLDriver` on Apple platforms. Receives `MTLDevice` and `MTLCommandQueue` from the Swift host (as `void*` to keep ObjC out of the header). Manages per-frame `MTLCommandBuffer` lifecycle (`beginFrame()`/`endFrame()`). Provides a static `currentDevice()` accessor used by CFBO, CTexture, and CImage to obtain the Metal device without constructor signature changes.
- **Replaces/Extends:** Replaces `GLFWOpenGLDriver.h` on Apple platforms
- **Destination:** `NativeSceneRenderer`
- **Key Dependencies:** `VideoDriver.h` (upstream base class), `ApplicationContext.h`, `WallpaperApplication.h`, `SimpleMouseInput.h` (new)
- **Notes:** The `void*` opaque pointer pattern for Metal objects is used throughout to avoid ObjC in C++ headers. The static singleton `s_instance`/`currentDevice()` pattern is a pragmatic compromise to avoid threading Metal device references through every constructor. `dispatchEventQueue()` is a no-op because the Swift CVDisplayLink owns the frame clock.

---

### `src/WallpaperEngine/Render/Drivers/CMetalDriver.mm`

- **Size:** 86 lines
- **Purpose:** Objective-C++ implementation of `CMetalDriver`. Initializes with Metal device/queue from Swift, creates a `MetalOutput`, manages `MTLCommandBuffer` lifecycle per frame via `beginFrame()`/`endFrame()`, provides render time via `CACurrentMediaTime`, and delegates mouse input to `SimpleMouseInput`. Most `VideoDriver` virtual methods are no-ops or trivial (no windowing system to manage).
- **Replaces/Extends:** Replaces `GLFWOpenGLDriver.cpp` on Apple platforms
- **Destination:** `NativeSceneRenderer`
- **Key Dependencies:** Metal framework, QuartzCore (`CACurrentMediaTime`), `MetalOutput.h` (new), `CMetalDriver.h` (new)
- **Notes:** The singleton pattern (`s_instance`) is set in the constructor and cleared in the destructor. Not thread-safe if multiple drivers are created, but only one is expected. `getProcAddress()` returns nullptr — GL proc loading is meaningless on Metal.

---

### `src/WallpaperEngine/Render/Drivers/Output/MetalOutput.h`

- **Size:** 34 lines
- **Purpose:** Header declaring `MetalOutput`, the `Output` implementation for the Metal driver. Creates a single "default" `MetalOutputViewport` covering the full viewport. `renderVFlip()` returns false (Metal NDC origin is top-left, matching the engine's scene coordinate system).
- **Replaces/Extends:** Replaces `GLFWWindowOutput.h` on Apple platforms
- **Destination:** `NativeSceneRenderer`
- **Key Dependencies:** `Output.h` (upstream base class), `ApplicationContext.h`
- **Notes:** Minimal adapter. No image buffer support (`haveImageBuffer()` returns false) — screenshot/recording functionality would need to be added here.

---

### `src/WallpaperEngine/Render/Drivers/Output/MetalOutput.cpp`

- **Size:** 28 lines
- **Purpose:** Implementation of `MetalOutput`. Constructor creates a single `MetalOutputViewport`. All methods are trivial: `reset()`, `updateRender()` are no-ops; `renderVFlip()` returns false; image buffer methods return null/zero.
- **Replaces/Extends:** Replaces `GLFWWindowOutput.cpp` on Apple platforms
- **Destination:** `NativeSceneRenderer`
- **Key Dependencies:** `MetalOutput.h` (new), `MetalOutputViewport.h` (new)
- **Notes:** Very thin. Multi-monitor support would require creating multiple viewports here.

---

### `src/WallpaperEngine/Render/Drivers/Output/MetalOutputViewport.h`

- **Size:** 22 lines
- **Purpose:** Header declaring `MetalOutputViewport`, the `OutputViewport` implementation for Metal. `makeCurrent()` and `swapOutput()` are no-ops because Metal command buffer lifecycle is managed by `CMetalDriver`.
- **Replaces/Extends:** Replaces `GLFWOutputViewport.h` on Apple platforms
- **Destination:** `NativeSceneRenderer`
- **Key Dependencies:** `OutputViewport.h` (upstream base class)
- **Notes:** Trivial adapter.

---

### `src/WallpaperEngine/Render/Drivers/Output/MetalOutputViewport.cpp`

- **Size:** 14 lines
- **Purpose:** Implementation of `MetalOutputViewport`. Constructor forwards viewport rect and name to the base class. `makeCurrent()` and `swapOutput()` are empty — Metal has no GL-style context switching or buffer swapping.
- **Replaces/Extends:** Replaces `GLFWOutputViewport.cpp` on Apple platforms
- **Destination:** `NativeSceneRenderer`
- **Key Dependencies:** `MetalOutputViewport.h` (new), `OutputViewport.h` (upstream base class)
- **Notes:** Trivial adapter.

---

### `src/WallpaperEngine/Render/Objects/CImage.mm`

- **Size:** 56 lines
- **Purpose:** Objective-C++ extension of the upstream `CImage` class, adding Metal vertex/texcoord buffer allocation. `setupMetalBuffers()` creates five `MTLBuffer` objects (scene-space position, copy-space position, pass-space position, texcoord-copy, texcoord-pass) from float arrays. `destroyMetalBuffers()` releases them. Getter methods return raw `void*` handles for use by `CPass::renderMetal()`.
- **Replaces/Extends:** Extends `CImage.cpp` — upstream handles GL VBO/VAO setup; this adds the parallel Metal buffer creation.
- **Destination:** `NativeSceneRenderer`
- **Key Dependencies:** `CImage.h` (upstream), `CMetalDriver.h` (new), Metal framework
- **Notes:** The five buffers mirror the five vertex attributes used by the GL path. `MTLResourceStorageModeShared` is used, which is correct for CPU-written vertex data. Buffer lifetime is tied to the CImage object.

---

### `src/WallpaperEngine/Render/Objects/Effects/CPass.mm`

- **Size:** 416 lines
- **Purpose:** Objective-C++ extension of the upstream `CPass` class, implementing the full Metal render pass pipeline. `setupShadersMetal()` cross-compiles GLSL to MSL via `GLSLContext::toMsl()`, compiles vertex/fragment MSL libraries, builds a vertex descriptor from reflected attributes, creates an `MTLRenderPipelineState` with blending configuration, and creates a default sampler. `renderMetal()` creates a render command encoder targeting the destination FBO's Metal texture, binds vertex buffers at `kVertexDataBaseSlot + location`, resolves and binds all uniforms (including texture animation state like `g_Texture0Rotation`/`g_Texture0Translation`) to both vertex and fragment stages, binds fragment textures and samplers via reflected slot maps, and issues a 6-vertex triangle draw. Includes shader source dumping for debugging failed compilations.
- **Replaces/Extends:** Extends `CPass.cpp` — upstream handles the GL render path (`glUseProgram`, `glUniform*`, `glDrawArrays`); this adds the complete Metal equivalent.
- **Destination:** `NativeSceneRenderer`
- **Key Dependencies:** `CPass.h` (upstream), `CMetalDriver.h` (new), `GLSLContext.h` (upstream, extended with `toMsl()`), `CFBO.h` (upstream, extended with `getMetalTexture()`), `CRenderable.h`, `RenderContext.h`, Metal framework, `glm/gtc/type_ptr.hpp`
- **Notes:** This is the most complex and critical new file (416 lines). It is the core rendering workhorse — every visible pixel flows through here. The uniform binding strategy uses individual `setVertexBytes:`/`setFragmentBytes:` calls per uniform rather than a packed constant buffer, which is simpler but less optimal for shaders with many uniforms. Custom geometry callbacks (particles) are not yet supported (`m_drawGeometryCallback` logs an error). The `configureBlending()` helper maps WE's three blending modes (Translucent, Additive, Normal) to Metal blend factors. Shader compilation errors are caught and logged with source dumps to `/tmp/wallpaperengine-shader-dumps/`.
