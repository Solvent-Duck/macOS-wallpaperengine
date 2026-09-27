# Script API Surface Inventory

Generated: 2026-04-03

Source: macOS Wallpaper Engine fork's QuickJS-based ScriptEngine
(`linux-wallpaperengine/src/WallpaperEngine/Scripting/ScriptEngine.cpp`)

---

## Host-Provided Bindings

The macOS fork implements a **minimal subset** of the Wallpaper Engine SceneScript API. Scripts are evaluated per-setting (not per-wallpaper), via `ScriptedDynamicValue`. The engine wraps each script in an IIFE that provides a limited set of globals and calls the script's `update(value)` function.

### Global Objects

| Object | Properties/Methods | Description | Per-Frame? |
|--------|-------------------|-------------|------------|
| `globalThis.__scriptProps` | `{[name]: value}` | Object containing current values of all `scriptproperties` connected to this setting. Populated from C++ `DynamicValue` map before each evaluation. Accessible inside the script via `createScriptProperties().finish()`. | On property change |
| `globalThis.__currentValue` | scalar or `{x,y,z,w}` | The current base value of the setting being scripted. Type depends on the DynamicValue type (float, int, bool, vec2/3/4, ivec2/3/4). | On property change |

### Global Functions

| Function | Signature | Description | Per-Frame? |
|----------|-----------|-------------|------------|
| `createScriptProperties()` | `() => Builder` | Returns a fluent builder object. The builder is used to declare script properties and their defaults. Returns an object with chaining methods and a terminal `.finish()`. | On evaluation |

### Builder Methods (returned by `createScriptProperties()`)

All builder methods return the builder itself for chaining. Each registers a default value for a named property if it is not already present in `__scriptProps`.

| Method | Signature | Description |
|--------|-----------|-------------|
| `addSlider` | `(opts: {name, value, ...}) => Builder` | Declares a slider (numeric) property with default `opts.value` |
| `addCheckbox` | `(opts: {name, value, ...}) => Builder` | Declares a checkbox (boolean) property with default `opts.value` |
| `addCombo` | `(opts: {name, value, ...}) => Builder` | Declares a combo/dropdown property with default `opts.value` |
| `addColor` | `(opts: {name, value, ...}) => Builder` | Declares a color property with default `opts.value` |
| `addText` | `(opts: {name, value, ...}) => Builder` | Declares a text (string) property with default `opts.value` |
| `finish` | `() => PropsObject` | Terminates the chain and returns the `__scriptProps` object |

### Lifecycle Callbacks

| Callback | When Called | Description |
|----------|------------|-------------|
| `update(value)` | On property change (reactive) | **Only implemented callback.** Called with `__currentValue`; return value replaces the setting's DynamicValue. Triggered whenever a connected `scriptproperty` changes, plus once at initialization. |

### NOT Implemented (Standard WE SceneScript APIs)

