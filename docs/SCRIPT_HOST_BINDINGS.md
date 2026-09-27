# Script Host Bindings

Phase 6 replaces the heuristic scripted-value evaluator with an owned QuickJS-backed host that matches the current upstream `ScriptEngine.cpp` behavior.

## Binding Inventory

Source of truth:

- upstream host: `linux-wallpaperengine/src/WallpaperEngine/Scripting/ScriptEngine.cpp`
- prior corpus inventory: [`SCRIPT_API_INVENTORY.md`](./SCRIPT_API_INVENTORY.md)

The current upstream host is not a full SceneScript runtime. It is a small scripted-dynamic-value evaluator that wraps each script and calls `update(value)`.

### Globals injected for each evaluation

| Binding | Kind | Reads/Writes | Call frequency | Corpus frequency |
| --- | --- | --- | --- | --- |
| `globalThis.__scriptProps` | global object | reads current `scriptproperties` values; writable by script | per evaluation | internal host detail only |
| `globalThis.__currentValue` | global value | reads the base dynamic value passed into `update(value)` | per evaluation | internal host detail only |

### Host function

| Binding | Signature | Reads/Writes | Call frequency | Corpus frequency |
| --- | --- | --- | --- | --- |
| `createScriptProperties` | `() -> Builder` | reads/writes `__scriptProps` defaults | per evaluation when script uses it | 0 in sample corpus |

### Builder methods

Each builder method adds a default value only when the property key is not already present in `__scriptProps`, then returns the builder for chaining.

| Binding | Signature | Reads/Writes | Call frequency | Corpus frequency |
| --- | --- | --- | --- | --- |
| `addSlider` | `({ name, value, ... }) -> Builder` | writes default numeric property | per evaluation if used | 0 |
| `addCheckbox` | `({ name, value, ... }) -> Builder` | writes default boolean property | per evaluation if used | 0 |
| `addCombo` | `({ name, value, ... }) -> Builder` | writes default combo property | per evaluation if used | 0 |
| `addColor` | `({ name, value, ... }) -> Builder` | writes default color property | per evaluation if used | 0 |
| `addText` | `({ name, value, ... }) -> Builder` | writes default text property | per evaluation if used | 0 |
| `finish` | `() -> Object` | returns the resolved script properties object | per evaluation if used | 0 |

### Expected script entrypoint

| Binding | Signature | Reads/Writes | Call frequency | Corpus frequency |
| --- | --- | --- | --- | --- |
| `update` | `(value) -> value` | reads current value and script properties; returns replacement dynamic value | per scripted-value evaluation | 0 in sample corpus |

## Marshaling Behavior

The owned host keeps the same value-shape contract as the upstream host:

- scalars map to JS numbers / booleans / strings
- vectors map to JS objects with `x`, `y`, `z`, `w`
- the returned JS value is converted back using the original base-value shape as the hint

This means:

- `vec2/3/4` scripts return `{x,y[,z[,w]]}`
- integer vectors preserve integer slots when the base value is an integer vector
- evaluation failures fall back to the base value

## Corpus Notes

The current sample corpus does not contain any scripts that match this host model.

Observed script usage from [`SCRIPT_API_INVENTORY.md`](./SCRIPT_API_INVENTORY.md):

- `shimmering_particles` uses `applyUserProperties(changedUserProperties)` and `thisObject`
- those are scene-level callback APIs, not scripted-dynamic-value bindings
- they are still out of scope for the extracted model at this point, because Phase 2 only exports scripted dynamic values, not top-level scene script callbacks

## Phase 6 Scope

Implemented in this phase:

- owned QuickJS-backed replacement for upstream `update(value)` scripted dynamic values
- builder/default-property compatibility for `createScriptProperties()`
- error reporting that surfaces the actual QuickJS exception text to Swift

Still deferred:

- scene-level callbacks like `applyUserProperties`, `init`, `destroy`
- bindings like `thisObject`, `thisScene`, `engine.*`, `input.*`
- imperative mutation scripts attached to scene/general objects rather than value-returning scripted dynamic values
