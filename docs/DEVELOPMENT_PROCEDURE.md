# Development procedure

Start here for the current local workflow. [Development history](archive/DEVELOPMENT_HISTORY.md)
preserves the previous pass-by-pass instructions, evidence, limitations, and detailed
regression requirements. Consult its relevant feature section before changing behavior.
The app is a native Swift/Metal runtime; upstream code supplies dependency libraries only.

## Setup and build

Use macOS 26+, Swift 6.2+, CMake, Git, rsync and Python 3. Install CMake and ffmpeg
with Homebrew. Initialize the top-level submodule with
`git submodule update --init -- linux-wallpaperengine`, then run:

```sh
./build-bridge.sh
swift build
swift build -c release
```

`./run.sh` performs the incremental dependency and release builds before launching.
The dependency script initializes only the four required nested repositories, builds
from `cmake/dependencies`, and applies the QuickJS fix to `build/quickjs-source`.
Neither normal builds nor patch application should modify the source submodules.
Do not suppress dependency initialization errors or rely on generated libraries in Git.

A selected Xcode installation may require license acceptance. On the current machine,
prior validation used the installed Command Line Tools through a child-process
`DEVELOPER_DIR=/Library/Developer/CommandLineTools` override. Do not change the global
selection automatically. Resolve compilers before CMake, and use a fresh build directory
after a toolchain/configuration change to avoid inherited empty optimization flags.
For this machine, `DEVELOPER_DIR=/Library/Developer/CommandLineTools ./run.sh` selects
that installed toolchain for the build and launch without changing the system setting.

## Fast checks

```sh
python3 scripts/check-repo-hygiene.py
python3 -m unittest discover -s CompatibilitySuite -p 'test_*.py' -v
bash -n build-bridge.sh run.sh
swift test --no-parallel
python3 CompatibilitySuite/run_shader_fixtures.py
python3 CompatibilitySuite/run_script_host_fixtures.py
```

Use focused Swift test filters while developing, then debug and release full suites at
integration checkpoints. Keep native tests serial on this machine to avoid competing
playback probes. After public scene-model or bridge layout changes, clean the Swift build
before rebuilding. Do not compare performance across `swift test -c release` and
`swift build -c release` without accounting for their different testability flags.

Some Command Line Tools installations require explicit Swift Testing paths. The exact
known workaround is retained in the local pass90 evidence; use the selected toolchain's
framework/plugin paths rather than copying another machine's absolute paths. Record any
unavailable tests and the exact commands. Optional media/audio probes remain opt-in.

## Compatibility validation

Portable authored text fixture:

```sh
python3 CompatibilitySuite/run_suite.py \
  --fixtures CompatibilitySuite/text_fixtures.json \
  --binary .build/debug/WallpaperEngine --timeout 60 --frames 60 --benchmark-duration 5
```

Existing sample and workshop catalogs retain their recorded input identities. Override
machine-specific locations explicitly; relative catalog roots resolve beside the catalog,
while relative overrides resolve from the caller's working directory. `~` is expanded.

```sh
python3 CompatibilitySuite/run_suite.py \
  --fixtures CompatibilitySuite/fixtures.json \
  --corpus-root "$HOME/wallpaper_engine/test_wallpapers" \
  --binary .build/debug/WallpaperEngine --timeout 60 --frames 60 --benchmark-duration 5
python3 CompatibilitySuite/run_suite.py \
  --fixtures CompatibilitySuite/local_scene_canaries.json \
  --corpus-root "$HOME/Library/Application Support/Steam/steamapps/workshop/content/431960" \
  --binary .build/debug/WallpaperEngine --timeout 60 --frames 60 --benchmark-duration 5
```

Run samples and representative workshop scenes for shared runtime/build changes; add text,
script, shader, or feature catalogs as appropriate. Preserve declared partial statuses.
A successful capture does not establish interaction, audible output, performance, physical
desktop delivery, or Windows fidelity. Functional playback and conspicuous visible defects
are the acceptance threshold; imperceptible differences alone are not blockers.

Never test workshop IDs `2114290843`, `3340296712`, `3626081043`, or `3626090712`, or the
external `Nsfw - non-testing` directory. Preserve these exclusions during catalog refreshes.
Do not check private workshop assets into this repository.

## Evidence and repository hygiene

`build/`, `.build/`, Python caches, and `CompatibilitySuite/reports/` are generated and
ignored. Keep source, tests, schemas, deterministic authored fixtures, build configuration,
and active patches in Git. Review newly authored files before a commit; the hygiene check
also accepts intent-to-add entries during review, which are not a committed baseline.

Keep JSON/logs, input and source hashes, commands, measurements, and written reviews.
Inspect small temporary image batches promptly, then delete only those newly generated
images after recording findings. Retain bounded images for unresolved defects. Do not
recreate historical screenshot archives, delete original workshop assets, or run artifact
cleanup concurrently with native measurements.

Local cleanup recovery archives live in ignored `.repo-backups/`; see `LATEST` for the
snapshot directory. They are recovery data, not build outputs. Do not include them in
routine cache deletion. Do not reset existing source changes to make status look clean.

## Feature-specific regression requirements

The [development history](archive/DEVELOPMENT_HISTORY.md) retains exact filters and original
probes for video, script threading/snapshots, audio, cursor delivery, properties, text,
effect/material bindings, display-link scheduling, and particles. Preserve those checks
when changing their behavior. Current architectural references are indexed in [docs](README.md).
