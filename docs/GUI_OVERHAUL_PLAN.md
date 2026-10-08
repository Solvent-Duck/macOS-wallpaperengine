# GUI / UX Overhaul Plan

Status (2026-10-07): phases 0–4 implemented (4 = playback controls only;
multi-monitor marked unsupported), phase 5 in progress — keyboard navigation,
drop-to-apply, first-run library guidance and accessibility labels done; Quick
Look-style preview not done. Originally a proposal.

Scope: `Sources/WallpaperEngine` UI layer only
(AppDelegate, Gallery*, PropertiesView, WallpaperProperty, DesktopWindowManager's
UI-facing API). Renderer parity work is out of scope except where a control has no
backend at all.

## 1. Current state (audited)

The UI is ~1.2k lines across three disconnected surfaces: a status-bar `NSMenu`
(AppDelegate.swift), a SwiftUI gallery in an `NSWindow` (GalleryView.swift), and a
SwiftUI properties `NSPanel` (PropertiesView.swift). They share no model; each pulls
state from `DesktopWindowManager` on demand and pushes callbacks back.

Corpus numbers below come from the 470 local projects (421 scene, 45 video, 1 web)
holding 6,401 authored properties.

### Broken or missing: wallpaper controls

| # | Problem | Impact |
|---|---------|--------|
| C1 | `condition` (show-if expressions) is never parsed | 2,109 of 6,401 properties (33%) should be hidden until a parent toggle or combo enables them. All of them show at once, so the panel is a wall of irrelevant controls. |
| C2 | Unknown types are dropped silently: `group` (236), `usershortcut` (157), `label` (8), capitalized `Text` (85), and missing or empty types (27) | Section structure is lost; labels vanish |
| C3 | `text` labels render raw, including WE's HTML (`<b>`, `<br>`, links) | Ugly, unreadable |
| C4 | `file` / `scenetexture` (112) are plain text fields | Can't pick an image; the user has to type a path |
| C5 | Each slider or colour tick calls `applyProperty`, which writes to UserDefaults and makes the scene rebuild the **entire** override map | Drag lag and disk churn |
| C6 | Video wallpapers (45) get **no** controls. WE's general settings (volume, playback rate, scaling/fill mode, alignment) aren't implemented for any type | Most-requested basic controls are missing |
| C7 | Web `applyGeneralProperties` is hard-coded (`fps:30, muted:false, volume:100`) and ignores the real mute/volume | Mute toggle lies to web wallpapers |
| C8 | Persistence key is the absolute directory path | Settings are lost if the library moves |

### Broken or missing: app shell

| # | Problem |
|---|---------|
| A1 | The gallery scans `~/Library/.../workshop/content/431960`, but USER_GUIDE says `~/Wallpaper Projects/`. No UI can set the `wallpaperDirectory` default, and an empty or wrong folder just shows "No wallpapers found". |
| A2 | Load errors (bad project, unsupported `preset`/`application`, WebM transcode failure) only `print()` to stdout. Clicking a card can silently do nothing. |
| A3 | WebM transcode (`WebMTranscoder.transcode`) runs synchronously on the main thread inside `loadWallpaper`, which freezes the UI. |
| A4 | The gallery uses `ForEach(... id: \.offset)` (wrong identity on filter/sort) and calls `NSImage(contentsOf:)` synchronously in the view body (scroll jank at 470 items). GIF previews are static. |
| A5 | No indication of the active wallpaper anywhere in the gallery. A click applies immediately, with no preview, details or confirmation. |
| A6 | Closing the gallery sets activation policy to `.accessory` even if the properties panel is open, so the panel loses focus and the Dock icon vanishes underneath it. |
| A7 | Pause state is duplicated (`AppDelegate.isPaused` vs `DesktopWindowManager.isManuallyPaused`). Occlusion and sleep don't update the menu. |
| A8 | The last wallpaper isn't restored on launch (only the `run.sh <path>` CLI arg), and there's no launch-at-login. As a daily driver it's useless after a reboot. |
| A9 | One wallpaper is mirrored to every display. There's no per-display assignment. **Decision (2026-10-07): multi-monitor is unsupported for now; A9 is out of scope.** |
| A10 | The menu is a flat dump: status lines shown as disabled items, debug actions (Copy Diagnostics) beside user actions, and Audio Response / Media Integration exposed as top-level concepts. |

