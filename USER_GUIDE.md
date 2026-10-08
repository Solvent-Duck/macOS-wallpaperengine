# macOS Wallpaper Engine — Easy User Guide

This guide is for people who know **Steam**, but do **not** know coding.

You do **not** need to understand the source code.
You **will** need to copy and paste a few commands into **Terminal** the first time.
Think of it like installing a mod loader: slightly fiddly once, then easy after that.

---

## What this app does

This project lets your Mac play **Wallpaper Engine wallpapers** as your desktop background.

It currently supports:
- **Video wallpapers**
- **Web wallpapers**
- **Scene wallpapers**

It does **not** support:
- **Application wallpapers** (Windows executable wallpapers)

After launch, it runs from the **menu bar** at the top of your screen.

---

## Before you start

You need:
- A Mac running **macOS 26 or newer**
- A Steam account with **Wallpaper Engine** wallpapers available
- Internet connection for the first setup
- About **10–20 minutes** for first-time installation

Important:
- This project is **not** yet a normal drag-and-drop Mac app installer
- First setup uses **Terminal**
- After setup, normal use is much easier

---

## Part 1 — Open Terminal

1. Press **Command + Space**
2. Type **Terminal**
3. Press **Return**

You will use Terminal to paste commands exactly as shown.

---

## Part 2 — Install the one-time requirements

### Step 1: Install Apple command line tools

Paste this into Terminal and press **Return**:

```bash
xcode-select --install
```

What happens:
- A pop-up may appear
- Click **Install**
- Wait until it finishes

If it says the tools are already installed, that is fine.

---

### Step 2: Install Homebrew if you do not already have it

Paste this into Terminal:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

If Terminal says `brew: command not found`, that means Homebrew was not installed yet.

If Homebrew is already installed, you can skip to the next step.

To check, paste:

```bash
brew --version
```

If you see a version number, you are good.

---

### Step 3: Install the tools this app needs

Paste this into Terminal:

```bash
brew install cmake ffmpeg
```

This may take a while.
That is normal.

---

## Part 3 — Go to the project folder

Paste this into Terminal:

```bash
cd /Users/isaiahbergstrom/Projects/macOS-wallpaperengine
```

You are now inside the project folder.

---

## Part 4 — Build and start the app

This is the part that looks scary but is mostly just waiting.

Paste:

```bash
./run.sh
```

What this does (automatically, in order):
1. Builds the vendored shader compiler libraries — usually **under a minute** the very first time
2. Builds the Mac app itself
3. Launches the app

You only need this one command.
On every run after the first, steps 1 and 2 are near-instant because everything is already built.

When it opens:
- You may **not** see a normal app window
- You may **not** see a Dock icon
- This is expected
- Look in the **menu bar** at the top of the screen for a **photo-style icon**

That icon is the app.

---

## Part 5 — Get your wallpapers ready

This app looks for wallpapers in this folder:

```text
~/Wallpaper Projects/
```

That means:

```text
/Users/your-name/Wallpaper Projects/
```

If the folder does not exist yet, create it with:

```bash
mkdir -p "$HOME/Wallpaper Projects"
```

---

## Part 6 — Move Steam Workshop wallpapers into the right folder

If you already download wallpapers through Steam, the important thing to understand is this:

Steam stores Workshop files in hidden folders.
This app works best when each wallpaper is copied into your **Wallpaper Projects** folder.

### The usual Steam Workshop wallpaper location

Wallpaper Engine workshop items are typically inside:

```text
~/Library/Application Support/Steam/steamapps/workshop/content/431960/
```

- `431960` is Wallpaper Engine's Steam app ID
- Inside it, each wallpaper is usually in its own numbered folder

---

### Easy way to open the Steam workshop folder in Finder

Paste this into Terminal:

```bash
open "$HOME/Library/Application Support/Steam/steamapps/workshop/content/431960"
```

Now Finder should open the workshop folder.

You will see numbered folders.
Each numbered folder is usually one wallpaper.

---

### What a valid wallpaper folder looks like

A wallpaper folder usually contains a file named:

```text
project.json
```

That file is the important bit.

Examples:

```text
1234567890/
  project.json
  preview.jpg
  wallpaper.mp4
```

or

```text
1234567890/
  project.json
  index.html
  assets/
```

If a folder has `project.json`, it is usually usable.

---

### Copy one wallpaper into Wallpaper Projects

Replace `1234567890` with the workshop item folder you want.

Paste:

```bash
cp -R "$HOME/Library/Application Support/Steam/steamapps/workshop/content/431960/1234567890" "$HOME/Wallpaper Projects/"
```

That copies the wallpaper into the folder the app scans.

