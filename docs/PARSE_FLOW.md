# Parse Flow

Phase 2.2 deliverable for `linux-wallpaperengine/src/WallpaperEngine/Data/Parsers/` and `Data/Builders/`.

## End-to-End Sequence

1. The host builds an `AssetLocator`/`Container` stack that mounts:
   - the wallpaper directory at `/`
   - `scene.pkg` and `gifscene.pkg` when present
   - the shared Wallpaper Engine assets directory
   - the current working directory as a final fallback root
2. `project.json` is loaded from that container and parsed into `WallpaperEngine::Data::JSON::JSON`.
3. `ProjectParser::parse()` constructs `Project`.
4. `ProjectParser::parseProperties()` populates the project-wide property registry before any `UserSetting` is parsed.
5. `WallpaperParser::parse()` branches on `Project::type`.
6. For scene wallpapers, `WallpaperParser::parseScene()` loads the scene JSON named by `project.json["file"]`, parses camera/general/object sections, and delegates each object to `ObjectParser`.
7. `ObjectParser` recursively fans out into:
   - `ModelParser` for image models
   - `MaterialParser` for material files and particle materials
   - `EffectParser` for post-processing/effect graphs
   - `ShaderConstantParser` for pass constant maps
   - `UserSettingParser` anywhere a field may bind to a property, script, or conditional value
8. The final in-memory shape is a `Project` containing a `Scene` with a flat `ObjectList` and nested asset/pass graphs.

## Parser Responsibilities

| Parser | Primary input | Constructs | Key JSON keys |
| --- | --- | --- | --- |
| `ProjectParser` | `project.json` | `Project`, `Properties`, `Wallpaper` | `title`, `type`, `workshopid`, `general.supportsaudioprocessing`, `general.properties`, `file` |
| `PropertyParser` | one `general.properties.<key>` object | concrete `Property` subclass | `type`, `text`, `order`, `value`, `min`, `max`, `step`, `precision`, `options` |
| `WallpaperParser` | `project.json["file"]` and then the referenced scene/web/video payload | `Scene`, `Web`, or `Video` | scene: `camera`, `general`, `objects`; video/web: file path only |
| `ObjectParser` | one entry in scene `objects[]` | `Image`, `Sound`, `Light`, `Particle`, or fallback `Object` | `id`, `name`, `dependencies`, `parent`, `origin`, plus object-type-specific keys |
| `ModelParser` | model JSON file | `ModelStruct` | `material`, `solidlayer`, `fullscreen`, `passthrough`, `autosize`, `nopadding`, `width`, `height`, `puppet` |
| `MaterialParser` | material JSON file | `Material`, `MaterialPass` | `passes`, `blending`, `cullmode`, `depthtest`, `depthwrite`, `shader`, `textures`, `usertextures`, `combos`, `constantshadervalues` |
| `EffectParser` | effect JSON file | `Effect`, `EffectPass`, `FBO` | `name`, `description`, `group`, `preview`, `dependencies`, `passes`, `fbos`, `bind`, `command`, `source`, `target`, `material` |
| `ShaderConstantParser` | object/material/effect `constantshadervalues` object | `ShaderConstantMap` | arbitrary constant names; values go through `UserSettingParser` |
| `UserSettingParser` | any dynamic-value JSON slot | `UserSetting` + `DynamicValue` / `ScriptedDynamicValue` | `value`, `user`, `condition`, `script`, `scriptproperties` |
| `TextureParser` | binary `.tex`/related data | texture binary metadata, not scene model | texture header fields |
| `PackageParser` | `.pkg` archive binary | package file table | package header/file list |

## Detailed Scene Parse Walkthrough

### 1. Project root

`ProjectParser::parse()` does four important things in order:

1. Normalizes `type` to lowercase.
2. Converts `workshopid` to a string, falling back to a synthetic negative ID.
3. Parses `general.properties` into a `Properties` map.
4. Parses the wallpaper payload named by `file`.

Why the order matters:

- `Properties` must exist before scene/object parsing starts because most scene fields are parsed as `UserSetting` values that can bind back to properties.

### 2. Property registry

`ProjectParser::parseProperties()` iterates `general.properties`.

Dispatch is entirely type-based:

- `color` -> `PropertyColor`
- `bool` -> `PropertyBoolean`
- `slider` -> `PropertySlider`
- `combo` -> `PropertyCombo`
- `text` -> `PropertyText`
- `scenetexture` -> `PropertySceneTexture`
- `file` -> `PropertyFile`
- `textinput` -> `PropertyTextInput`
- missing `type` or `group` -> ignored group node
- unknown type -> logged and ignored

Fallback/error behavior:

- Properties with unsupported types are not fatal.
- Groups are silently skipped because they are UI structure, not runtime values.

### 3. Wallpaper type branch

