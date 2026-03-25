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
- A Mac running **macOS 13 or newer**
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

### Step 3: Install the libraries this app needs

Paste this into Terminal:

```bash
brew install cmake glew glfw sdl2 lz4 ffmpeg freeglut glm
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

## Part 4 — Build the app

This is the part that looks scary but is mostly just waiting.

### Step 1: Build the wallpaper engine bridge

Paste:

```bash
./build-bridge.sh
```

What this does:
- Downloads required sub-parts
- Compiles the rendering engine
- Prepares the C++ side of the app

Expected time:
- Usually **2–5 minutes**, sometimes longer the first time

When it finishes successfully, you should see something like:

```text
=== Build complete ===
Static library: build/lib/libwallpaperengine.a
Bridge header:  build/include/WEBridge.h
```

---

### Step 2: Build the Mac app itself

Paste:

```bash
swift build
```

When it finishes, the app binary will exist here:

```text
.build/debug/WallpaperEngine
```

If you want the optimized version later, use:

```bash
swift build -c release
```

That version ends up here:

```text
.build/release/WallpaperEngine
```

For most people, the normal debug build is fine to start with.

---

## Part 5 — Start the app

To launch it, paste:

```bash
.build/debug/WallpaperEngine
```

If you built the release version instead, paste:

```bash
.build/release/WallpaperEngine
```

When it opens:
- You may **not** see a normal app window
- You may **not** see a Dock icon
- This is expected
- Look in the **menu bar** at the top of the screen for a **photo-style icon**

That icon is the app.

---

## Part 6 — Get your wallpapers ready

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

## Part 7 — Move Steam Workshop wallpapers into the right folder

If you already download wallpapers through Steam, the important thing to understand is this:

Steam stores Workshop files in hidden folders.
This app works best when each wallpaper is copied into your **Wallpaper Projects** folder.

### The usual Steam Workshop wallpaper location

Wallpaper Engine workshop items are typically inside:

```text
~/Library/Application Support/Steam/steamapps/workshop/content/431960/
```

- `431960` is Wallpaper Engine’s Steam app ID
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

## Part 8 — Pick a wallpaper inside the app

Once the app is running:

1. Click the **menu bar icon**
2. Click **Browse Wallpapers…**
3. The gallery should open
4. Click any wallpaper to apply it

The gallery scans your `~/Wallpaper Projects/` folder automatically.

You can also:
- Search by wallpaper name
- Filter by tags
- Click a wallpaper card to set it

---

## Part 9 — Other ways to load a wallpaper

You are not limited to the gallery.

From the menu bar icon, you can choose:

### **Select Wallpaper…**
Use this if you want to open:
- A wallpaper folder
- A `project.json` file
- A supported video file
- A `.pkg` wallpaper package

The app can also load a wallpaper directly from Terminal when launching.

Example:

```bash
.build/debug/WallpaperEngine "$HOME/Wallpaper Projects/1234567890"
```

That starts the app and immediately loads that wallpaper.

---

## Part 10 — Everyday controls

From the menu bar icon, you can use:

- **Browse Wallpapers…** — open the wallpaper gallery
- **Select Wallpaper…** — manually choose a wallpaper file or folder
- **Pause / Resume** — stop or continue playback
- **Mute / Unmute Audio** — turn wallpaper sound off or on
- **Clear Wallpaper** — remove the current animated wallpaper
- **Copy Diagnostics** — copy technical info for troubleshooting
- **Quit WallpaperEngine** — close the app

---

## Supported wallpaper types

### Works
- **Video wallpapers** (`.mp4`, `.mov`, `.m4v`, and some other video files)
- **Web wallpapers** (`.html`, JS, CSS bundles)
- **Scene wallpapers** (the app includes bridge support for these)

### Does not work
- **Application wallpapers**
  - These are basically Windows programs
  - macOS cannot sensibly run them as wallpapers here

---

## Special note about WebM videos

If a wallpaper uses **WebM** video, the app may convert it to **MP4** the first time it loads.

That is why `ffmpeg` was installed earlier.

So if first load is a bit slower once, that is not automatically a bug.

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

### Problem: build says `library not found for -lwallpaperengine`
You probably skipped the bridge build.

Run:

```bash
./build-bridge.sh
swift build
```

---

### Problem: build says `library not found for -lglfw`
Install missing dependencies again:

```bash
brew install glfw glew sdl2 freeglut glm cmake lz4 ffmpeg
```

Then rebuild.

---

### Problem: the app launches but you cannot find it
That is because it is a **menu bar app**.

Look at the top-right or top area of the screen for the icon.
There is no normal app window at startup.

---

### Problem: the gallery is empty
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
   brew install cmake glew glfw sdl2 lz4 ffmpeg freeglut glm
   ```
5. Run:
   ```bash
   cd /Users/isaiahbergstrom/Projects/macOS-wallpaperengine
   ./build-bridge.sh
   swift build
   ```
6. Launch:
   ```bash
   .build/debug/WallpaperEngine
   ```
7. Create wallpaper folder if needed:
   ```bash
   mkdir -p "$HOME/Wallpaper Projects"
   ```
8. Open Steam’s workshop storage folder:
   ```bash
   open "$HOME/Library/Application Support/Steam/steamapps/workshop/content/431960"
   ```
9. Copy wallpaper folders into:
   ```text
   ~/Wallpaper Projects/
   ```
10. In the app’s menu bar icon, click **Browse Wallpapers…**

---

## Final plain-English summary

The first setup is the annoying part.
After that, normal use is simple:

- put wallpapers into `~/Wallpaper Projects/`
- launch the app
- click the menu bar icon
- choose a wallpaper

Very civilised once assembled.
