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

## Phase 0 — SDK test: PASSED (2026-10-08)

The probe was a throwaway C++ program built against `~/sdk` (Steamworks SDK, `SteamUGC_v021`),
with `SteamAppId=431960` set in its environment. No `steam_appid.txt` was needed.

| Check | Result |
|---|---|
| `SteamAPI_InitEx` | OK. `GetAppID` = 431960; ownership check passed; `BIsAppInstalled` = false (doesn't matter) |
| Subscribed items | 711 subscribed / 472 installed / 239 never downloaded by Steam itself. `GetItemInstallInfo` returns the `content/431960/<id>` folder |
| `DownloadItem` on a never-downloaded item | Accepted. About 40 s later (12.8 MB): `ItemInstalled_t` and `DownloadItemResult_t` (OK) fired; folder has `project.json`, `scene.pkg`, `preview.jpg` |
| `CreateQueryAllUGCRequest` (trending) | OK. 50 per page, 3.2M total; titles, tags, votes and preview URLs returned |
| `SubscribeItem` / `UnsubscribeItem` | **Not run.** It changes the account; run it on a throwaway item with the user's OK |
| "In-game" status, conflict with a Windows PC on the same account | **Not observed** (headless run); check by eye during Phase 2 |

Findings that change the design:
- **The subscription list is empty right after Steam launches.** The first run (seconds after
  Steam started) reported 0 subscriptions; the next run reported 711. Sync must wait until
  the list is populated (retry with backoff) and must never treat "0 subscribed" as
  "everything was unsubscribed".
- **Steam doesn't download 431960 items on its own.** Of 711 subscriptions, 239 sat
  undownloaded (state `Subscribed|NeedsUpdate`). Active sync (Phase 2) is what makes
  subscribing actually deliver wallpapers.
- **Subscriptions are readable without the SDK.**
  `Steam/userdata/<accountid>/ugc/431960_subscriptions.vdf` lists every subscribed id (711,
  matching the SDK). Phase 1 can show subscribed-but-not-downloaded items, and the plan should
  pick the account folder by the logged-in user (two accounts exist under `userdata/` here).
- **`GetItemDownloadInfo` reports 0/0 while an item is waiting to download.** The UI needs a
  "Queued" state, not just a progress bar.
- **The default catalogue query includes Mature items** (Wallpaper Engine tags its content
  rating as Everyone / Questionable / Mature). Browse must filter by rating, defaulting to
  Everyone, with a setting to change it.
- **`libsteam_api.dylib`'s install name is `@loader_path`.** Either copy it next to the
  helper binary (from the user's SDK path) or `dlopen` it by absolute path.
- **Starting a session makes Steam download every pending subscription.** About 10 minutes
  after the probe sessions, Steam had installed the pending items (245 new folders) on its
  own (content folder 20.6 GB → 46 GB), with no further `DownloadItem` calls. Active sync may
  only need a running session plus `DownloadItem` for stragglers. The first sync must warn
  about size, because subscriptions can add up to tens of GB.
- **Some subscriptions can never download.** `DownloadItem(920933904)` returned
  `k_EResultAccessDenied` (15): the item is removed or private. Record failures and don't
  retry them in a loop; show them as "Unavailable".
- **`GetItemState` can claim an item is installed when its folder is gone.** Three items
  reported `Installed` with a `GetItemInstallInfo` folder that doesn't exist on disk. Sync
  must check that the folder exists and call `DownloadItem` to repair it.

## Phase 1 — Passive sync without the SDK (done)

Status (2026-10-08): committed on `workshop/steam-sync`.
- `SteamLibrary` target: `VDF`, `SteamLibraryLocator`, `WorkshopManifest`,
  `WorkshopSubscriptions`, `WorkshopSnapshot`, `WorkshopFolderWatcher`.
- `GalleryViewModel.refreshFolder(named:)`.
- `AppModel.startWorkshopMonitoring()`, started by `AppDelegate`.
- A subscription count in Settings.

Changes from the plan:
- **No notification when the active wallpaper is removed.** The app is an unbundled SwiftPM
  executable, so `UNUserNotificationCenter` isn't available; the desktop just clears.
- **"Not downloaded" placeholder tiles are deferred to Phase 2**, where they can show download
  state. Phase 1 shows the count in Settings instead.
- **The incremental update API is a single `refreshFolder(named:)`, not separate
  `upsert`/`remove`.** It re-resolves the name across library folders, so removing a copy
  reveals the Workshop item underneath it.

Live check against real Steam: the watcher reported 711 subscribed, 708 installed and 4 not
downloaded. These counts match the files on disk; the SDK's figure of 1 not downloaded is
stale (see the Phase 0 findings).

New target `SteamLibrary` (pure Swift, no Steam dependency):

- `VDFParser`: parses Valve's KeyValues text format. Covered by unit tests on a real
  `libraryfolders.vdf` and `appworkshop_431960.acf` (fixtures stripped of personal data).
- `SteamLibraryLocator`: finds the Steam root, reads every library `path` from
  `libraryfolders.vdf`, and returns each `<lib>/steamapps/workshop/content/431960` that exists.
- `WorkshopManifest`: reads `WorkshopItemsInstalled` from each library's
  `appworkshop_431960.acf` (id → size, `timeupdated`, manifest).
- `WorkshopSubscriptions`: reads `userdata/<accountid>/ugc/431960_subscriptions.vdf` for the
  logged-in account (SteamID64 from `config/loginusers.vdf` minus 76561197960265728). The library can then show
  subscribed items Steam hasn't downloaded, as "Not downloaded" placeholders.
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

## Phase 2 — Active sync through the SDK

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
  what's installed. It waits until the subscription list is populated (it reads 0 right
  after Steam launches) and never acts on an empty list. Downloads are queued a few at a
  time; the first sync here is 239 items:
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
  - a content-rating filter (Everyone / Questionable / Mature tags), defaulting to Everyone
    and changeable in Settings
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