These are part of the real Wallpaper Engine SceneScript API (per [docs.wallpaperengine.io](https://docs.wallpaperengine.io)) but are **not exposed** by this engine:

| API | Type | Description |
|-----|------|-------------|
| `thisObject` | global object | Reference to the scene object owning the script (allows setting properties like `thisObject.bloomstrength`) |
| `applyUserProperties(changedUserProperties)` | callback | Called when user properties change; receives only the changed properties |
| `init()` | callback | Called once when the wallpaper initializes |
| `destroy()` | callback | Called when the wallpaper is destroyed |
| `engine.registerForCursorEvents(callback)` | function | Registers for mouse cursor events |
| `engine.timeout` / `engine.interval` | function | Timer scheduling |
| `engine.screenResolution` | property | Current screen resolution |
| `engine.runtime` | property | Time since wallpaper started |
| `input.cursorPosition` | property | Current cursor position |
| `input.cursorWorldPosition` | property | Cursor position in world space |
| `thisScene` | global object | Reference to the scene |
| `console.log` | function | Debug logging |

---

## DynamicValue Type Marshaling

The engine marshals values between C++ `DynamicValue` types and JavaScript:

| C++ Type | JS Representation | Direction |
|----------|------------------|-----------|
| `Float` | `number` (float64) | Both |
| `Int` | `number` (int32) | Both |
| `Boolean` | `boolean` | Both |
| `Vec2` | `{x, y}` (float) | Both |
| `Vec3` | `{x, y, z}` (float) | Both |
| `Vec4` | `{x, y, z, w}` (float) | Both |
| `IVec2` | `{x, y}` (int) | Both |
| `IVec3` | `{x, y, z}` (int) | Both |
| `IVec4` | `{x, y, z, w}` (int) | Both |

---

## Corpus Usage Frequency

Test wallpaper corpus: `~/wallpaper_engine/test_wallpapers/` (3 wallpapers: deep_space, neon_sunset, shimmering_particles)

**No `.js` files found** in the corpus. Script content is embedded inline in scene JSON files.

### Inline Scripts Found

| Wallpaper | Location | APIs Used | Script Pattern |
|-----------|----------|-----------|----------------|
| shimmering_particles | `scene.json` > `bloomstrength.script` | `applyUserProperties`, `thisObject` | Uses the **standard WE pattern** (`applyUserProperties` + `thisObject`), which is **not supported** by the current engine |

### API Usage Counts

| API | Wallpapers Using It | Total Calls | Implemented? |
|-----|---------------------|-------------|--------------|
| `createScriptProperties()` | 0 | 0 | Yes |
| `addSlider()` | 0 | 0 | Yes |
| `addCheckbox()` | 0 | 0 | Yes |
| `addCombo()` | 0 | 0 | Yes |
| `addColor()` | 0 | 0 | Yes |
| `addText()` | 0 | 0 | Yes |
| `finish()` | 0 | 0 | Yes |
| `update(value)` | 0 | 0 | Yes |
| `applyUserProperties()` | 1 (shimmering_particles) | 1 | **No** |
| `thisObject` | 1 (shimmering_particles) | 1 | **No** |

---

## Coverage Summary

- **Total APIs exposed by host:** 8 (createScriptProperties, addSlider, addCheckbox, addCombo, addColor, addText, finish, update)
- **APIs used in corpus:** 0 of 8 implemented APIs are used
- **APIs not used in corpus:** All 8 implemented APIs (createScriptProperties, addSlider, addCheckbox, addCombo, addColor, addText, finish, update)
- **Unimplemented APIs used in corpus:** 2 (applyUserProperties, thisObject)
- **Most-used APIs (top 10):** applyUserProperties (1), thisObject (1) -- both unimplemented

---

## Notes

1. **Script model mismatch.** The engine implements a `createScriptProperties()` + `update(value)` pattern where scripts are value transformers: they receive a current value, read properties, and return a new value. However, the one script found in the test corpus uses the `applyUserProperties(changedUserProperties)` + `thisObject` pattern, which is the standard WE SceneScript API for imperative property mutation. These are fundamentally different models -- the corpus script would silently fail or error because neither `applyUserProperties` nor `thisObject` is exposed.

2. **Evaluation trigger.** Scripts are re-evaluated reactively whenever a connected `scriptproperty`'s `DynamicValue` fires a change notification (via the `listen()` callback in `ScriptedDynamicValue`). This is not per-frame -- it is event-driven. An initial evaluation also occurs at construction time.

3. **No sandbox.** The QuickJS context is a bare `JS_NewContext` with no restrictions. Scripts have access to all default QuickJS globals. No `console`, `setTimeout`, or engine-specific globals are injected beyond the ones listed above.

4. **Script source transformation.** The engine strips `'use strict';` and `export` keywords via simple string replacement (`body.find/erase`), then wraps the body in an IIFE. This is fragile -- if a script contains the substring `"export "` in a string literal or comment, it will be corrupted.

5. **Error handling.** On script evaluation failure, the engine falls back to returning the original `currentValue` unchanged, and logs the JS exception. Scripts cannot crash the engine.

6. **Singleton runtime.** All scripts share a single `JSRuntime` and `JSContext` (singleton pattern). Globals set by one script evaluation (`__scriptProps`, `__currentValue`) are cleaned up immediately after evaluation, but any side effects on the global object from script code would persist across evaluations.

7. **Small corpus caveat.** The test corpus has only 3 wallpapers, and only 1 contains any script. Real-world WE wallpapers frequently use `createScriptProperties()` + `update(value)` for material parameter animation, so the implemented API is likely correct for the most common use case, even though the corpus doesn't demonstrate it.

8. **`scriptproperties` JSON key.** The parser in `UserSettingParser.cpp` reads `"scriptproperties"` (lowercase, no underscore) from JSON alongside `"script"` and `"value"` to connect script property inputs to other `UserSetting` values.
