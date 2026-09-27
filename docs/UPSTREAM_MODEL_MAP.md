# Upstream Model Map

Phase 2.1 deliverable for `linux-wallpaperengine/src/WallpaperEngine/Data/Model/`.

## Summary

- The upstream scene model is parse-heavy and ownership-heavy: nearly every major node owns nested `unique_ptr` graphs.
- Hot-path state is concentrated in `DynamicValue`, `UserSetting`, scene camera settings, object transforms/visibility, light intensities, and particle operator/initializer parameters.
- Cold-path state is mostly file metadata, editor labels, dependency lists, pass declarations, and static asset references.
- Runtime mutation is rarely done by replacing model objects. Instead, the engine mutates `DynamicValue` instances and reaches them through `UserSetting` and `Property` connections.

## Cross-Cutting Patterns

### Dynamic value graph

| Type | Inheritance | Fields | Mutable at runtime | Hot/cold | Relationships |
| --- | --- | --- | --- | --- | --- |
| `ConditionInfo` | none | `name: string`, `condition: string` | No | Cold | Attached to `DynamicValue`/`UserSetting` for conditional activation. |
| `DynamicValue` | polymorphic base | cached scalar/vector/string representations, listener list, connection list, current `UnderlyingType`, optional condition | Yes, this is the main runtime mutation point | Hot | Owned by `UserSetting`, `Property`, and scripted-property maps. Connected to other `DynamicValue` instances. |
| `ScriptedDynamicValue` | `DynamicValue` | `m_scriptSource: string`, `m_scriptProps: map<string, DynamicValueUniquePtr>`, `m_baseValue: DynamicValue` | Yes, reevaluates when script props change | Hot | Built by `UserSettingParser` when JSON includes `script`; uses `ScriptEngine`. |
| `UserSetting` | none | `value: DynamicValueUniquePtr`, `property: PropertySharedPtr`, `condition: optional<ConditionInfo>` | Yes through `value`; `property` link is stable | Hot when consumed every frame | Bridge object between parsed JSON values and live property-driven/script-driven runtime values. |

### Shared ownership/value aliases

| File/type | Purpose | Mutable at runtime | Hot/cold | Relationships |
| --- | --- | --- | --- | --- |
| `Types.h` aliases | `Properties`, `ObjectList`, `TextureMap`, `ComboMap`, many pointer aliases | Container contents are effectively stable after parse; pointed-to `DynamicValue` state changes | Mixed | Used everywhere; important because almost all model references are alias-driven rather than ID-driven. |

## Project-Level Types

### `Project.h`

| Type | Inheritance | Fields | Mutable at runtime | Hot/cold | Relationships |
| --- | --- | --- | --- | --- | --- |
| `Project` | none | `title`, `type`, `workshopId`, `supportsAudioProcessing`, `properties`, `wallpaper`, `assetLocator` | `properties` values mutate; rest stable after parse | Title/type/workshop are cold, `properties` hot, `assetLocator` load-time | Root owner for the whole wallpaper. Owns `Wallpaper` subtree and property registry. |

## Wallpaper-Level Types

### `Wallpaper.h`

| Type | Inheritance | Fields | Mutable at runtime | Hot/cold | Relationships |
| --- | --- | --- | --- | --- | --- |
| `WallpaperData` | none | `filename`, `project&` | No | Cold | Shared base payload for every wallpaper kind. |
| `Wallpaper` | `TypeCaster`, `WallpaperData` | inherited fields only | No | Cold | Base class for `Scene`, `Video`, `Web`. |
| `Video` | `Wallpaper` | no extra fields | No | Cold | Leaf variant for video wallpapers. |
| `Web` | `Wallpaper` | no extra fields | No | Cold | Leaf variant for web wallpapers. |
| `SceneData.colors` | nested struct | `ambient: vec3`, `skylight: vec3`, `clear: UserSettingUniquePtr` | `clear` mutates, ambient/skylight do not | `clear` hot, colors mostly cold | Owned by `Scene`. |
| `SceneData.camera.bloom` | nested struct | `enabled`, `strength`, `threshold` as `UserSettingUniquePtr` | Yes | Hot | Read per frame by scene/camera/bloom render code. |
| `SceneData.camera.parallax` | nested struct | `enabled`, `amount`, `delay`, `mouseInfluence` | Yes | Hot | Consumed in camera updates each frame. |
| `SceneData.camera.shake` | nested struct | `enabled`, `amplitude`, `roughness`, `speed` | Yes | Hot | Consumed in camera updates each frame. |
| `SceneData.camera.configuration` | nested struct | `center`, `eye`, `up` | No after parse | Warm: loaded once, reused every frame | Defines base camera transform. |
| `SceneData.camera.projection` | nested struct | `width`, `height`, `isAuto`, `nearz`, `farz`, `fov` | No after parse | Warm | Used in projection setup and output sizing. |
| `SceneData` | none | `colors`, `camera`, `objects: ObjectList` | `UserSetting` subfields mutate | Objects and camera settings are hot | Owned by `Scene`. |
| `Scene` | `Wallpaper`, `SceneData` | inherited fields plus all scene payload | Nested settings mutate | Hot | Owns the flat list of scene objects. |