If you want to copy **all** workshop wallpapers at once, paste:

```bash
cp -R "$HOME/Library/Application Support/Steam/steamapps/workshop/content/431960/." "$HOME/Wallpaper Projects/"
```

That may take a while if you have a lot of wallpapers.

---

## Part 7 — Pick a wallpaper inside the app

Once the app is running:

1. Click the **menu bar icon**
2. Click **Browse Wallpapers…**
3. The Wallpaper Library window opens
4. Click a wallpaper to see its details on the right, then click **Apply** — or just double-click it

The library scans your `~/Wallpaper Projects/` folder and Steam's Workshop folder automatically.
To use a different folder, go to **Settings → General → Choose Folder…**. Click the ↻ button to rescan after adding wallpapers.

You can also:
- Search by wallpaper name
- Use the sidebar to show Favorites, Recent wallpapers, one type (scene, video, web) or one tag
- Click the ♡ on a wallpaper to add it to Favorites
- Sort by title, type or number of tags
- Right-click a wallpaper to apply it, favorite it or show it in Finder

The wallpaper that is on your desktop right now is marked **Active**.

---

## Part 8 — Customising a wallpaper's properties

Many wallpapers expose settings — colours, speeds, toggles, and other options.

To access them:
1. Click the **menu bar icon**
2. Click **Customize** — or select any wallpaper in the Wallpaper Library

The settings appear on the right side of the library, under the wallpaper's details, grouped into sections.

The **Playback** section at the top has the same controls for every wallpaper of a type:
- **Volume** — video, web and scene wallpapers (also in the menu bar popover, under the buttons)
- **Speed** — video wallpapers, from 0.25× to 2×
- **Scaling** — video wallpapers: **Fill** (crop to fill the screen), **Fit** (show the whole video) or **Stretch**
Some controls only appear once you turn on the option they belong to.
Changes to the wallpaper on your desktop take effect immediately.
You can also change a wallpaper's settings before applying it; they are used when you apply it.
Settings are saved per wallpaper — each wallpaper remembers its own values.

To undo one change, click the ↺ arrow next to it (or right-click it and choose **Reset to Default**).
To go back to all the original settings, click **Reset All** at the bottom of the settings.

Not all wallpapers have properties; those show "This wallpaper has no settings".

---

## Part 9 — Other ways to load a wallpaper

You are not limited to the gallery.

From the menu bar icon, you can choose:

### The folder button (next to **Browse Wallpapers…**)
Use this if you want to open:
- A wallpaper folder
- A `project.json` file
- A supported video file
- A `.pkg` wallpaper package

The app can also load a wallpaper directly from Terminal when launching.

Example:

```bash
./run.sh "$HOME/Wallpaper Projects/1234567890"
```

That builds (if needed) and starts the app with that wallpaper already loaded.

---

## Part 10 — Everyday controls

Click the menu bar icon to see what is playing and to use:

- **Pause / Resume** — stop or continue playback; the wallpaper freezes in place when paused
- **Mute / Unmute** — turn wallpaper sound off or on
- **Customize** — adjust settings for the current wallpaper
- **Recent** — click a thumbnail to switch back to a wallpaper you used recently
- **Browse Wallpapers…** — open the wallpaper gallery
- The **folder** button — manually choose a wallpaper file or folder
- **Clear Wallpaper** — remove the current animated wallpaper
- The **gear** — open Settings
- The **power** button — quit the app

The app also pauses automatically when your desktop is fully covered by other windows, and resumes when it is visible again. The popover shows why it is paused.

### Settings

- **General** — restore the last wallpaper when the app starts (on by default), open the app at login, and choose the wallpaper library folder.
  Open at login starts the app from the place you ran it last; if you move the project folder, turn it off and on again.
- **Audio & Media** — audio response and now-playing sources (see below)
- **Advanced** — **Copy to Clipboard** copies technical info (frame timings, FPS, memory) for troubleshooting

---

## Multiple monitors (not supported yet)

Multi-monitor setups are **not supported yet**.
If more than one display is connected, the app currently shows the same wallpaper on every display,
but you cannot choose a different wallpaper per display, span one wallpaper across displays,
or change settings for one display only. Behaviour when displays are connected, disconnected
or rearranged while the app is running has not been tested.

---

## Audio reactivity

Some scene and web wallpapers respond to audio — they pulse, move, or change colour based on what is playing on your Mac.

Choose a source in **Settings → Audio & Media → Audio Response**:

- **System Audio** (default) responds to sound playing on your Mac. Allow the macOS
  audio recording prompt when it appears. No loopback driver is needed.
- **Microphone / Input Device** uses the default input, including an existing
  loopback device. This mode requires microphone permission.
