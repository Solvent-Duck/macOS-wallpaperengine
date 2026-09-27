# Phase 7 Status

Phase 7 replaces the previous “unsupported text object” path with:

- native text object parsing in the upstream bridge export
- structured `TextDescriptor` decoding in `NativeSceneCore`
- runtime-owned text frame packets in `NativeSceneRuntime`
- Core Text / Core Graphics text rasterization in `NativeSceneRenderer`

## What Is Verified

- Deterministic native text rendering on the repo-local fixture catalog in `CompatibilitySuite/text_fixtures.json`
- Native scene decoding for real scripted text wallpaper `2232968607`
- Native-requested real text canaries now render visible text for:
  - `2232968607`
  - `3098403977`
- Real text-bearing workshop scenes still pass on the native canary lane in `CompatibilitySuite/text_scene_canaries.json`

## Current Boundary

Complex real workshop text scenes still expose broader native image/material parity gaps that are not text-parser failures:

- `2232968607` and `3098403977` now show native text content, but the rest of the frame is still dominated by the current native image/material subset rather than bridge parity.
- `3368256253` remains a partial-parity native canary because particle support is still outside the native text slice.

This means Phase 7 is complete for the text subsystem itself, but it does not imply full native parity for every real text-heavy wallpaper yet. The remaining divergence belongs to the existing native image/material coverage boundary from Phase 5.
