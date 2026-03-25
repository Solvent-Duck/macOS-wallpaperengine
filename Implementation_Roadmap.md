# macOS Wallpaper Engine — Implementation Roadmap

## Current State

The application is a menu bar-only macOS app that renders animated wallpapers behind desktop icons using borderless windows at the desktop window level. It supports multi-monitor configurations and intelligently pauses rendering when the desktop is occluded.

---

## Wallpaper Type Support

| Type | Status | Details |
|------|--------|---------|
| **Video** | **Working** (partial) | MP4, MOV, M4V via AVFoundation + AVPlayerLooper. WebM is supported via first-load ffmpeg transcoding to cached MP4. |
| **Web** | **Working** | WKWebView loads local HTML/JS/CSS bundles. JS API polyfill covers ~20% of WE's API (stubs for properties, audio, cursor, music). |
| **Scene** | **Implemented** (untested) | C bridge to linux-wallpaperengine via `libwallpaperengine.a`. Shared OpenGL context + CVDisplayLink at 30fps. Builds successfully; awaiting runtime testing. |
| **Application** | **Skipped** | Windows executables — not feasible on macOS. |

---

## What Has Been Implemented

- **Desktop window layer** — Borderless, transparent windows at `desktopWindow + 1` level, one per screen. Persists across Spaces, hidden from Mission Control.
- **Video renderer** — AVFoundation playback with seamless looping (`AVPlayerLooper`), muted by default, aspect-fill scaling.
- **Web renderer** — WKWebView with file URL access. Injects JS polyfill at document start providing stubs for `wallpaperPropertyListener`, `wallpaperRegisterAudioListener`, `wallpaperRequestCursorPosition`, and `wallpaperRequestRandomMusicFile`.
- **Occlusion detection** — KVO on `NSWindow.occlusionState` automatically pauses/resumes renderers when the desktop is covered or revealed.
- **Menu bar UI** — Status item with: current wallpaper label, "Select Wallpaper..." (file picker), Pause/Resume toggle, Clear Wallpaper, Quit. Keyboard shortcuts (Cmd+O, Cmd+P, Cmd+Q).
- **`.pkg` archive parser** — Parses Wallpaper Engine's binary package format, extracts to temp directories.
- **Wallpaper project loader** — Loads from directories with `project.json`, direct `project.json` files, `.pkg` archives, or bare media files (auto-wrapped).
- **Cursor tracking** — Global mouse event monitoring with normalized coordinates (0.0–1.0), forwarded to web wallpapers.
- **Multi-monitor support** — `DesktopWindowManager` creates/destroys windows on display configuration changes.
- **Scene renderer** — Full C bridge to linux-wallpaperengine C++ engine. Two-step build: `build-bridge.sh` (CMake → `libwallpaperengine.a` 4.9MB static library) then `swift build` (SPM links everything). Renders via shared OpenGL context between GLFW (engine) and NSOpenGLView (display), CVDisplayLink capped at 30fps, zero GPU cost when paused. macOS platform patches applied to engine: `#ifdef __APPLE__` guards for PulseAudio, CEF, MPV, X11; forward-compat GL hints; embeddable constructors; inline stubs for excluded subsystems.

---

## What Remains to Be Implemented

### High Priority (v1 targets not yet done)

#### 1. Scene Renderer Runtime Testing (Difficulty: 5/10)
The scene renderer is implemented and builds but has not been runtime-tested yet. Test wallpapers are available at `~/wallpaper_engine/test_wallpapers/` (deep_space, neon_sunset, shimmering_particles). WE assets at `~/wallpaper_engine/assets/`.

**What's needed:**
- Run the app with a scene wallpaper and verify it renders correctly
- Debug any shader compilation failures (macOS GL has stricter validation)
- Verify pause/resume lifecycle works end-to-end
- Profile CPU/GPU usage
- Expected: ~90% shader compatibility; some complex 3D wallpapers may fail

**Known v1 limitations:**
- Audio reactivity stubbed (wallpapers see silence)
- Video textures within scenes not supported (MPV excluded on macOS)
- Engine runs in-process (no crash isolation)
- Mouse position injection is a TODO in the bridge