## 2. Target design

Platform is macOS 26 (Package.swift), so use current SwiftUI throughout: `@Observable`,
`MenuBarExtra(.window)`, `Window`/`Settings` scenes, `NavigationSplitView`, and the
system glass materials. Drop the hand-built NSMenu/NSPanel/NSWindow plumbing.

### Surfaces (three, each with one job)

1. **Menu bar popover** (`MenuBarExtra`, window style), for quick control:
   - Current wallpaper thumbnail and title, with a status line (Playing / Paused: occluded / Paused: battery).
   - Transport row: pause/resume, mute, volume slider.
   - Strip of the 6–8 most recent wallpapers, applied with one click.
   - Buttons: "Open Library…" and "Customize…", which jumps to the inspector for the current wallpaper.
   - Footer: Settings and Quit.
2. **Library window** (`Window` scene, `NavigationSplitView`), the main app:
   - Sidebar: All, Favorites, Recent, then Type (Scene/Video/Web), then Tags (collapsible, with counts). Replaces the horizontal chip rows.
   - Content: lazy grid with async, cached thumbnails (animated GIF on hover). A badge marks the active wallpaper (per display). Toolbar has search, sort and grid size.
   - Inspector (`.inspector`): large preview, title, author, type, workshop ID, tags, and compatibility (from `supportReportLine`). Below that sit an **Apply** button with a display picker, then that wallpaper's **properties** (the same view as surface 3). You can customize a wallpaper before applying it, and live edits show when it's active.
3. **Settings** (`Settings` scene), with tabs:
   - General: library folders (multiple, add/remove; both default locations auto-detected), launch at login (`SMAppService`), restore on launch.
   - Playback: pause when another app is fullscreen / on battery / on low power, FPS cap, default mute.
   - Audio and Media: the current Audio Response and Media Integration menus, moved here with their status text and the Connect buttons.
   - Displays: ~~same wallpaper on all displays vs per-display~~ — shows "Multiple displays: not supported yet" (multi-monitor out of scope).
   - Advanced: Copy Diagnostics, reveal logs, reset all wallpaper settings.

The floating Properties panel goes away. Customization lives in the Library inspector,
and the popover's "Customize…" deep-links to it.

### Single source of truth

Add an `@Observable @MainActor final class AppModel` that owns:
- `library: LibraryStore`: scanning, cached `WallpaperProject` list, favorites, recents, and thumbnail cache.
- `playback: PlaybackState`: active project per display, paused reason(s), mute, volume, and the last error.
- `settings`: an `@AppStorage`-backed struct.
- A `DesktopWindowManager` reference. The manager reports state changes (pause reasons, load success or failure) through callbacks or `AsyncStream`, not via polling in `menuWillOpen`.

AppDelegate shrinks to lifecycle and automation mode. Views read `AppModel`, so all
three surfaces stay consistent automatically (fixes A7).

### Properties engine (fixes C1–C5, C8)

- Extend `WEPropertyType` with `group`, `usershortcut` (shown read-only as a hint), and `label`. Parse the type case-insensitively and fall back to `.text` instead of dropping the property.
- Parse `condition` into a small expression evaluator over the current values. WE conditions are JS-like (`prop.value == true`, `a.value == 2 && b.value`). A tokenizer plus a recursive-descent parser for `== != && || ! ( )` with bool/number/string literals covers it, and conditions that fail to parse default to visible. Unit-test it against every condition string in the corpus.
- `group` starts a collapsible `Section`. A `text`/`label` becomes footnote text with HTML stripped to an `AttributedString` (bold and links kept).
- `file` / `scenetexture` get a picker button with a thumbnail and a clear button. Store the bookmark data so the sandbox stays future-proof.
- Coalesce edits. The UI updates immediately, the renderer gets updates throttled to about one per frame, and persistence is debounced (500 ms). Scene apply is incremental: `updatePropertyOverrides` with only the changed key, if `NativeSceneRenderer` supports a delta, otherwise add one.
- Persistence key: workshop ID when present, else the directory name. Migrate old path keys on first load.
- Per-property reset (context menu or a ↺ shown when the value differs from the default), plus "Reset All".