## Object Graph Types

### `Object.h` base and common image/light/sound types

| Type | Inheritance | Fields | Mutable at runtime | Hot/cold | Relationships |
| --- | --- | --- | --- | --- | --- |
| `ObjectData` | none | `id`, `name`, `dependencies`, `parent`, `origin` | `origin` mutates, IDs/names/deps do not | IDs/deps cold, `origin` hot | Shared payload for all object subclasses. |
| `Object` | `TypeCaster`, `ObjectData` | inherited only | `origin` through `UserSetting` | Hot | Base for `Image`, `Sound`, `Light`, `Particle`. |
| `ImageEffectPassOverride` | none | `id`, `combos`, `constants`, `textures`, `shaderOverride` | Usually stable after parse | Cold/warm | Nested inside `ImageEffect`; overrides `EffectPass`/`MaterialPass`. |
| `ImageEffect` | none | `id`, `name`, `visible`, `passOverrides`, `effect` | `visible` mutates | Visible is hot, effect/pass definitions cold | Owned by `Image`. References `Effect`. |
| `ImageAnimationLayer` | none | `id`, `rate`, `visible`, `blend`, `animation` | `visible` mutates | Warm/hot | Owned by `Image`. |
| `ImageData` | none | `scale`, `angles`, `visible`, `alpha`, `color`, `alignment`, `size`, `parallaxDepth`, `colorBlendMode`, `brightness`, `model`, `effects`, `animationLayers` | User-setting fields mutate; asset references do not | Transform/visibility/color hot; model/effects cold | Owned by `Image`. |
| `Image` | `Object`, `ImageData` | inherited plus image payload | Yes through `UserSetting` | Hot | References `ModelStruct`, `Effect`, animation layers. |
| `SoundData` | none | `playbackmode`, `sounds` | No | Cold | Owned by `Sound`. |
| `Sound` | `Object`, `SoundData` | inherited plus sound payload | Only inherited `origin` mutates | Mostly cold | Leaf object that points to audio assets. |
| `LightType` | enum | `Point`, `Spot`, `Tube`, `Directional` | No | Cold | Used by `Light`. |
| `LightData` | none | `type`, `visible`, `angles`, `color`, `intensity`, `radius`, `length`, `innerCone`, `outerCone`, `castShadow` | All `UserSetting` fields mutate; type/shadow flag stable | Hot | Owned by `Light`. |
| `Light` | `Object`, `LightData` | inherited plus light payload | Yes | Hot | Leaf lighting node consumed each frame. |

### Particle support types

| Type | Inheritance | Fields | Mutable at runtime | Hot/cold | Relationships |
| --- | --- | --- | --- | --- | --- |
| `ParticleControlPoint` | none | `id`, `flags`, `offset`, `lockToPointer` | Pointer lock may influence runtime behavior but parsed values stable | Warm | Used by particle operators/children. |
| `ParticleEmitter` | none | identifier plus direction/origin/range/rate/audio fields | Parsed fields stay stable | Warm/hot | Owned by `Particle`; emitted into runtime particle system. |
| `ParticleRenderer` | none | renderer style/rope-trail settings | No | Warm | Owned by `Particle`. |
| `ParticleChild` | none | child type/name/count/control-point linkage/transforms/particle file | No | Warm | Owned by `Particle`. |
| `ParticleInstanceOverride` | none | `enabled`, `alpha`, `size`, `lifetime`, `rate`, `speed`, `count`, `color`, `colorn` | Yes | Hot | Owned by `Particle`; applied to spawned particle instances. |
| `ParticleData` | none | transform settings, `particleFile`, animation config, `material`, emitter/initializer/operator/renderer/control-point/child arrays, instance override | User settings mutate; structure arrays do not | Hot | Owned by `Particle`. |
| `Particle` | `Object`, `ParticleData` | inherited plus particle payload | Yes | Hot | Most complex object variant. |

