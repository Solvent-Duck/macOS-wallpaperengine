# Steam Workshop Sync Plan

Goal: Workshop integration matching the Windows Wallpaper Engine app. Subscribing anywhere
(Steam client, website or our app) makes the wallpaper show up in the library. Unsubscribing
removes it. Updates arrive on their own, and users can browse and subscribe from inside the
library window.

Prerequisite (assumed): Steam is running on the Mac and logged in with an account that owns
Wallpaper Engine (app ID 431960).

Branch: `workshop/steam-sync`, cut from `gui/phase0` (`9bc7992`, PR #1). It builds on the GUI
overhaul (`AppModel`, `LibraryFolders`, the library window and inspector, Settings). Rebase it
onto `main` once PR #1 merges.

## Why this is feasible

- Wallpaper Engine's Workshop support is Steam's UGC API (`ISteamUGC`). Steam does all
  downloading and storage; the app only subscribes, queries and reacts to callbacks.
- The Steamworks SDK ships `libsteam_api.dylib` for macOS. `SteamAPI_Init` checks that the
  account owns the app ID, not which platform the app was built for.
- Workshop items are platform-neutral data (`project.json`, `.pkg`, video, web files).
- Evidence on the dev Mac: Steam already manages 431960 content. There are 471 items in
  `steamapps/workshop/content/431960`, tracked in `steamapps/workshop/appworkshop_431960.acf`
  (with `NeedsDownload 1`, `LastBuildID 0`).

## What the GUI branch already gives us

| Existing piece | Where | What it means for Workshop sync |
|---|---|---|
| `LibraryFolders.defaultDirectories`: `~/Wallpaper Projects` first, then one hardcoded workshop path | `GalleryWindowController.swift:63` | Replace the hardcoded path with every library found in `libraryfolders.vdf`. Keep the order: copies still win over duplicates through `seenNames`. |
| `GalleryViewModel.scan(directories:)`: full rescan, guarded by `scanGeneration` | `GalleryViewModel.swift:137` | Needs incremental `upsert(folder:)` / `remove(folder:)` so a watcher event doesn't trigger a full rescan. Tag and type counts must update too. |
| `LibraryFilter` and the sidebar sections Library / Types / Tags | `GalleryView.swift:295` | Add a "Steam Workshop" section: a *Browse* entry (Phase 3) and a *Downloading* entry while downloads are active. |
| The inspector already detects a Workshop ID (all-digit folder name) and links to its page | `LibraryInspector.swift:74,137` | This is where Unsubscribe, download progress and Open in Steam go. |
| Saved properties and playback settings are keyed by **folder name** | `DesktopWindowManager.swift:507` | Workshop folder name = item ID, so customizations survive updates and moving to another Steam library. No migration needed. |
| Recents and restore-at-launch skip paths that no longer exist | `RecentWallpapers.swift:30,58` | Unsubscribed items already drop out of recents and won't be restored. |
| `AppModel.refresh` only runs on a 1 s timer while a window is open | `AppModel.swift:92` | The watcher must not ride on this timer. An item can update while no window is open, and the active wallpaper still has to reload. |
| A Settings "Wallpaper Library" section lists the scanned folders | `SettingsView.swift:92` | Add a "Steam Workshop" section beside it: Steam status, SDK path, and the sync toggle. |
| A custom library folder **replaces** the defaults | `LibraryFolders.directories` | Open question: should Workshop folders still be scanned when a custom folder is set? Proposal: keep replace semantics for the gallery, but let SDK sync keep running and the Browse view still show installed state. |

## Phase 0 — SDK test (go/no-go, 1–2 days)

A throwaway command-line target, `SteamWorkshopProbeTool`, kept local and never shipped.

- Load `libsteam_api.dylib` with `dlopen` from a path the user provides (we can't
  redistribute it; see Risks).
- Set `SteamAppId=431960` / `SteamGameId=431960` in the environment, then call
  `SteamAPI_Init`.
- Exercise:
  - `GetNumSubscribedItems` / `GetSubscribedItems`
  - `GetItemState`, `GetItemInstallInfo`, `GetItemDownloadInfo`
  - `DownloadItem(id, highPriority: true)` on an item that is subscribed but not installed
  - `SubscribeItem` / `UnsubscribeItem` round-trip on a test item
  - one `CreateQueryAllUGCRequest` page (titles, preview URLs, tags)
- Write down the side effects:
  - "In-game: Wallpaper Engine" status in Steam
  - what happens if the Windows app is also running under the same account elsewhere
  - whether `SteamAPI_Shutdown` clears the status right away

**Go:** init succeeds, the subscribed list matches the website, `DownloadItem` delivers files
to `GetItemInstallInfo`'s folder, and the install callback fires.
**No-go:** ship Phase 1 only and drop Phases 2–4.

## Phase 1 — Passive sync without the SDK (ships regardless)

New target `SteamLibrary` (pure Swift, no Steam dependency):

- `VDFParser`: parses Valve's KeyValues text format. Covered by unit tests on a real
  `libraryfolders.vdf` and `appworkshop_431960.acf` (fixtures stripped of personal data).
- `SteamLibraryLocator`: finds the Steam root, reads every library `path` from
  `libraryfolders.vdf`, and returns each `<lib>/steamapps/workshop/content/431960` that exists.
- `WorkshopManifest`: reads `WorkshopItemsInstalled` from each library's
  `appworkshop_431960.acf` (id → size, `timeupdated`, manifest).
- `WorkshopFolderWatcher`:
  - an FSEvents stream on each content folder plus its `.acf`
  - debounced, and emits `added(id)` / `removed(id)` / `updated(id)` by comparing against the
    last snapshot (folder listing plus manifest `timeupdated`)
  - ignores folders Steam is still writing (the manifest entry is missing, or `downloads/`
    still holds the id)

App integration:

- `LibraryFolders.defaultDirectories` = `~/Wallpaper Projects` followed by
  `SteamLibraryLocator`'s folders. Settings → Wallpaper Library then lists every Steam library
  automatically.
- `GalleryViewModel` gains `upsert(folder:)` and `remove(folder:)`. These keep `wallpapers`,
  tag/type counts, `selectedPath` and `allTags` consistent, and respect the copy-wins
  duplicate rule.
- A `WorkshopLibraryMonitor`, owned by `AppDelegate`/`AppModel` and running for the app's
  whole lifetime:
  - feeds watcher events into `GalleryViewModel`
  - `updated(id)` for the active wallpaper → `AppModel.load(url, reportsErrors: false)`
    reloads it, keeping its saved properties and playback settings (keyed by folder name)
  - `removed(id)` for the active wallpaper → `AppModel.clearWallpaper()`, plus a notification
    explaining it was unsubscribed or removed from Steam

**Acceptance:**
- `swift test` passes the new parser/locator/watcher tests and the `GalleryViewModel`
  upsert/remove tests.
- Manual check: subscribe on the website → once Steam downloads it, it appears in the open
  library window without a relaunch. Unsubscribe → it disappears, and the active wallpaper is
  cleared cleanly.

**Limitation:** Steam may not download 431960 items until something asks for them. That's
what Phase 2 fixes.

## Phase 2 — Active sync through the SDK (after Phase 0 says go)

### `SteamWorkshopHelper` (separate executable)

- Separate process, so a fault in `libsteam_api` can't take the renderer down. It can also
  quit when idle, which clears the "In-game" status.
- C wrapper target `CSteamFlat`: declares the handful of `steam_api_flat.h` functions we use,
  resolved with `dlsym`. Same pattern as `CScriptHost`, but with no link-time dependency, so
  the app builds and runs without the SDK.
- Runs `SteamAPI_RunCallbacks` on a ~100 ms timer. Turns these callbacks into messages:
  - `RemoteStoragePublishedFileSubscribed_t`
  - `RemoteStoragePublishedFileUnsubscribed_t`
  - `ItemInstalled_t`
  - `DownloadItemResult_t`
- Messages: `subscribed`, `itemState`, `download(id)`, `subscribe(id)`, `unsubscribe(id)`,
  `query(page, filters)`, `progress(id, bytes, total)`, `shutdown`.
- Transport: JSON lines over stdin/stdout to start with, because XPC services need an app
  bundle layout the SwiftPM build doesn't produce yet. Move to XPC if the app gets proper
  bundling.

### `WorkshopSyncService` (in the app)

- Starts the helper when **Settings → Steam Workshop → Sync subscriptions** is on (off by
  default) and the dylib path is valid. Settings shows status: Steam not running / SDK not
  found / syncing / up to date.
- On start and on each subscribe/unsubscribe callback, compares the subscribed set with
  what's installed:
  - missing or `NeedsUpdate` → `DownloadItem`
  - unsubscribed → Steam deletes the content, and the Phase 1 watcher handles the gallery
- Progress from `GetItemDownloadInfo` appears:
  - on gallery tiles, as a placeholder tile for items not installed yet
  - in the inspector
  - in a sidebar *Downloading* entry while anything is downloading
- Tags: the `tags.json` sidecar is currently the only tag source for Workshop folders
  (`GalleryViewModel.swift:192`). The SDK can provide real tags (`GetQueryUGCTag`) for
  subscribed items, cached alongside it. Nice to have, not required.
- Passive mode (Phase 1) stays the fallback whenever the helper isn't running.

**Acceptance:**
- Subscribing on the website brings the item into the library within ~1 min, with the app
  running and nothing else touched.
- A Workshop update to the active item reloads it with its customizations intact.
- Killing the helper process doesn't affect the running wallpaper.

## Phase 3 — In-app Workshop browsing

- A sidebar entry, *Steam Workshop → Browse*, replaces the grid with a remote grid built
  natively on `CreateQueryAllUGCRequest`:
  - sort options: trending, most popular, most recent, most subscribed
  - the existing search field drives the query text
  - tag filters, paging
  - preview images fetched from the returned URLs
- The inspector, for a remote item: preview, title, author, description, vote score, and a
  **Subscribe** button in place of **Apply**. Once installed, the same inspector switches to
  the local wallpaper (Apply, properties, playback), so one wallpaper never has two inspectors.
- For local Workshop items, the inspector gets an **Unsubscribe** button (with confirmation)
  next to Favorite and Show in Finder.
- Compatibility badge, taken from the Workshop type tag (Scene / Video / Web / Application):
  - Application items hidden by default
  - once installed, the existing `supportReportLine` compatibility line takes over
- Native rather than an embedded `steamcommunity.com` web view: no second Steam sign-in, and
  the app never handles credentials.
- Keyboard navigation and accessibility labels match the phase 5 GUI work (arrow-key grid,
  Return to subscribe/apply).

## Phase 4 — Polish (optional)

- Vote up/down and Workshop favorites (`SetUserItemVote`, `AddItemToFavorites`) in the
  inspector.
- Unsubscribe from a tile's context menu.
- Workshop link in the inspector opens `steam://url/CommunityFilePage/<id>` when Steam is
  running, with the current web URL as fallback.
- A menu bar popover hint while downloads are running.

## Explicitly out of scope

- Uploading/publishing (`CreateItem`, `SubmitItemUpdate`).
- Steam Cloud sync of the Windows app's settings and playlists (it uses its own format).
- The Steam overlay.
- Multi-monitor (already marked unsupported).

## Risks and open questions

| Risk | Impact | Mitigation |
|---|---|---|
| `SteamAPI_Init` or `DownloadItem` refuses a Windows-only app on macOS | Phases 2–4 can't happen | Phase 0 settles it before any real work; Phase 1 is still useful |
| Using another developer's app ID breaches the Steamworks terms if distributed | Can't ship publicly | Personal builds only, SDK sync off by default; contact the Wallpaper Engine developer before any public release |
| SDK binaries can't be redistributed | Repo can't vendor it | `dlopen` from a user-supplied path set in Settings; a docs page explains how to get the SDK |
| "In-game: Wallpaper Engine" status and a single session at a time | Annoying; may conflict with a Windows PC on the same account | Helper runs only while syncing or browsing, then calls `SteamAPI_Shutdown` |
| Folders seen mid-download | Broken gallery entries | Watcher ignores ids still in `downloads/` or missing from the manifest |
| PR #1 changes before merging | Rebase conflicts | Keep changes to GUI files small and additive (new sidebar section, new inspector buttons, a new settings section) |
| Custom-folder semantics (open question above) | Users with a custom folder lose Workshop items | Decide before Phase 1 lands; the proposal is in the table above |

## Files (expected)

- New: `Sources/SteamLibrary/` (`VDFParser`, `SteamLibraryLocator`, `WorkshopManifest`,
  `WorkshopFolderWatcher`)
- New: `Sources/CSteamFlat/`, the dlsym wrapper
- New: `Sources/SteamWorkshopHelper/` (main, callback pump, JSON-lines IPC)
- New: `Sources/WallpaperEngine/` (`WorkshopLibraryMonitor`, `WorkshopSyncService`,
  `WorkshopBrowseView`)
- Changed:
  - `GalleryWindowController.swift` (`LibraryFolders`)
  - `GalleryViewModel.swift` (upsert/remove, browse filter)
  - `GalleryView.swift` (sidebar section)
  - `LibraryInspector.swift` (Unsubscribe, progress, remote mode)
  - `SettingsView.swift` (Steam Workshop section)
  - `AppModel.swift` (monitor and sync ownership)
- Tests: `Tests/SteamLibraryTests/`, plus `GalleryViewModel` upsert/remove tests in
  `WallpaperEngineTests`
- `Package.swift`: new targets
