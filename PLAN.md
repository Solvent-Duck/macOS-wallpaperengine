# macOS Wallpaper Engine — Project Plan

## Overview

Wallpaper Engine supports four wallpaper types. Compatibility difficulty varies enormously by type. The single most important external resource is **[linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine)** — a C++ project that has already reverse-engineered WE's proprietary scene format and built a renderer. This project builds on that rather than starting from scratch.

---

## Wallpaper Engine File Formats

| Type | Format | Notes |
|------|--------|-------|
| **Video** | MP4, WebM, AVI | Standard containers |
| **Web** | HTML/JS/CSS bundle | `index.html` + WE JS API calls |
| **Scene** | Proprietary `.json` + assets + HLSL shaders | The hard part |
| **Application** | Windows `.exe` | Not feasible on macOS — skip |

Workshop files are distributed as `.pkg` — a custom binary container. When WE is installed on Windows/Linux, they're extracted to `steamapps/workshop/content/431960/[id]/`. A standalone macOS app needs a `.pkg` parser (linux-wallpaperengine already has one).

Each wallpaper directory contains a `project.json` with metadata (type, title, preview path, properties) and the content files.

---

## The Core macOS Challenge: Rendering Behind the Desktop

`NSWorkspace.setDesktopImageURL` only accepts static images. To display animated content as wallpaper, the standard technique is:

1. Create an `NSWindow` at `CGWindowLevelForKey(.desktopWindow)` — this places it behind Finder icons
2. Set it borderless, non-activating, transparent background
3. Set `collectionBehavior` to `.canJoinAllSpaces` + `.stationary` so it survives Space switches
4. Create one window per `NSScreen` for multi-monitor support

