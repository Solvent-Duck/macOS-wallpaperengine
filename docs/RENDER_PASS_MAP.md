# Render Pass Map

Phase 5 introduces the first owned renderer path in Swift. This document maps the current native path to the upstream scene renderer and records the deliberate scope boundary for this phase.

## Upstream To Native Mapping

| Upstream responsibility | Current upstream location | Native Phase 5 owner | Notes |
| --- | --- | --- | --- |
| Scene frame entry | `WallpaperApplication::render()` -> `RenderContext::render()` | `SceneRenderer` + `NativeSceneRenderer.renderNextFrame` | App integration remains in `SceneRenderer`; native render entry is feature-flagged. |
| Per-frame scene state | `WallpaperApplication::update()` | `SceneRuntime.step(deltaTime:)` | Added in Phase 4 and consumed directly by the renderer in Phase 5. |
| Render-item ordering | `CScene::renderFrame()` object traversal | `PassGraph.build(packet:)` | Current ordering is flat packet order plus material pass order. |
| Material pass execution | `Objects/*` + `Effects/CPass.cpp` | `MaterialBinder` + `ImageRenderer` | Native path currently binds image materials and executes their shader passes directly. |
| Shader preprocessing/compilation | `ShaderUnit` + fork patches | `NativeSceneCompatibility.ShaderPipeline` | Owned since Phase 3. |
| Texture resolution | asset locators + material/runtime helpers | `SceneTextureResolver` | Resolves wallpaper-local and shared asset textures for material bindings. |
| Quad/image geometry | `CImage` | `ImageRenderer` | Native Phase 5 currently supports flat image-layer geometry only. |
| Lighting uniforms | light state in scene renderer | `LightingPass` + opportunistic uniform binding in `MaterialBinder` | Only placeholder ambient/light array defaults for now. |
| Post-processing graph | FBO/effect pass management | `PostProcessPass` | Stubbed in Phase 5; no owned RTT/effect graph yet. |
| Particle rendering | `CParticle`, particle material/runtime code | `ParticleRenderer` | Stubbed in Phase 5; particle scenes remain on the bridge path. |
| Final presentation to screen | Metal bridge texture blit | `SceneMetalView` | Shared presentation path now supports either bridge output or native output texture. |

## Current Native Render Scope

The Phase 5 native path is intentionally narrow:

- Supported:
  - scene wallpapers whose nodes are image layers
  - image materials with shader passes compiled through the owned shader pipeline
  - property overrides and audio summaries flowing into `SceneRuntime`
  - offscreen snapshot rendering through `SceneNativeSnapshotTool`
  - app-side presentation through `SceneRenderer` when `WE_USE_NATIVE_SCENE_RENDERER=1`
- Not yet supported:
  - particle nodes
  - image effect chains / RTT graphs
  - animation-layer-heavy scenes
  - mesh/model geometry (`.mdl`, `.obj`)
  - owned lighting/post-processing parity beyond placeholder uniforms

Unsupported scenes continue to use the existing bridge renderer. This is deliberate: Phase 5 is a controlled mixed-mode step, not a full renderer cutover.

## Feature Flag

The app integration is currently gated behind:

```bash
WE_USE_NATIVE_SCENE_RENDERER=1 ./.build/debug/WallpaperEngine <wallpaper> --screenshot /tmp/out.png --frames 60
```

Selection behavior:

- if the flag is unset, `SceneRenderer` always uses the bridge path
- if the flag is set and the scene passes `NativeSceneRenderer.support(scene:)`, `SceneRenderer` uses the native path
- if native initialization fails or the scene is outside the supported subset, `SceneRenderer` logs the reason and falls back to the bridge path

## Acceptance Boundary For Phase 5

Phase 5 is considered complete when:

- `NativeSceneRenderer` builds as its own package target
- the app can present a native-rendered frame through the existing `SceneRenderer` entrypoint
- the integration is feature-flagged and safe to fall back
- the native path can render at least one real scene wallpaper end to end without a black frame

That boundary has been met for the `deep_space` sample scene. Broader feature coverage remains later-phase work.