`WallpaperParser::parse()` branches by `Project::type`:

- `scene` -> `parseScene`
- `video` -> `parseVideo`
- `web` -> `parseWeb`
- anything else -> exception

There is no schema-version switch here. Type branching is the main top-level format branch.

### 4. Scene root

`WallpaperParser::parseScene()` loads the referenced scene JSON file and requires:

- `camera`
- `general`
- `objects`

Parsed fields:

- `general.ambientcolor` -> ambient color
- `general.skylightcolor` -> skylight color
- `general.clearcolor` -> `UserSetting`
- `general.camerafade`
- `general.camerapreview`
- `general.bloom`, `bloomstrength`, `bloomthreshold`
- `general.cameraparallax`, `cameraparallaxamount`, `cameraparallaxdelay`, `cameraparallaxmouseinfluence`
- `general.camerashake`, `camerashakeamplitude`, `camerashakeroughness`, `camerashakespeed`
- `general.orthogonalprojection.width|height|auto`
- `camera.center|eye|up`
- `camera.nearz|farz|fov`

Defaulting behavior:

- Ambient/skylight default to zero vectors.
- Clear defaults to white.
- Projection width/height default to `0`.
- `orthogonalprojection.auto` defaults to `true` when the section is absent.
- `nearz`, `farz`, `fov` default to `0.01`, `1000`, and `50`.

### 5. Object dispatch

`ObjectParser::parse()` first tries to build `ObjectData`:

- `id` is required
- `name` is required, but a numeric `name` is tolerated by fallback code
- `dependencies` is optional array
- `parent` is optional integer
- `origin` is parsed as `UserSetting`

If base parsing throws, the parser logs the exception and falls back to:

- best-effort `id`
- stringified numeric `name`
- empty dependencies

Object-type dispatch uses key presence and value shape:

- `image` string -> image object
- `sound` array -> sound object
- `light` string -> light object
- `particle` present -> particle object
- `text` present -> logged unsupported
- malformed light -> logged unsupported light format
- anything else -> logged unknown object, returns base `Object`

This is a behaviorally important recovery point: unsupported objects do not abort the entire scene parse.

## Object-Specific Parse Paths

### Image path

`ObjectParser::parseImage()` reads:

- `scale`, `angles`, `visible`, `alpha`, `color`
- `alignment`, `size`, `parallaxDepth`, `colorBlendMode`, `brightness`
- model file from the `image` field
- optional `effects`
- optional `animationlayers`

Delegations:

- `ModelParser::load(project, imagePath)`
- `parseEffects()`
- `parseAnimationLayers()`

Normalization/fallback behavior:

- `scale` defaults to `1 1 1`
- `angles` defaults to `0 0 0`
- `visible` defaults to `true`
- `alpha` defaults to `1`
- `color` defaults to `1 1 1 1`
- `alignment` defaults to `center`
- `size` defaults to `0 0`
- `parallaxDepth` defaults to `0 0`
- If parsed color lands as vec3/ivec3, the parser promotes it to vec4/ivec4 to guarantee alpha.

### Sound path

`parseSound()` reads:

- `sound[]`
- optional `playbackmode`

No further nested parsing.

### Light path

`parseLight()` reads:

- `light` type alias (`lpoint`, `lspot`, `ltube`, `ldirectional`, `ldir`)
- `visible`, `angles`, `color`, `intensity`, `radius`, `length`, `innercone`, `outercone`
- `castshadow`

Fallback behavior:

- unknown light type logs and defaults to point light
- all numeric/light user settings have hardcoded defaults

### Particle path

`parseParticle()` is the most complex path and has two format branches:

1. `particle` is a string -> load referenced particle definition file
2. `particle` is an inline object -> parse directly

Keys in the particle definition file:

- `material`
- `animationmode`
- `sequencemultiplier`
- `maxcount`
- `starttime`
- `flags`
- `emitter[]`
- `initializer[]`
- `operator[]`
- `renderer[]`
- `controlpoint[]`
- optional `children[]`

Keys on the parent scene object:

- transform fields: `scale`, `angles`, `visible`, `parallaxDepth`
- optional `instanceoverride`

Delegations:

- `parseParticleEmitter()`
- `parseParticleInitializer()`
- `parseParticleOperator()`
- `parseParticleRenderer()`
- `parseParticleControlPoint()`
- `parseParticleChild()`
- `parseParticleInstanceOverride()`
- `MaterialParser::load()` for particle materials

Recovery/default behavior:

- missing `particle` key yields a valid but heavily defaulted `Particle`
- particle file load failures are logged and parsing continues with empty JSON
- renderer list gets a default sprite renderer if empty
- numeric/vector particle fields accept multiple shapes in several helpers:
  - strings like `"1 2 3"`
  - arrays like `[1,2,3]`
  - scalar numbers broadcast across components for some fields
