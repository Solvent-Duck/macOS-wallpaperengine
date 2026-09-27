# Repository cleanup — 2026-09-26

## Changes

- Removed 760 generated `build/` files from Git's index while retaining local products.
  Added Python cache and local recovery-directory exclusions.
- Moved the active dependency CMake project into `cmake/dependencies`. Build only the ten
  library targets consumed by the Swift package. Repeated builds check inputs and outputs
  without recompiling unchanged libraries.
- Apply the active QuickJS fix in a generated source copy. Dependency initialization and
  patch failures now stop the build, and missing libraries are checked on every launch.
- Replaced the local-only engine checkpoint with its upstream parent. The four active
  dependency revisions are unchanged. The former engine edits are recoverable from
  [the cumulative legacy patch](archive/README.md); active submodule checkouts are clean.
- Added `--corpus-root`, catalog-relative roots, and home expansion to the harness. The
  authored text fixture catalog now travels with the repository. Existing external corpus
  identities remain recorded and can be overridden without rewriting historical catalogs.
- Added portable inventory/unit/shell checks in `.github/workflows/repository-checks.yml`.
  Native GPU CI is still future work; this pass ran native validation locally.
- Replaced the lengthy development entry point with current instructions and a documentation
  index. Prior development and CI documents are preserved byte-for-byte under `docs/archive`.

## Preservation and Git state

Before editing, saved `.repo-backups/20260926-220605/checkout.tar.gz`, separate Git patches,
and `source-sha256.json`. The archive includes Git metadata, the original index, authored
files, initialized dependencies and tracked build products. It omits generated Swift products,
report evidence, Python caches and local Claude settings/worktrees, which remain in place.
The local backup is ignored and must not be treated as disposable build output.

All pre-existing files under `Sources/` and `Tests/` match their pre-cleanup hashes.
No application feature or Swift test implementation changed. The accumulated implementation
was not independently reviewed for correctness during this repository cleanup.

The initial cleanup left the implementation uncommitted for review. The user subsequently
authorized checkpointing it for the Windows handoff. The commit groups are the native-runtime
baseline with its tests, required dependency/build changes and generated-file removals;
harness/CI improvements; and documentation. The native source and its build changes belong
together, so the checkpoint does not rely on an intermediate mixture of old and new bridges.
Rebuilding no longer adds generated-file churn or dirties nested dependencies.

## Validation

The isolated build used `/private/tmp/mac-wallpaper-cleanup-20260926`, with current authored
source and clean Git exports of upstream dependency revisions. No existing `build/` or
`.build/` products were copied. This verifies an uncached build of the working source; it is
not a claim that the old committed HEAD reproduces the current application.

Passed:

- 15 Python unit tests: compiler discovery, initialization failures, patch isolation and
  repeatability, fixture roots, harness behavior, diagnostics and repository inventory.
- Fresh dependency compilation; incremental dependency build with zero compile/link steps.
- Debug and release Swift suites: 543 enabled tests in 91 suites per configuration. Six
  existing optional installed-media/audio probes were skipped by their normal opt-in gates.
- Production `swift build -c release`, separate from the testable release configuration.
- Three shader fixtures and three script-host fixtures.
- 24 capture canaries: 21 pass and three declared partial, with no unexpected failures.
  Samples: 2 pass / 1 partial; portable text: 1 pass; workshop: 18 pass / 2 partial.
  Partial IDs are `neon_sunset` (3D models), `3573378561` (shortcut icons), and
  `3613126158` (shortcut icons/system textures). All 24 captures showed nonblank scene
  composition at contact-sheet scale. Their hashes and written review remain; only this
  run's images were removed after review. This is not a before/after fidelity, desktop
  interaction, audible-output or performance comparison.
- Recreated a deliberately missing QuickJS library in the isolated build. The final
  repeated local build compiled/linked nothing and left the complete Git status unchanged.
- Shell syntax, Git inventory, and whitespace checks on files changed by this pass.
  The full accumulated diff still has pre-existing Markdown hard-break whitespace in
  `docs/RUNTIME_UPDATE_FLOW.md`; this historical content was left intact.

Swift checks used child-process `DEVELOPER_DIR=/Library/Developer/CommandLineTools` and the
existing Swift Testing framework/plugin flags below. The first sandboxed test attempt could
not write the compiler cache; rerunning with cache/native access passed. No global toolchain
selection or Xcode license setting was changed.

```sh
python3 -m unittest discover -s CompatibilitySuite -p 'test_*.py' -v
python3 scripts/check-repo-hygiene.py
bash -n build-bridge.sh run.sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools ./build-bridge.sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools swift test --no-parallel --disable-xctest \
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
# Repeat the same test invocation with: -c release
DEVELOPER_DIR=/Library/Developer/CommandLineTools swift build -c release
python3 CompatibilitySuite/run_shader_fixtures.py
python3 CompatibilitySuite/run_script_host_fixtures.py
```

Compact logs, exact canary commands, source/binary hashes and results are retained locally
in ignored `CompatibilitySuite/reports/repo-cleanup-20260926/`. No historical evidence was
removed. CI configuration was checked locally but has not been dispatched to GitHub.