### Particle initializer classes

| Type | Inheritance | Fields | Mutable at runtime | Hot/cold | Relationships |
| --- | --- | --- | --- | --- | --- |
| `ParticleInitializerBase` | `TypeCaster` | none | N/A | Warm | Base for initializer RTTI dispatch. |
| `ColorRandomInitializer` | `ParticleInitializerBase` | `min`, `max` | Yes through `UserSetting` | Hot | Particle spawn-time color range. |
| `SizeRandomInitializer` | `ParticleInitializerBase` | `min`, `max`, `exponent` | Yes | Hot | Particle spawn-time size range. |
| `AlphaRandomInitializer` | `ParticleInitializerBase` | `min`, `max` | Yes | Hot | Particle spawn-time alpha range. |
| `LifetimeRandomInitializer` | `ParticleInitializerBase` | `min`, `max` | Yes | Hot | Particle lifetime range. |
| `VelocityRandomInitializer` | `ParticleInitializerBase` | `min`, `max` | Yes | Hot | Initial velocity range. |
| `RotationRandomInitializer` | `ParticleInitializerBase` | `min`, `max` | Yes | Hot | Initial rotation range. |
| `AngularVelocityRandomInitializer` | `ParticleInitializerBase` | `min`, `max`, `exponent` | Yes | Hot | Angular velocity distribution. |
| `TurbulentVelocityRandomInitializer` | `ParticleInitializerBase` | `speedMin`, `speedMax`, `scale`, `offset`, `forward`, `timeScale`, `phaseMin`, `phaseMax`, `right` | Yes | Hot | Noise-driven initial velocity. |
| `MapSequenceAroundControlPointInitializer` | `ParticleInitializerBase` | `controlPoint`, `count`, `speedMin`, `speedMax` | Yes | Hot | Sequence mapping around a control point. |

### Particle operator classes

| Type | Inheritance | Fields | Mutable at runtime | Hot/cold | Relationships |
| --- | --- | --- | --- | --- | --- |
| `ParticleOperatorBase` | `TypeCaster` | none | N/A | Warm | Base for operator RTTI dispatch. |
| `MovementOperator` | `ParticleOperatorBase` | `drag`, `gravity` | Yes | Hot | Per-frame particle integration. |
| `AngularMovementOperator` | `ParticleOperatorBase` | `drag`, `force` | Yes | Hot | Per-frame angular integration. |
| `AlphaFadeOperator` | `ParticleOperatorBase` | `fadeInTime`, `fadeOutTime` | Yes | Hot | Lifetime alpha modulation. |
| `SizeChangeOperator` | `ParticleOperatorBase` | `startTime`, `endTime`, `startValue`, `endValue` | Yes | Hot | Lifetime size curve. |
| `AlphaChangeOperator` | `ParticleOperatorBase` | `startTime`, `endTime`, `startValue`, `endValue` | Yes | Hot | Lifetime alpha curve. |
| `ColorChangeOperator` | `ParticleOperatorBase` | `startTime`, `endTime`, `startValue`, `endValue` | Yes | Hot | Lifetime color curve. |
| `TurbulenceOperator` | `ParticleOperatorBase` | `scale`, `speedMin`, `speedMax`, `timeScale`, `mask`, `phaseMin`, `phaseMax`, audio-processing fields | Yes | Hot | Noise/audio-driven movement. |
| `VortexOperator` | `ParticleOperatorBase` | `controlPoint`, `flags`, axis/offset/radius/speed/ring/audio fields | Yes | Hot | Control-point-relative vortex behavior. |
| `ControlPointAttractOperator` | `ParticleOperatorBase` | `controlPoint`, `origin`, `scale`, `threshold` | Yes | Hot | Pull particles toward a control point. |
| `OscillateAlphaOperator` | `ParticleOperatorBase` | frequency/scale/phase bounds | Yes | Hot | Oscillating alpha. |
| `OscillateSizeOperator` | `ParticleOperatorBase` | frequency/scale/phase bounds | Yes | Hot | Oscillating size. |
| `OscillatePositionOperator` | `ParticleOperatorBase` | frequency/scale/phase bounds, `mask` | Yes | Hot | Oscillating offset. |