- initializer/operator unknown names return `nullptr` and are skipped

### Effect/image-override path

Image objects can contain `effects[]`.

For each effect:

- `file` loads an effect JSON
- `visible` is a `UserSetting`
- optional `passes[]` applies per-pass overrides

Per-pass overrides read:

- `id`
- `combos`
- `textures`
- `constantshadervalues`
- optional `shaderOverride`

## Lower-Level Parsers

### `ModelParser`

`ModelParser::load()` loads a JSON file and requires `material`.

Optional flags/defaults:

- `solidlayer`, `fullscreen`, `passthrough`, `autosize`, `nopadding` default `false`
- `width`, `height`, `puppet` are optional

### `MaterialParser`

`MaterialParser::parse()` requires `passes`.

Each pass reads:

- `blending` default `normal`
- `cullmode` default `nocull`
- `depthtest` default `disabled`
- `depthwrite` default `disabled`
- required `shader`
- optional `textures[]`
- optional `usertextures[]`
- optional `combos`
- optional `constantshadervalues`

Fallback behavior:

- unknown blend/cull/depth strings are logged and coerced to safe defaults
- non-string texture entries are logged and replaced with empty-string placeholders

### `EffectParser`

`EffectParser::parse()` requires `passes`.

Optional keys:

- `name`, `description`, `group`, `preview`
- `dependencies[]`
- `fbos[]`

Per-pass behavior:

- `material` is optional
- `bind[]` is optional
- `command` can be `"copy"` or anything else interpreted as swap
- if `command` exists, `source` and `target` become required
- without `command`, `source`/`target` are optional

### `ShaderConstantParser`

- Iterates object/material/effect constant maps.
- Every entry is parsed via `UserSettingParser`.

### `UserSettingParser`

This parser is the real normalization boundary for runtime-driven values.

Accepted shapes:

1. Bare scalar/vector/null value
2. Object with:
   - `value`
   - optional `user`
   - optional conditional `user` object with `name` + `condition`
   - optional `script`
   - optional `scriptproperties`

Behavior:

- strings are heuristically parsed as vec2/vec3/vec4 by token count
- integers, floats, bools, and null map directly
- `user` binds the setting to an existing `Property`
- conditional `user` attaches a `ConditionInfo`
- `script` wraps the base `DynamicValue` in a `ScriptedDynamicValue`
- each `scriptproperties` entry is recursively parsed and its `value` is retained for script evaluation
- if a property link exists, the new value connects to that property so later property updates propagate automatically

Important implication for extraction:

- upstream "model" data is already partially runtime-wired by the time parsing finishes; it is not a purely immutable AST.

## Builders and Helpers in the Parse Path

| Component | Role |
| --- | --- |
| `VectorBuilder` | Converts space-delimited strings into `glm` vectors; used widely via `JSON::get()` and parser helpers. |
| `UserSettingBuilder` | Supplies default `UserSetting` instances from plain values when a field is absent. |
| `JSON::require/optional/user` helpers | Centralize missing-key validation, defaults, and `UserSettingParser` dispatch. |

## Schema/Version Branching

There is no explicit version field dispatch in the current scene parser path.

Actual branching points are format/shape based:

- project type string (`scene`, `video`, `web`)
- particle definition inline object vs referenced file
- light aliases (`ldirectional` / `ldir`)
- optional orthographic projection block
- optional command passes in effects
- optional scripts and conditional property bindings in `UserSetting`
- flexible vector encoding in particle helpers

That means compatibility work should treat "schema differences" as key-shape differences rather than a single version switch.

## Error Recovery and Non-Fatal Behavior

The parse flow is intentionally tolerant in several places:

- unsupported property types are logged and skipped
- malformed base object fields fall back to best-effort `id`/`name`
- unsupported object kinds become generic `Object` nodes instead of hard failure
- text objects are logged unsupported, not fatal
- particle file/material load failures are logged and parsing continues
- unknown particle initializers/operators are skipped
- unknown enum-like strings in materials/lights are logged and defaulted

Fatal paths remain where the engine cannot sensibly continue:

- missing `project.title`, `project.type`, or `project.file`
- missing scene `camera`, `general`, or `objects`
- missing required model/material/effect keys such as `material` or `passes`

## Rewrite Guidance for Native Parsing

If this flow were rewritten without reading the original C++:

1. Parse and register project properties first.
2. Parse scene/root metadata second.
3. Normalize all dynamic value slots through a single `UserSetting`-equivalent layer.
4. Keep object parsing tolerant and shape-driven.
5. Treat particles as their own subsystem with dedicated helper parsers.
6. Preserve non-fatal behavior for unsupported objects and malformed optional fields, because real workshop content depends on that tolerance.
