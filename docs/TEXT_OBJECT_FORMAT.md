# Text Object Format

Phase 7 text support was derived from real workshop scenes, primarily:

- `2232968607` (`天空之镜 4K`) for simple scripted clock/date/week text
- `3098403977` (`HUD 02 | cursor tracker + world clock [4K]`) for text-heavy HUD layout

## Object Shape

Text objects do not carry an explicit `"type": "text"` tag in the raw scene JSON. They are identified by the presence of text-specific keys such as `"text"`, `"font"`, `"pointsize"`, `"horizontalalign"`, and `"verticalalign"`.

Observed object-level fields:

- `id`
- `name`
- `origin`
- `scale`
- `angles`
- `visible`
- `alpha`
- `color`
- `backgroundcolor`
- `backgroundbrightness`
- `castshadow`
- `depthtest`
- `font`
- `size`
- `pointsize`
- `padding`
- `anchor`
- `horizontalalign`
- `verticalalign`
- `limitrows`
- `limitwidth`
- `limituseellipsis`
- `maxrows`
- `maxwidth`
- `blockalign`
- `locktransforms`
- `opaquebackground`
- `parallaxDepth`
- `effects`
- `text`

## Font References

Observed font references are relative asset paths such as:

- `fonts/NotoSans-Regular.ttf`

The native renderer resolves fonts first relative to the wallpaper root, then relative to the shared Wallpaper Engine assets path.

## Styling Semantics

Observed styling/value formats:

- `origin`, `scale`, `angles`, `size`, `parallaxDepth`: whitespace-separated numeric vectors
- `pointsize`, `padding`, `maxrows`, `maxwidth`: numeric scalars
- `horizontalalign`: `left`, `center`, `right`
- `verticalalign`: `top`, `center`, `bottom`
- `color`: literal RGB vector or a property-bound object
- `backgroundcolor`: authored as RGB; native normalization should treat the implicit alpha as `0` unless `opaquebackground` is enabled
- `castshadow`: boolean shadow toggle
- `limitwidth` + `limituseellipsis`: width-constrained truncation behavior

## Dynamic Text Updates

The `text` field is a standard `UserSetting` payload. Observed forms:

Static literal:

```json
{
  "value": "Phase 7 Native Text"
}
```

Property-bound literal:

```json
{
  "user": "subtitle",
  "value": "Derived from real Wallpaper Engine text objects"
}
```

Scripted dynamic value:

```json
{
  "value": "02:36",
  "script": "export function update(value) { ... return value; }",
  "scriptproperties": {
    "delimiter": ":"
  }
}
```

Observed script behavior:

- the runtime calls `update(value)` with the current/base text value
- `scriptproperties` supply plain literals or property-backed values
- wallpapers frequently use `Date()` inside `update(value)` for clocks/calendars
- the hide convention is to return `"\0"`, which should be normalized to an empty rendered string

## Native Mapping

Phase 7 normalizes these objects into `TextDescriptor` in `NativeSceneCore`, preserving:

- transform inputs
- color/background settings
- layout and truncation controls
- font path
- effects metadata
- scripted or property-bound text content via `UserSettingDescriptor`

The native renderer then rasterizes the evaluated `FrameText` into Metal textures using Core Text / Core Graphics.