**Reference implementation**: [Plash](https://github.com/sindresorhus/Plash) (open source, web-only WKWebView wallpaper app) demonstrates this entire pattern cleanly.

Known caveats: Mission Control briefly reveals the window stacking. This is a macOS limitation all similar apps share.

---

## Component Difficulty Breakdown

### 1. Video Wallpapers — `3/10`
- MP4/MOV: `AVFoundation` (`AVPlayerLayer`) handles this trivially
- **WebM is a problem**: not natively supported by AVFoundation. Requires bundling `libvpx`/`ffmpeg` or using a third-party decoder. WebM is extremely common in WE's library, so this isn't optional.
- Seamless looping: `AVPlayerLooper`
- Audio: mute by default, optionally unmute; detect when other apps are playing audio via `AVAudioEngine`

### 2. Web Wallpapers — `4/10`
- `WKWebView` loads local `file://` HTML bundles well
- WE injects a JavaScript API (`wallpaperPropertyListener`, `wallpaperRequestRandomMusicFile`, cursor position, audio data, etc.) — need to implement a polyfill injected via `WKUserScript`
- The WE JS API is partially community-documented; covering the most common calls gets ~80% coverage
- Mouse/cursor position: forward `NSEvent` coordinates into the WebView via JS
- Throttle JS execution when the wallpaper is fully occluded

### 3. Scene Wallpapers — `8/10`
This is the hardest and most important component. The scene format includes:
- A scene graph (`scene.json` + layer descriptors)
- HLSL shaders compiled for DirectX (need translation to GLSL or Metal)
- Particle systems, bloom/blur/chromatic aberration post-processing
- Camera paths, animation timelines
- Audio reactivity, mouse parallax

**The path forward**: Port `linux-wallpaperengine` to macOS.
- It's C++, builds with CMake, uses OpenGL + various libs (`glm`, `glfw`, `mpv` for video)
- OpenGL is deprecated on macOS (since 10.14) but still works — long-term risk, not an immediate blocker
- Will compile on macOS with minor changes; the heavy lifting (scene parser, shader translator, effect system) is already done
- Long-term goal: migrate the rendering backend from OpenGL to Metal for better power efficiency on Apple Silicon

### 4. Supporting Infrastructure

| Component | Difficulty | Notes |
|-----------|-----------|-------|
| `.pkg` parser | `3/10` | Already in linux-wallpaperengine |
| Desktop window layer | `3/10` | Plash is the blueprint |
| Multi-monitor | `4/10` | `NSScreen.screens`, one window per screen |
| Settings UI (wallpaper picker, properties) | `3/10` | Standard SwiftUI |
| WE scene properties (user-configurable params) | `4/10` | `project.json` schema, expose via UI |
| Audio reactivity | `6/10` | Tap system audio via `AVAudioEngine`; harder than on Windows |
| HLSL → Metal shader translation | `7/10` | Use linux-wallpaperengine's GLSL path short-term |

---

## Architecture

### Tech Stack

```
Swift/SwiftUI         — macOS app shell, settings UI, desktop window management
AVFoundation          — video wallpapers
WKWebView             — web wallpapers
linux-wallpaperengine — scene wallpaper renderer (C++ submodule)
  └── OpenGL          — rendering backend (short-term; Metal is the long-term target)
ffmpeg / libvpx       — WebM decoding
```

### Scene Renderer Integration Options

**— Renderer subprocess**
Run the renderer as a separate process rendering offscreen, share frames via `IOSurface` or XPC. More resilient to crashes; cleaner separation. Better long-term architecture.

---

## Performance Strategy

The pause/resume strategy matters more than any backend choice.

- Detect when the wallpaper window is **fully occluded** by other windows → stop rendering entirely
- Resume only when desktop is visible (Mission Control, empty desktop, etc.)
- Cap frame rate at **30fps** — imperceptible for most wallpapers, halves GPU load vs 60fps
- Use `CADisplayLink` / `CVDisplayLink` for render timing (avoids spinning a hot loop)
- Participate in macOS **App Nap** (`NSProcessInfo` power assertions)
- For web wallpapers: `WKWebView.pauseAllMediaPlayback()` when occluded

On Apple Silicon, OpenGL runs through a Metal translation layer adding CPU overhead. A native Metal renderer is the long-term power efficiency goal, but a paused OpenGL renderer in typical use (wallpaper covered by windows ~90% of the time) is practically efficient enough for v1.

---

## Progress

### Completed
- [x] Desktop window layer (borderless windows at desktop level, one per screen)
- [x] Multi-monitor support (auto-rebuilds on display config changes)
- [x] Video wallpapers — MP4/MOV/M4V via AVFoundation + AVPlayerLooper
- [x] WebM video support — ffmpeg transcoder with VideoToolbox HW acceleration + disk cache
- [x] Web wallpapers — WKWebView with WE JS API polyfill (~20% API coverage)
- [x] Scene wallpapers — linux-wallpaperengine C++ port via C bridge + CVDisplayLink at 30fps (runtime-tested: deep_space, neon_sunset, shimmering_particles)
- [x] Occlusion-based pause/resume (triple-gate: visibility + manual + sleep)
- [x] Sleep/wake handling with automatic scene renderer GL context recovery
- [x] Frame rate cap at 30fps via CVDisplayLink
- [x] Menu bar UI (status item with pause/resume, clear, audio toggle, gallery)
- [x] Fix: menu item actions broken after gallery opens (explicit `target = self` on all NSMenuItems)
- [x] `.pkg` archive parser (WE's binary package format)
- [x] Wallpaper project loader (directory, project.json, .pkg, bare media files)
- [x] Cursor tracking for interactive wallpapers (normalized coordinates)
- [x] CLI argument support for loading wallpapers on launch
- [x] Audio mute/unmute toggle
- [x] Gallery window — SwiftUI grid browser with preview thumbnails and tag filtering
- [x] Fix: occlusion detection for desktop-level windows (macOS reports them as permanently occluded)
- [x] Performance profiling — CPU frame timing (total / engine / blit split), FPS tracking, process memory (RSS), lifecycle event log, live FPS tooltip on status item
- [x] Per-wallpaper properties UI — slider, bool, color, combo, textinput controls; floating NSPanel; persisted per-wallpaper in UserDefaults; "Reset to Defaults"
- [x] WE JavaScript API ~80% coverage — `applyUserProperties` (functional, injects on load + per-change), `applyGeneralProperties`, audio zero-data heartbeat, media stubs, `_weVersion`/`_wePlatform`, `wallpaperGetContentRating`, `wallpaperPlaySound`, `wallpaperRegisterAudioResponsiveGroup`
- [x] Audio reactivity — `AVAudioEngine` input tap + vDSP FFT → 128 log-spaced bands → web JS + scene `we_set_audio_data`; zero-data heartbeat suppressed when real audio is active
- [x] App Nap participation — `NSProcessInfo` activity token held while rendering, released on all pause/sleep/occlude paths

### Remaining
- [ ] Metal rendering backend (long-term)
- [ ] HLSL → Metal shader translation (long-term)

---

## Scope

### v1 Target
- Video wallpapers (MP4 + WebM)
- Web wallpapers + core WE JS API polyfill
- Scene wallpapers via linux-wallpaperengine port
- Multi-monitor support
- `.pkg` extraction
- Basic per-wallpaper properties UI
- Smart pause/resume when occluded
- Gallery window for browsing installed wallpapers

### Out of Scope
- Application wallpapers (Windows EXEs — not feasible)
- Full audio visualization parity
- Every obscure WE shader effect (~90% coverage is the realistic target)
- Steam integration (intentionally standalone)

---

## Overall Difficulty: `7/10`

The project is ambitious but tractable, primarily because linux-wallpaperengine eliminates the hardest reverse-engineering work. Without it, this would be a 9/10 requiring months just to understand the scene format.

The biggest single risk is shader translation — WE's scene shaders use DirectX semantics and custom preprocessor macros. linux-wallpaperengine's GLSL translation handles a large subset but not everything. Expect some complex 3D wallpapers to render incorrectly or not at all.