#### 2. WebM Video Support (Difficulty: 4/10)
Implemented as a pragmatic compatibility layer: `.webm` files are transcoded to cached MP4 on first load, then played through AVFoundation.

**Remaining work:**
- Move transcoding off the UI path so large wallpapers do not block loading
- Improve user-facing progress/error reporting during transcode
- Consider a true decode path later if startup latency becomes a real problem

#### 3. Per-Wallpaper Properties UI (Difficulty: 3/10)
Wallpaper Engine wallpapers define user-configurable properties in `project.json` (colors, sliders, toggles, etc.).

**What's needed:**
- Parse property definitions from `project.json`
- Build a SwiftUI settings panel that dynamically generates controls
- Wire property values into both the web JS API and the scene C bridge

### Medium Priority

#### 4. Enhanced WE JavaScript API (Difficulty: 4/10)
Current polyfill provides stub-only coverage (~20%). Target is ~80%.

**What's needed:**
- Implement `wallpaperPropertyListener.applyUserProperties` (pass real values)
- Implement audio data forwarding (requires audio reactivity, below)
- Handle `wallpaperRequestRandomMusicFile` responses
- Test against popular web wallpapers and fill API gaps

#### 5. Audio Reactivity (Difficulty: 6/10)
Required for audio-visualizing wallpapers (both web and scene types).

**What's needed:**
- Tap system audio output via `AVAudioEngine`
- Perform FFT to extract frequency bands
- Forward frequency data to web wallpapers via JS (`wallpaperRegisterAudioListener` callback)
- Forward frequency data to scene renderer via `we_set_audio_data`

**Challenge:** Capturing system audio on macOS is harder than on Windows. May require a virtual audio device or ScreenCaptureKit.

#### 6. Frame Rate Capping (Difficulty: 2/10)
Scene renderer already uses CVDisplayLink with 30fps cap. Video/web are frame-managed by their frameworks.

**What's needed:**
- Make frame rate configurable (e.g., UserDefaults or properties UI)
- Consider per-wallpaper frame rate settings

#### 7. App Nap Participation (Difficulty: 2/10)
**What's needed:**
- Use `NSProcessInfo` power assertions appropriately
- Allow macOS App Nap when wallpaper is fully occluded
- Prevent App Nap when actively rendering

### Long-Term (Post-v1)

#### 8. Metal Rendering Backend (Difficulty: 7/10)
OpenGL is deprecated on macOS since 10.14. It still works (runs through a Metal translation layer on Apple Silicon) but adds CPU overhead.

**What's needed:**
- Rewrite rendering backend from OpenGL to Metal
- Better power efficiency, especially on Apple Silicon
- Not urgent — paused OpenGL is practically efficient enough for v1

#### 9. HLSL -> Metal Shader Translation (Difficulty: 7/10)
Currently relies on linux-wallpaperengine's GLSL translation path.

**What's needed:**
- Direct HLSL -> Metal translation for better compatibility and performance
- Can use SPIRV-Cross (already a dependency) for SPIR-V -> Metal path

#### 10. Renderer Subprocess Architecture
Run the scene renderer as a separate process for crash isolation.

**What's needed:**
- Render offscreen in a subprocess
- Share frames via `IOSurface` or XPC
- Cleaner separation and crash resilience

---

## Out of Scope

- **Application wallpapers** — Windows executables, not feasible on macOS
- **Full audio visualization parity** — Target reasonable coverage, not 100%
- **Every obscure WE shader effect** — ~90% coverage is the realistic target
- **Steam integration** — Intentionally standalone; no Steam dependency

---

## Implementation Order (Suggested)

```
1. Scene renderer testing      — Validate the build, debug shader issues (DONE: builds, needs runtime test)
2. WebM video support          — Quick win, unblocks many video wallpapers
3. Properties UI               — Enables customization for all wallpaper types
4. Enhanced JS API             — Improves web wallpaper compatibility
5. Audio reactivity            — Enables audio-visualizing wallpapers
6. App Nap + power polish      — Power efficiency refinements
7. Metal backend               — Long-term performance investment
```
