# Runtime Bridge Benchmark

Phase 4.7 benchmark results for the new `NativeSceneRuntime` frame packet.

## Method

Current-engine baseline:

- used the existing scene benchmark JSON already captured by the app automation flow
- source report set:
  - `CompatibilitySuite/reports/run_2026-04-03T15-08-03Z`

Native-runtime benchmark:

- built `SceneRuntimeBenchmarkTool`
- loaded each sample scene through `NativeSceneBridge`
- stepped `SceneRuntime` for 300 frames at `1/60s`
- measured:
  - frame packet production time
  - JSON encoding time as a pessimistic bridge-copy proxy
  - average and peak packet size

Commands used:

```bash
./.build/debug/SceneRuntimeBenchmarkTool /Users/isaiahbergstrom/wallpaper_engine/test_wallpapers/deep_space /Users/isaiahbergstrom/wallpaper_engine/assets --frames 300
./.build/debug/SceneRuntimeBenchmarkTool /Users/isaiahbergstrom/wallpaper_engine/test_wallpapers/neon_sunset /Users/isaiahbergstrom/wallpaper_engine/assets --frames 300
./.build/debug/SceneRuntimeBenchmarkTool /Users/isaiahbergstrom/wallpaper_engine/test_wallpapers/shimmering_particles /Users/isaiahbergstrom/wallpaper_engine/assets --frames 300
```

## Results

| Fixture | Current engine cpu_avg_ms | Packet avg ms | Encode avg ms | Packet+encode avg ms | Avg bytes |
| --- | ---: | ---: | ---: | ---: | ---: |
| `deep_space` | 0.314 | 0.039 | 0.074 | 0.113 | 2,726 |
| `neon_sunset` | 0.781 | 0.081 | 0.126 | 0.207 | 5,270 |
| `shimmering_particles` | 0.588 | 0.096 | 0.137 | 0.233 | 6,753 |

Detailed native-runtime measurements:

- `deep_space`
  - packet p95: `0.047 ms`
  - encode p95: `0.088 ms`
  - peak packet size: `2,727 bytes`
- `neon_sunset`
  - packet p95: `0.107 ms`
  - encode p95: `0.155 ms`
  - peak packet size: `5,272 bytes`
- `shimmering_particles`
  - packet p95: `0.123 ms`
  - encode p95: `0.170 ms`
  - peak packet size: `6,754 bytes`

## Interpretation

For the current three-fixture sample corpus:

- packet production alone is small
- even JSON encoding, which is more expensive than a binary packet copy, stays below `0.25 ms` average on all three scenes
- packet+encode cost is between roughly `26%` and `40%` of the current full-engine CPU frame time on these fixtures

That does not prove the mixed-mode cost is cheap on the 20-scene real canary corpus, especially for:

- transform-heavy scenes
- scenes with many lights
- scenes with large particle counts
- script-heavy scenes once Phase 6 replaces the host

But it is enough to answer the Phase 4 decision gate for the current sample benchmark set.

## Decision

Do **not** merge Phases 4 and 5 yet.

Reason:

- the current frame packet is small
- packet production is cheap
- even the pessimistic JSON-copy proxy does not consume the entire CPU budget on the sample scenes

Follow-up rule before Phase 5 is considered stable:

- rerun the same benchmark method on a representative subset of the 20-scene local canary corpus
- if packet production plus bridge copy starts approaching the existing renderer CPU time on those scenes, collapse the runtime/renderer boundary before broadening mixed-mode usage

## Notes

- `shimmering_particles` emitted upstream script-evaluation noise during scene extraction, but the runtime benchmark still completed because `NativeSceneRuntime` itself does not execute the upstream JS host.
- These numbers are for packet construction and serialization only. They do not include renderer consumption cost, which belongs to Phase 5.