### General (WE "playback") controls (fixes C6, C7)

Add to the `WallpaperRenderer` protocol: `volume: Float`, `playbackRate: Float`, and
`scaling: .fill/.fit/.stretch/.center`, plus alignment for scenes if the aspect fix
lands (see the known "no aspect policy" bug).
- Video: `AVPlayer.volume` / `rate` and `AVPlayerLayer.videoGravity`, which is trivial.
- Web: pass the real `applyGeneralProperties` payload (fps, muted, volume).
- Scene: pass volume to `SceneSoundPlayer`. Scaling depends on the aspect-policy work. Expose it only once that is implemented, and don't ship a dead control.

These show as a fixed "Playback" section at the top of every inspector, above the
authored properties.

## 3. Phases

Each phase can ship independently. The order front-loads visible wins and real bugs.

**Phase 0: bug fixes in the current UI (about 1 day, no redesign)**
A1 (auto-detect both library paths and add a Choose Folder button to the empty state),
A2 (NSAlert or banner on load failure), A3 (move the transcode off the main thread with a
progress indication), A4 (stable `id`, async thumbnails), A6, A7, C5 throttle/debounce,
C7. These are small, independent and testable, and they make the current UI usable while the rest is built.

**Phase 1: properties engine (about 2–3 days)**
`condition` parser and evaluator with corpus-driven tests, new types, groups/sections,
HTML labels, file pickers, incremental apply, the new persistence key and migration, and
per-property reset. Delivered inside the *existing* panel first, so it's verifiable on
its own.

**Phase 2: AppModel and app shell (about 2 days)**
Introduce `AppModel` and a SwiftUI `App` entry point with `MenuBarExtra`, the `Settings`
scene and the `Window` scene. Keep `NSApplicationDelegateAdaptor` for lifecycle and
automation. Move the menu functionality into the popover and Settings, and delete the NSMenu code.
Add restore-on-launch and launch-at-login (A8).

**Phase 3: Library window (about 2–3 days)**
NavigationSplitView with sidebar, grid and inspector. Favorites, recents, a
thumbnail cache, an active badge, and the Apply flow. The properties view moves into the
inspector, and the NSPanel is deleted.

**Phase 4: playback controls and displays (about 2 days)** — *done for playback (C6);
per-display assignment (A9) dropped: multi-monitor is marked unsupported.*
General controls (C6) for video and web, then scene volume. Per-display assignment (A9)
requires `DesktopWindowManager` to hold a project and renderer per window instead of
one project for all of them. That's the largest backend change in the plan, so it goes last.

**Phase 5: polish**
Keyboard navigation in the grid (arrows, Return to apply, Space for Quick Look-style
preview), drag-a-folder-to-import, onboarding for the first-run empty library, accessibility
labels, and dark/light/glass checks.

## 4. Verification

- Unit tests (`Tests/`): condition parser over every corpus condition string,
  property parsing of all type spellings, persistence migration, and edit throttling.
- Use the existing headless automation mode (`LaunchOptions.isAutomation`) to confirm
  that a property change still reaches the renderer. Capture before and after toggling a bool that
  gates a layer in a known scene.
- Manual UI pass per phase: load each type, toggle conditions, restart the app (restore),
  disconnect a display, and sleep/wake.
- No GUI test harness exists today. Adding XCUITest is out of scope, so UI checks are manual
  screenshots attached to each phase's PR.

## 5. Risks and open questions

- **Condition dialect:** confirm the corpus only uses simple comparisons. If some
  conditions call functions, fall back to visible and log them.
- **Per-display (A9)** touches renderer ownership, script storage per screen, and audio
  fan-out, so it's the one phase with real regression risk to the render path. It could be
  deferred without blocking anything else.
- **SwiftUI `App` migration** must keep automation mode working: no status item and
  deterministic exit codes. Gate scene creation on `!isAutomation`.
- **Parallel renderer work:** do the UI work on its own branch so it doesn't tangle
  with renderer passes that touch `SceneRenderer` / `DesktopWindowManager`.