- **Off** disables audio response.

The choice is saved between launches. Capture pauses with the wallpaper and stops
when it is removed. Audio is analyzed in memory and is not recorded to a file.
**Mute / Unmute Audio** separately controls the wallpaper's own sound output.

---

## Supported wallpaper types

### Works
- **Video wallpapers** (`.mp4`, `.mov`, `.m4v`, and some other video files)
- **Web wallpapers** (`.html`, JS, CSS bundles)
- **Scene wallpapers** (rendered natively via Metal on Apple Silicon and Intel Macs)

### Does not work
- **Application wallpapers**
  - These are basically Windows programs
  - macOS cannot sensibly run them as wallpapers here

---

## Special note about WebM videos

If a wallpaper uses **WebM** video, the app may convert it to **MP4** the first time it loads.

That is why `ffmpeg` was installed earlier.

So if first load is a bit slower once, that is not automatically a bug.
Converted files are cached, so the next load is fast.

---

## If something goes wrong

### Problem: `xcode-select --install` fails
Try:
- Restart the Mac
- Run it again
- Make sure macOS software updates are not half-installed

---

### Problem: `brew` says command not found
Homebrew is not installed yet, or it was not added to your shell path.

Try installing Homebrew first:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Then close Terminal, open it again, and test:

```bash
brew --version
```

---

### Problem: build says `library not found for -lglslang` or similar
The vendored shader compiler libraries have not been compiled yet.

Run:

```bash
./run.sh
```

That will build them automatically before building the Swift app.

---

### Problem: build says `ffmpeg: command not found` at runtime
Install ffmpeg:

```bash
brew install ffmpeg
```

ffmpeg is used to convert WebM video wallpapers to MP4 on first load.

---

### Problem: the app launches but you cannot find it
That is because it is a **menu bar app**.

Look at the top-right or top area of the screen for the icon.
There is no normal app window at startup.

---

### Problem: the wallpaper library is empty
Check these things:

1. Your wallpapers are inside:
   ```text
   ~/Wallpaper Projects/
   ```
2. Each wallpaper is in its **own folder**
3. Each wallpaper folder contains:
   ```text
   project.json
   ```

If you copied the wrong folder level, the app will not find them.

Wrong:

```text
~/Wallpaper Projects/project.json
```

Right:

```text
~/Wallpaper Projects/1234567890/project.json
```

---

### Problem: a wallpaper loads in Steam on Windows but not here
That can happen.
Some wallpapers depend on features this macOS project does not fully support yet.

Try another wallpaper first to confirm the app itself is working.

Best test wallpapers:
- Simple video wallpapers
- Simple web wallpapers
- Workshop items with obvious `project.json` and media files

---

### Problem: audio reactivity is not working
Check the status in **Audio Response**, and make sure the wallpaper is playing
and supports audio response. For **System Audio**, allow WallpaperEngine under
**System Settings → Privacy & Security → Screen & System Audio Recording**.
For **Microphone / Input Device**, check **Privacy & Security → Microphone** and
the selected input device. After granting permission, select the audio source
again to retry. The app does not change your system's default audio devices.

---

### Problem: you want a totally normal app you can double-click
At the moment, this project is still closer to a **build-it-once, then use it** tool than a polished consumer app installer.

So the honest answer is:
- It is usable
- It is not yet beginner-perfect
- A future `.app` bundle or installer would make this much friendlier

---

## Recommended first-time quick path

If you want the shortest version, do this:

1. Open **Terminal**
2. Run:
   ```bash
   xcode-select --install
   ```
3. Install Homebrew if needed
4. Run:
   ```bash
   brew install cmake ffmpeg
   ```
5. Build and launch:
   ```bash
   cd /Users/isaiahbergstrom/Projects/macOS-wallpaperengine
   ./run.sh
   ```
   This handles the shader library build, Swift build, and launch in one step.
   The first run takes under a minute. After that it's near-instant.
6. Create wallpaper folder if needed:
   ```bash
   mkdir -p "$HOME/Wallpaper Projects"
   ```
7. Open Steam's workshop storage folder:
   ```bash
   open "$HOME/Library/Application Support/Steam/steamapps/workshop/content/431960"
   ```
8. Copy wallpaper folders into:
   ```text
   ~/Wallpaper Projects/
   ```
9. In the app's menu bar icon, click **Browse Wallpapers…**

---

## Final plain-English summary

The first setup is the annoying part.
After that, normal use is simple:

- put wallpapers into `~/Wallpaper Projects/`
- run `./run.sh` from the project folder
- click the menu bar icon
- choose a wallpaper

Very civilised once assembled.
