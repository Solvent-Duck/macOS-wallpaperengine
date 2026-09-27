# Windows reference-capture handoff

The user confirmed a Windows device is available on 2026-09-26. Repository checkpointing
prepares the source handoff; access to that device and the capture workflow are not yet
configured. The current Swift application still targets macOS and uses AppKit and Metal.
This checkpoint does not add a Windows application build or a Windows capture runner.
The validated native source/build checkpoint is `f3f5d58`; the compatibility harness and
repository checks are in `2aba536`. Use the current `main` revision for the complete handoff.

## Repository transfer

On the Windows device, clone the existing repository, or update an existing clean checkout:

```powershell
git clone https://github.com/Solvent-Duck/macOS-wallpaperengine.git
cd macOS-wallpaperengine
git status
```

For an existing checkout on `main`, use `git pull --ff-only` after preserving any local work.
The capture setup can inspect catalogs and documentation without building the macOS app.
The dependency submodules are needed for native builds on the Mac, not for reading the
reference-capture inputs on Windows.

Git carries the implementation, tests, authored fixtures, schemas, catalog identities,
active dependency patch, documentation and legacy source archive. It intentionally omits
private installed wallpaper assets, generated builds, `.repo-backups/` and local
`CompatibilitySuite/reports/` evidence. Those are not transferred by a clone.
Repository attributes keep text checkouts in LF format across hosts and preserve patch
files byte-for-byte, so Windows line-ending settings do not alter those capture inputs.

## Capture setup still needed

- Establish an authorized connection to the Windows device and locate its Wallpaper Engine
  installation and matching wallpaper corpus.
- Start with a small representative catalog. Preserve workshop IDs, project/package hashes,
  authored property values, viewport size, elapsed capture time, camera and input state.
  Live clocks, media, random effects and authored intros need explicit comparison conditions.
- Save Windows reference images with a manifest identifying the repository revision,
  Wallpaper Engine version, input hashes, settings and capture conditions. Compare them to
  the corresponding Mac outputs; a successful render alone does not establish parity.
- Copy only the relevant compact Mac evidence and bounded reference images when needed.
  The cleanup's counts and limitations are recorded in [REPO_CLEANUP.md](REPO_CLEANUP.md);
  exact commands and source/binary/input hashes remain in the Mac's ignored
  `CompatibilitySuite/reports/repo-cleanup-20260926/` directory.

Existing catalog absolute paths describe the Mac corpus. Supply host-specific paths when
configuring the Windows capture workflow; the Mac harness supports `--corpus-root` but
invokes the native Mac app and is not itself a Windows reference-capture implementation.

Keep the four wallpaper exclusions in [Development procedure](DEVELOPMENT_PROCEDURE.md).
Do not add private wallpaper packages, generated caches or bulk captures to Git. Keep
reference images only as a bounded comparison set, with their provenance and review notes.
