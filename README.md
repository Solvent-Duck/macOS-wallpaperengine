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
- Swift 5.9+

## Building

```bash
swift build
```

## Usage

### Launch

```bash
# Launch with menu bar controls
.build/debug/WallpaperEngine

# Launch and immediately load a wallpaper
.build/debug/WallpaperEngine "/path/to/wallpaper/directory"
```

The app runs as a menu bar accessory — look for the photo icon in the menu bar.

### Menu Bar

| Item | Shortcut | Description |
|------|----------|-------------|
| Browse Wallpapers… | Cmd+B | Open the gallery window to pick from installed wallpapers |
| Select Wallpaper… | Cmd+O | Open a file picker to load any wallpaper file or directory |
| Pause / Resume | Cmd+P | Toggle wallpaper playback |
| Mute / Unmute Audio | Cmd+M | Toggle wallpaper audio (muted by default) |
| Clear Wallpaper | | Remove the current wallpaper |
| Quit | Cmd+Q | Exit the application |

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
| Scene | Not yet implemented | Proprietary format (planned via linux-wallpaperengine port) |
| Application | Not supported | Windows executables — not feasible on macOS |

**Note:** WebM video is not yet supported (requires ffmpeg/libvpx integration).

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
- **`SceneRenderer`** — stub for future linux-wallpaperengine C++ integration
- **`OcclusionDetector`** — pauses rendering when the desktop is fully covered
- **`PackageParser`** — extracts Wallpaper Engine `.pkg` archives
- **`GalleryView`** — SwiftUI grid browser for installed wallpapers

## License

This project uses [linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine) as a submodule for future scene wallpaper support.
