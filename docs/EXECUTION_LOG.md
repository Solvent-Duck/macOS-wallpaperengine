# Execution Log

## 2026-04-03

### Phase 0 Audit Closure

Changes:
- Audited the current state of Phase 0 deliverables against [`docs/IMPLEMENTATION_TASKS.md`](./IMPLEMENTATION_TASKS.md).
- Added [`docs/PHASE_0_AUDIT.md`](./PHASE_0_AUDIT.md) to record what had already been done and what was missing.
- Added [`docs/PATCHLOG.md`](./PATCHLOG.md) as the consolidated divergence inventory required by the roadmap.

Functionality and impact:
- Later phases now have a single source of truth for fork-local behavior.
- The audit confirms that the submodule divergence is still concentrated in embedding, Metal rendering, shader compatibility, and parser/runtime fixes.
- The remaining plan can now proceed with explicit knowledge of what must be preserved versus extracted or deleted.

### Phase 1 Harness Foundation

Changes:
- Added `CompatibilitySuite/schema/fixture.schema.json` to define the machine-readable fixture catalog format.
- Added `CompatibilitySuite/generate_fixtures.py` to scan the local wallpaper corpus and derive fixture metadata automatically.
- Generated `CompatibilitySuite/fixtures.json` from the current local corpus.
- Added [`docs/CI_PLAN.md`](./CI_PLAN.md) to lock the promotion path and enforcement strategy before renderer automation work starts.

Functionality and impact:
- Fixture metadata can now be regenerated from the wallpaper corpus instead of being curated by hand.
- The current local corpus snapshot contains three scene fixtures: `deep_space`, `neon_sunset`, and `shimmering_particles`.
- Automated classification already highlights the main compatibility risk in the corpus: `shimmering_particles` depends on `applyUserProperties` and `thisObject`, which the current script runtime does not expose.
- The harness has an agreed CI shape before screenshot and benchmark features are added to the app.

### Phase 1 App Automation

Changes:
- Added non-interactive launch parsing for `--screenshot`, `--benchmark`, `--frames`, and `--benchmark-duration`.
- Added an automation controller so the app can execute capture tasks sequentially and then exit cleanly.
- Added PNG capture from the scene renderer's Metal output texture.
- Added benchmark JSON export from the in-process performance monitor.

Functionality and impact:
- `WallpaperEngine <wallpaper> --screenshot <file>` now writes a PNG and exits.
- `WallpaperEngine <wallpaper> --benchmark <file>` now writes JSON containing `cpu_avg_ms`, `cpu_p95_ms`, `fps_avg`, `memory_peak_mb`, and `sample_count`.
- Verified locally with `deep_space`: the automation flow produced a valid `1920x1080` PNG and benchmark JSON in `/tmp/`.

### Phase 1 Suite Runner

Changes:
- Added `CompatibilitySuite/run_suite.py` to launch the app per fixture, capture stdout and stderr, and write per-fixture plus summary JSON reports.
- Added `CompatibilitySuite/schema/run-report.schema.json` for the report format.
- Extended screenshot capture to emit a PNG sidecar JSON with black-frame classification metadata.

Functionality and impact:
- The harness now measures `launch_ok`, `render_ok`, `black_frame`, `duration_ms`, and benchmark output per fixture.
- Full local corpus run completed with the current three fixtures.
- Initial baseline:
  - `neon_sunset`: `pass`
  - `deep_space`: `fail` (`black_frame: true`)
  - `shimmering_particles`: `fail` (`black_frame: true`)
- This gives Phase 2+ work a concrete regression target instead of anecdotal testing.

### Phase 1 Black-Frame Investigation

Changes:
- Fixed Apple scene clearing so Metal-backed framebuffers are explicitly cleared before scene draws.
- Added Apple-side fallback decoding for non-power-of-two compressed textures by loading sibling image assets into padded Metal textures when direct TEXB upload is invalid on Metal.
- Corrected the Metal clip-space transform for `g_ModelViewProjectionMatrix` so OpenGL-authored scene geometry is not clipped away on Apple.
- Implemented Metal particle rendering for custom indexed geometry instead of short-circuiting the Apple path.
- Replaced sparse black-frame sampling with a full-buffer scan in screenshot analysis so particle-heavy scenes are classified from the actual captured pixels.

Functionality and impact:
- `deep_space` now renders visible output instead of a fully black capture; focused verification reported `black_frame: false` with `black_pixels: 0`.
- `shimmering_particles` now renders visible particle output on Metal; focused verification reported `black_frame: false` after the renderer fix and screenshot-classifier correction.
- Full suite verification now passes for the current local corpus:
  - `deep_space`: `pass`
  - `neon_sunset`: `pass`
  - `shimmering_particles`: `pass`
- Verified report: `CompatibilitySuite/reports/run_2026-04-03T14-20-33Z.json`
- Residual note: particle scheme colors still need follow-up validation because the current Metal path is rendering with neutralized color inputs for this fixture, but this no longer blocks extraction readiness for the black-frame gate.
