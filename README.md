# macOS Wallpaper Engine

A macOS application that plays animated [Wallpaper Engine](https://store.steampowered.com/app/431960/Wallpaper_Engine/) wallpapers as your desktop background. Supports video and web wallpaper types with a menu bar interface and visual gallery browser.

## Features

- **Video wallpapers** — MP4, MOV, M4V with seamless looping
- **Web wallpapers** — HTML/JS/CSS bundles with Wallpaper Engine JavaScript API polyfill
- **Multi-monitor support** — one wallpaper window per connected display
- **Smart power management** — automatically pauses rendering when the desktop is covered
- **Gallery browser** — SwiftUI window for browsing installed wallpapers with preview thumbnails and tag filtering
- **Menu bar controls** — pause/resume, mute/unmute audio, clear wallpaper, open gallery
- **Package support** — reads Wallpaper Engine's `.pkg` archive format

## Requirements

- macOS 13.0 or later
- Xcode Command Line Tools (`xcode-select --install`)
- Swift 5.9+
- CMake 3.12+ (`brew install cmake`)
- Homebrew dependencies (see below)

## Building

### 1. Install dependencies

```bash
# Xcode Command Line Tools (if not already installed)
xcode-select --install

# CMake and runtime dependencies
brew install cmake glew glfw sdl2 lz4 ffmpeg freeglut glm
```

### 2. Build and run

```bash
./run.sh
```

`run.sh` handles everything in order:
1. Builds the C++ engine bridge (`./build-bridge.sh`) — only on first run or if the library is missing; takes 2–5 minutes
2. Compiles the Swift app (`swift build -c release`)
3. Launches the binary

On subsequent runs the bridge step is skipped, so startup is fast.

#### Manual build steps (if needed)

If you want to build without launching, or need a clean rebuild:

```bash
# Step 1 — C++ bridge (once, or when engine code changes)
./build-bridge.sh

# Step 2 — Swift app
swift build -c release
```

The release executable is at `.build/release/WallpaperEngine`.

### Troubleshooting

| Problem | Fix |
|---------|-----|
| `library not found for -lglfw` | `brew install glfw` and make sure `/opt/homebrew/lib` is on the linker path (it is by default in Package.swift) |
| `library not found for -lwallpaperengine` | Run `./run.sh` (or `./build-bridge.sh` manually) — the C++ bridge must be compiled before `swift build` |
| `submodule update --init` hangs | Check network; the engine has ~9 nested submodules to clone |
| CMake can't find OpenGL/GLEW/SDL2 | `brew install glew sdl2 freeglut` — CMake searches `/opt/homebrew` and `/usr/local` |
| Linker warnings about "newer macOS version" | Safe to ignore — vendored libraries built for a newer deployment target than the Swift package minimum |

### Clean rebuild

```bash
# Remove all build artifacts and start fresh
rm -rf build .build
./run.sh
```

## Usage

### Launch

```bash
# Build (if needed) and launch
./run.sh

# Build (if needed) and immediately load a wallpaper
./run.sh "/path/to/wallpaper/directory"

# Launch the already-built binary directly
.build/release/WallpaperEngine
```

The app runs as a menu bar accessory (no Dock icon) — look for the photo icon in the menu bar.

**Quit behavior:** this is a menu bar accessory app, so quit handling is routed through the status-item menu instead of a system-wide keyboard monitor. The current quit path performs explicit renderer teardown and then exits immediately, working around a crash in linked C++ scene-renderer finalizers during normal `NSApplication.terminate()` shutdown.

### Menu Bar

| Item | Shortcut | Description |
|------|----------|-------------|
| Browse Wallpapers… | Cmd+B | Open the gallery window to pick from installed wallpapers |
| Select Wallpaper… | Cmd+O | Open a file picker to load any wallpaper file or directory |
| Pause / Resume | Cmd+P | Toggle wallpaper playback |
| Mute / Unmute Audio | Cmd+M | Toggle wallpaper audio (muted by default) |
| Clear Wallpaper | | Remove the current wallpaper |
| Copy Diagnostics | Cmd+D | Copy performance stats and lifecycle events to clipboard |
| Quit | — | Exit the application from the menu bar |

### Gallery

Click **Browse Wallpapers…** in the menu bar to open the gallery window. It scans `~/Wallpaper Projects/` for installed wallpaper directories containing a `project.json` file.

The gallery displays:
- Preview thumbnails from each wallpaper's `preview` image
- Wallpaper title and type badge (Video, Web, Scene)
- Tag-based filtering (tags from `project.json`)
- Search by wallpaper title

Click any wallpaper card to set it as your desktop background.

### Installing Wallpapers

Place Wallpaper Engine wallpaper directories in `~/Wallpaper Projects/`. Each wallpaper should be a folder containing a `project.json` file and its associated media files.

Typical structure:
```
~/Wallpaper Projects/
  ├── 1234567890/
  │   ├── project.json
  │   ├── preview.jpg
  │   └── wallpaper.mp4
  └── 0987654321/
      ├── project.json
      ├── preview.gif
      └── index.html
```

You can also load `.pkg` files (Wallpaper Engine's packed format) directly via **Select Wallpaper…** — they will be extracted automatically.

### Supported Wallpaper Types

| Type | Status | Formats |
|------|--------|---------|
| Video | Working | MP4, MOV, M4V |
| Web | Working | HTML/JS/CSS bundles |
| Scene | Working | Proprietary format via linux-wallpaperengine C++ bridge (OpenGL 3.3) |
| Application | Not supported | Windows executables — not feasible on macOS |

**Note:** WebM videos are automatically transcoded to MP4 via ffmpeg on first load (requires ffmpeg from Homebrew).

## Automation Direction

Automation is planned as a **post-core quality-of-life layer**, not part of the current rendering/compatibility push. The intended agent-facing design is a small companion CLI backed by a local control channel into the running app, with machine-readable commands and JSON responses rather than GUI scripting.

Long-term, this should support tag-driven wallpaper selection so an external agent can choose wallpapers based on factors like local weather, time of day, season, and date, then apply them through a stable command surface.

## Architecture

The app creates borderless, transparent `NSWindow` instances positioned at the desktop window level — above the system wallpaper image but below Finder's desktop icons. Each connected display gets its own window.

```
┌─────────────────────────────┐
│  Application windows        │  ← Normal windows
├─────────────────────────────┤
│  Desktop icons (Finder)     │  ← Managed by macOS
├─────────────────────────────┤
│  WallpaperEngine window     │  ← desktopWindow + 1
├─────────────────────────────┤
│  System wallpaper           │  ← Static image set by macOS
└─────────────────────────────┘
```

### Key Components

- **`DesktopWindow`** — borderless window at the desktop level, passes through mouse events
- **`DesktopWindowManager`** — creates/destroys windows per display, manages renderer lifecycle
- **`VideoRenderer`** — AVFoundation-based video playback with seamless looping
- **`WebRenderer`** — WKWebView with injected JavaScript API polyfill
- **`SceneRenderer`** — OpenGL 3.3 renderer using linux-wallpaperengine via C bridge, CVDisplayLink-driven at 30fps
- **`OcclusionDetector`** — pauses rendering when the desktop is fully covered
- **`CursorTracker`** — global mouse event monitor for interactive/parallax wallpapers
- **`PerformanceMonitor`** — frame timing ring buffer and lifecycle event logger
- **`PackageParser`** — extracts Wallpaper Engine `.pkg` archives
- **`GalleryView`** — SwiftUI grid browser for installed wallpapers

## License

This project uses [linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine) as a submodule for future scene wallpaper support.
