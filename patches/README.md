# Active dependency patches

`quickjs-mapped-arguments-gc.patch` backports QuickJS-NG #1401 to the pinned QuickJS
revision `72ba50f63ee31202f8c18b8d07ab1e1c3486ee6f`. Active mapped arguments must not
enter the detached-variable GC list. Preserve this fix until the dependency is deliberately
updated to a revision containing it and the script regression tests pass.

`build-bridge.sh` checks and applies it to a generated source copy in `build/quickjs-source`.
The dependency checkout is never patched. An already-applied fix is accepted; an incompatible
patch fails the build before CMake runs. Legacy renderer changes are archived separately
under `docs/archive` and are not applied by the build.
