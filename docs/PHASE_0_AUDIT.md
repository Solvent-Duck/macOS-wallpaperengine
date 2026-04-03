# Phase 0 Audit

Generated: 2026-04-03
Fork baseline: `linux-wallpaperengine` at `cb0a0f6e1e9a77f93ac702e15a5bd38acf931a88`

## Status

| Task | Expected Output | Observed State | Audit |
| --- | --- | --- | --- |
| 0.1 | `docs/PATCHLOG.md` for all modified submodule files | Missing | Incomplete |
| 0.2 | "New Files (macOS-specific)" section appended to `docs/PATCHLOG.md` | Present as standalone [`docs/PATCHLOG_UNTRACKED.md`](./PATCHLOG_UNTRACKED.md) with 16 entries | Substantively complete, structurally incomplete |
| 0.3 | `docs/SCRIPT_API_INVENTORY.md` | Present and covers the local `~/wallpaper_engine/test_wallpapers/` corpus | Complete |
| 0.4 | Divergence summary at top of `docs/PATCHLOG.md` | Missing because 0.1 was not finished | Incomplete |

## Findings

- The submodule itself is still at the upstream commit recorded in the roadmap, but it has a large local divergence: 39 modified tracked files and 16 untracked macOS-specific files.
- Phase 0 had been started, not finished.
- The strongest existing artifact was the untracked-file inventory. It documented all 16 new files, but it lived in a separate file and therefore did not satisfy the roadmap requirement for a single `docs/PATCHLOG.md`.
- The script API inventory is usable as-is and does identify a real compatibility gap: the local engine implements the value-transformer `update(value)` pattern, while the local test corpus includes at least one wallpaper using the imperative `applyUserProperties` plus `thisObject` pattern.
- No consolidated divergence summary existed, so later phases were still at risk of making extraction decisions without a complete map of fork-local behavior.

## Scope Snapshot

- `linux-wallpaperengine` tracked modifications: 39 files
- `linux-wallpaperengine` untracked files: 16 files
- Dominant divergence area: Metal renderer bring-up and embedding support
- Secondary divergence areas: shader sanitization, light-object parsing, cursor/audio injection, parser/runtime fixes

## Remediation Applied

This audit is paired with a new consolidated [`docs/PATCHLOG.md`](./PATCHLOG.md) that closes the remaining Phase 0 gaps:

- It inventories all 39 modified tracked files.
- It folds in all 16 untracked macOS-specific files.
- It adds category, destination, and risk summaries.
- It calls out the highest-risk divergences explicitly.

## Recommended Next Steps

1. Start Phase 1 with the compatibility harness metadata and fixture catalog, because those are low-risk and immediately useful.
2. Add app automation modes next: screenshot capture, benchmark capture, and non-interactive exit.
3. Run the harness against the existing three local fixtures before touching Phase 2 extraction work.
