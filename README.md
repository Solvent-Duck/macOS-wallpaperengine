# macOS Wallpaper Engine

A macOS application that plays animated [Wallpaper Engine](https://store.steampowered.com/app/431960/Wallpaper_Engine/) wallpapers as your desktop background. Supports video, web, and native Metal scene rendering with a menu bar interface and visual gallery browser. Windows rendering and feature parity are in progress; see the [parity progress report](docs/WINDOWS_PARITY_PROGRESS.md) for verified results and remaining gaps. Application wallpapers are excluded.

## Features

- **Video wallpapers** — MP4, MOV, M4V with seamless looping
- **Web wallpapers** — HTML/JS/CSS bundles with Wallpaper Engine JavaScript API polyfill
- **Multi-monitor support** — one wallpaper window per connected display
- **Smart power management** — automatically pauses rendering when the desktop is covered
- **Wallpaper library** — SwiftUI window with a sidebar (favorites, recent, types, tags), a thumbnail grid and an inspector for details, Apply and per-wallpaper settings
- **Menu bar controls** — pause/resume, mute/unmute audio, clear wallpaper, open gallery
- **Package support** — reads Wallpaper Engine's `.pkg` archive format

## Requirements

- macOS 26.0 or later
- Xcode Command Line Tools (`xcode-select --install`)
- Swift 6.2+
- CMake 3.12+ (`brew install cmake`)
- Homebrew dependencies (see below)

## Building

For development checks, fixture paths, and evidence retention, start with the
[development procedure](docs/DEVELOPMENT_PROCEDURE.md). The [documentation index](docs/README.md)
separates current guidance from historical implementation reports.

### 1. Install dependencies

```bash
# Xcode Command Line Tools (if not already installed)
xcode-select --install

# CMake and runtime dependencies
brew install cmake ffmpeg
```

### 2. Build and run

```bash
./run.sh
```

`run.sh` handles everything in order:
1. Checks and incrementally builds the vendored shader compiler and script libraries (`./build-bridge.sh`), including changed configuration and patches
2. Compiles the Swift app (`swift build -c release`)
3. Launches the binary

The app uses the owned Swift scene runtime. The vendored libraries provide glslang, SPIRV-Cross, and QuickJS; there is no upstream rendering bridge in the app. Build configuration lives in `cmake/dependencies`; the QuickJS patch is applied to a generated copy under `build/`, leaving the dependency checkout clean.

#### Manual build steps (if needed)

If you want to build without launching, or need a clean rebuild:

```bash
# Step 1 — vendored dependencies (once, or when their source changes)
./build-bridge.sh

# Step 2 — Swift app
swift build -c release
```

The release executable is at `.build/release/WallpaperEngine`.

### Troubleshooting

| Problem | Fix |
|---------|-----|
| `cmake: command not found` | `brew install cmake` and put Homebrew's `bin` directory on `PATH` |
| Missing `glslang`, `spirv-cross`, or `qjs` library | Run `./build-bridge.sh` before `swift build` |
| `submodule update --init` hangs | Check network; the engine has ~9 nested submodules to clone |
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

**Quit behavior:** quit handling is routed through the menu bar popover's power button. The app tears down renderers and explicitly finalizes glslang before exiting.

### Menu Bar

Clicking the menu bar icon opens a popover with:

| Control | Description |
|---------|-------------|
| Now playing | Current wallpaper preview, title and status (playing, paused and why, loading) |
| Pause / Mute / Customize | Toggle playback, toggle wallpaper audio (muted by default), open the wallpaper's properties |
| Recent | The last eight wallpapers; click one to apply it |
| Browse Wallpapers… / folder button | Open the wallpaper library, or pick any wallpaper file or directory |
| Clear Wallpaper | Remove the current wallpaper (it is then not restored at next launch) |
| Settings (gear) | Startup, library folder, audio response, now-playing source, diagnostics |
| Quit (power) | Exit the application |

The last wallpaper is restored when the app starts (turn this off in Settings). Settings can also add a login item, which starts the executable you launched from.

### Wallpaper Library

Click **Browse Wallpapers…** in the menu bar popover to open the library window. It scans `~/Wallpaper Projects/` and the Steam Workshop folder for installed wallpaper directories containing a `project.json` file (metadata only, so it takes well under a second); choose a different folder in Settings.

- **Sidebar** — All, Favorites, Recent, then each wallpaper type and tag with counts
- **Grid** — preview thumbnails; the active wallpaper is badged; ♡ toggles a favorite; right-click for Apply / Favorite / Show in Finder
- **Inspector** — large preview, type, Workshop link, tags, description, **Apply**, and the wallpaper's settings. Settings of the active wallpaper apply live; others are saved and used when the wallpaper is applied.

Click a card to inspect it; double-click to set it as your desktop background. **Customize** in the menu bar popover opens the library on the active wallpaper.

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
| Scene | Partial parity | Proprietary format via the native Swift/Metal scene runtime |
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
- **`SceneRenderer`** — native Swift scene runtime and Metal renderer at 30fps
- **`OcclusionDetector`** — pauses rendering when the desktop is fully covered
- **`CursorTracker`** — global mouse event monitor for interactive/parallax wallpapers
- **`PerformanceMonitor`** — frame timing ring buffer and lifecycle event logger
- **`PackageParser`** — extracts Wallpaper Engine `.pkg` archives
- **`GalleryView`** / **`LibraryInspector`** — SwiftUI wallpaper library (sidebar, grid, inspector with properties)
- **`AppModel`** / **`MenuBarPopover`** / **`SettingsView`** — app state, menu bar popover and settings window

## License

This project currently vendors compatibility/runtime code from [linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine), but the long-term direction is a standalone macOS-native scene runtime.
