# Legacy engine recovery

The native Swift app no longer compiles the former upstream C++/Objective-C++ renderer.
The active dependency CMake project is now owned by this repository in `cmake/dependencies`.
The top-level engine submodule uses upstream commit
`cb0a0f6e1e9a77f93ac702e15a5bd38acf931a88`, available on `origin/main`, rather than the
local-only checkpoint `50cb1153a20209d00f319beaf7a87f6b87636449`.
The four active nested dependency revisions are unchanged.

`legacy-engine-macos.patch` preserves the cumulative engine changes from that upstream
base through the local checkpoint and the working tree at cleanup time. It includes the
legacy bridge configuration and renderer/parser changes. It excludes the nested QuickJS
fix, which remains active in `patches/quickjs-mapped-arguments-gc.patch`.

For investigation, use a separate checkout of the upstream base, then apply this patch
there with `git apply /absolute/path/to/legacy-engine-macos.patch`. Do not apply it to the
active dependency checkout as part of normal builds. Patch applicability was checked
against an export of the upstream base before the old checkout was restored.

An ignored local `.repo-backups/` snapshot additionally preserves the original `.git`
metadata, index, tracked build products, working source and initialized dependencies,
along with separate root/engine/QuickJS patches and a source hash inventory. Read `LATEST`
for its location. The archive omits `.build`, report evidence, Python caches and `.claude`;
those originals remain in place. Restore the archive into a separate directory first;
never unpack it over ongoing development. Review stored `.git` worktree paths before use.

`DEVELOPMENT_HISTORY.md` and `CI_PLAN_2026-04.md` retain the prior documents. Historical
bridge lanes and screenshot retention proposals are superseded by the current workflow.
