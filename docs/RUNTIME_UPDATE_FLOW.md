# Runtime Update Flow

Phase 4.1 deliverable for the upstream runtime path that currently drives scene playback.

## Summary

The upstream per-frame path is split across two layers:

1. `WallpaperApplication::render()`
   owns global time/input/audio/pause/screenshot/playlist work
2. `WallpaperApplication::update(viewport)`
   delegates the actual viewport draw to `RenderContext::render(viewport)`

For scene wallpapers, the final hot path is:

`WallpaperApplication::render()`  
-> video driver frame callback  
-> `WallpaperApplication::update(viewport)`  
-> `RenderContext::render(viewport)`  
-> `CWallpaper::render(viewport, vflip)`  
-> `CScene::renderFrame(viewport)`  
-> render each object in `m_objectsByRenderOrder`

## Application-Level Frame Work

`WallpaperApplication::render()` is where the global runtime state is advanced before any viewport draw happens.

If the app was paused because a fullscreen app was detected:

- sleep briefly
- wait until fullscreen clears
- call `RenderContext::setPause(false)`
- shift playlist timers by the paused duration
- clear the paused flag

If the app is not paused:

- update `g_Daytime` from wall clock time
- move `g_Time` into `g_TimeLast`
- fetch the new render time from `VideoDriver::getRenderTime()`
- update the audio driver/recorder
- update input state
- dispatch queued driver events
- stop if the driver requested close
- detect fullscreen and, if needed:
  - mark paused
  - record pause start time
  - call `RenderContext::setPause(true)`
  - skip the rest of the frame

After the global frame state is updated:

- update playlists
- check delayed screenshot capture
- take the screenshot once the requested frame counter is reached

Important detail:

- `WallpaperApplication::render()` does not directly draw the wallpaper
- the actual draw happens later when the video driver asks the application to update a viewport

## Viewport Draw Delegation

`WallpaperApplication::update(viewport)` is intentionally thin:

- it calls `m_renderContext->render(viewport)`

`RenderContext::render(viewport)` then:

- makes the viewport current
- finds the wallpaper assigned to that viewport name
- calls `wallpaper->render(viewportRect, renderVFlip)`
- swaps the output

This means the application-level frame step and the per-viewport draw are already separate concerns in the upstream design.

## Scene Wallpaper Render Path

For scene wallpapers, `CWallpaper::render()`:

- calls `renderFrame(viewport)` on the concrete wallpaper
- on non-Apple paths, also blits the scene FBO to the destination framebuffer
- on Apple, returns after `renderFrame()` because Swift/Metal does the final blit

For `CScene::renderFrame(viewport)`, the per-frame order is:

1. `updateMouse(viewport)`
   - read current mouse position
   - convert it into normalized viewport space
   - remap it through the current wallpaper UV crop
2. `updateLightState()`
   - rebuild the flat point/spot/tube/directional light arrays
3. update camera parallax displacement
   - uses `g_Time - g_TimeLast`
   - uses scene parallax settings and current mouse position
4. update main textures for image objects
   - iterate `m_objectsByRenderOrder`
   - for each `CImage`, call `image->getTexture()->update()`
5. clear the scene render target
   - GL clear on non-Apple
   - Metal texture clear on Apple
6. render each object in render order
   - `cur->render()`

There is no separate explicit “scene runtime step” object here. Evaluation and rendering are still tightly interleaved.

## Transform Hierarchy Evaluation

The upstream transform story is partially centralized and partially object-local.

Observed global pieces:

- parent relationships are created before child objects
- `CScene::resolveObjectOrigin()` walks parent links and sums origins
- `updateLightState()` uses that resolved origin for light placement

Observed object-local pieces:

- renderable objects keep their own transform/material state
- visibility, scale, angle, and shader constant consumption happen inside the object render paths rather than in one flat scene-wide transform pass

Implication for the native runtime:

- the immutable scene model already exposes the data needed for a flat parent-first transform pass
- Phase 4 can replace this with one explicit world-transform array instead of per-object traversal

## Visibility Determination

Visibility is not owned by one top-level function upstream.

Current visibility gates are spread across:

- light filtering in `CScene::updateLightState()`
- object-specific render paths that check `visible` dynamic values
- particle enable/disable logic inside particle render/update code

Implication:

- Phase 4 should make visibility an explicit frame-packet field, not an emergent side effect of object render code

## Property, Script, and Animation Evaluation

The upstream runtime does not perform a single centralized “evaluate every property now” pass.

Instead:

- property overrides are applied at load/setup time in `WallpaperApplication::setupPropertiesForProject()`
- `DynamicValue` stores all scalar/vector/string views at once and propagates changes to listeners
- `ScriptedDynamicValue` reevaluates by calling the script engine whenever its input properties change
- object render code and shader pass binding code read those live dynamic values when needed

What this means operationally:

- user property overrides are long-lived runtime state
- script-driven values are incremental and listener-driven
- render-time code sees already-resolved values through `DynamicValue`

This is the main behavior gap between the upstream runtime and the new Phase 4 Swift runtime:

- the native runtime now owns explicit per-frame property resolution and packetization
- full script-host parity is still deferred to Phase 6

## Audio-Reactive Timing

Audio updates happen before viewport rendering:

- `m_audioDriver->update()` runs in `WallpaperApplication::render()`

The results are then consumed later by runtime objects and shader constant binding code. The application loop itself does not directly map audio into object state; it just advances the source data before the frame draw.

## Pause Behavior

Pause is coordinated at the application level:

- fullscreen detection triggers pause
- `RenderContext::setPause(true/false)` forwards pause state to wallpapers
- `CWallpaper::setPause()` is a no-op for scene wallpapers today
- video wallpapers override pause directly

For scenes, the effective pause behavior today comes mostly from:

- `WallpaperApplication::render()` stopping time/input/audio advancement while paused
- playlist timers being shifted after unpause

## Dataflow Notes For Native Runtime Design

The key extraction points for Phase 4 are:

- move time, visibility, transforms, and property snapshots into a flat Swift-owned runtime step
- keep renderer-facing output as a plain data packet
- avoid rebuilding the upstream “object graph with lazy reads” model in Swift

That directly leads to the Phase 4 implementation split:

- `NativeSceneRuntime`
  owns mutable frame state
- `FramePacket`
  is the renderer-facing boundary
- later renderer work should consume packets, not walk scene objects