## Asset/Render Description Types

### `Material.h`

| Type | Inheritance | Fields | Mutable at runtime | Hot/cold | Relationships |
| --- | --- | --- | --- | --- | --- |
| `BlendingMode`, `CullingMode`, `DepthtestMode`, `DepthwriteMode` | enums | render-state selectors | No | Cold | Used by `MaterialPass`. |
| `MaterialPass` | none | blending/cull/depth state, `shader`, `textures`, `usertextures`, `combos`, `constants` | Parsed structure stable; shader constants can hold mutable `UserSetting` values | Pass definition cold, constants hot | Owned by `Material`; consumed during render passes. |
| `Material` | none | `filename`, `passes` | No after parse | Warm | Owned by `ModelStruct` or `EffectPass`. |

### `Effect.h`

| Type | Inheritance | Fields | Mutable at runtime | Hot/cold | Relationships |
| --- | --- | --- | --- | --- | --- |
| `PassCommandType` | enum | `Copy`, `Swap` | No | Cold | Used by `EffectPass`. |
| `FBO` | none | `name`, `format`, `scale`, `unique` | No | Cold | Owned by `Effect`. |
| `EffectPass` | none | optional `material`, `binds`, optional `command`, optional `source`, optional `target` | No after parse | Warm | Owned by `Effect`; can embed a `Material`. |
| `Effect` | none | `name`, `description`, `group`, `preview`, `dependencies`, `passes`, `fbos` | No after parse | Warm | Referenced by `ImageEffect`. |

### `Model.h`

| Type | Inheritance | Fields | Mutable at runtime | Hot/cold | Relationships |
| --- | --- | --- | --- | --- | --- |
| `ModelStruct` | none | `filename`, `material`, `solidlayer`, `fullscreen`, `passthrough`, `autosize`, `nopadding`, optional `width`, optional `height`, optional `puppet` | No after parse | Warm | Owned by `Image` or wrapped for `Particle`. References `Material`. |

## Property Types

### `Property.h`

| Type | Inheritance | Fields | Mutable at runtime | Hot/cold | Relationships |
| --- | --- | --- | --- | --- | --- |
| `PropertyData` | none | `name`, `text`, `order` | No after parse | Warm | Shared property metadata. |
| `SliderData` | none | `min`, `max`, `step`, `precision` | No after parse | Warm | Shared slider metadata. |
| `ComboData` | none | `values: map<string, string>` | No after parse | Warm | Shared combo options. |
| `Property` | `DynamicValue`, `TypeCaster`, `PropertyData` | inherited live value plus metadata | Yes | Hot | Root property type stored in `Project.properties`. |
| `PropertySlider` | `Property` + private `SliderData` | slider metadata and float value | Yes | Hot | Connected into many `UserSetting` instances. |
| `PropertyBoolean` | `Property` | bool value | Yes | Hot | Connected into `UserSetting`. |
| `PropertyColor` | `Property` | color value encoded through `DynamicValue` | Yes | Hot | Connected into `UserSetting`. |
| `PropertyCombo` | `Property` + private `ComboData` | option map and selected key | Yes | Hot | Connected into `UserSetting`. |
| `PropertyText` | `Property` | display-only label | Runtime updates intentionally ignored | Cold | UI/editor metadata only. |
| `PropertySceneTexture` | `Property` | `m_value: string` | Potentially yes, though usually stable | Warm | Scene texture asset/property. |
| `PropertyFile` | `Property` | `m_value: string` | Potentially yes | Warm | File picker property. |
| `PropertyTextInput` | `Property` | `m_value: string` | Potentially yes | Warm | Free-form text property. |

## Ownership/Dependency Notes Relevant to Extraction

- `Project` is the true ownership root. Every parser ultimately hangs data off that tree.
- `Property` and `UserSetting` form the runtime mutation boundary. That is the key boundary Phase 2 needed to normalize into Swift value descriptors.
- `ObjectList` is already flat and ID-based, but parent/dependency references are stored as ad hoc integers rather than stable handle types.
- `Material`, `Effect`, and `ModelStruct` are nested and duplicated structurally. The upstream model does not intern them.
- Text objects are not represented as a first-class parsed model in this fork yet; the parser logs them as unsupported.
