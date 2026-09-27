# Shader Pipeline

Phase 3.1 deliverable for `NativeSceneCompatibility` and the standalone shader compiler bridge.

## Goal

Move shader preprocessing and pipeline assembly out of the upstream fork so shader compatibility work happens in repo-owned Swift code. The only remaining native dependency in this phase is the GLSL -> SPIR-V -> MSL compiler wrapper in `Sources/CShaderCompiler/`.

## End-to-End Flow

1. A caller constructs `ShaderCompilationRequest` with:
   - `shaderPath`
   - asset roots
   - material combo values
   - override combo values
2. `ShaderPipeline.compile()` loads the raw `.vert` and `.frag` sources through `ShaderAssetResolver`.
3. `ComboResolver` scans the raw sources for `// [COMBO] ...` metadata and discovers fallback combo defaults that were not already supplied by material data.
4. `ComboResolver` emits the final `#define` block in precedence order:
   - override combos
   - material combos
   - discovered defaults
5. `ShaderPreprocessor` resolves shader-library references:
   - top-level `#include "file"` blocks are loaded and injected before `main`
   - top-level `#require lib/name` blocks are expanded inline
   - nested `#include` and `#require` inside libraries are recursively resolved inline
6. `ShaderPreprocessor` runs sanitizer passes for malformed workshop shaders:
   - drops orphan `#endif`
   - appends missing closing `#endif`
   - rewrites fragment shaders that assign to `varying` inputs inside `main`
7. `ShaderPipeline` assembles final GLSL:
   - shared compatibility header
   - stage-specific defines (`attribute`/`varying`, `out_FragColor`)
   - combo define block
   - preprocessed shader body
8. `MetalShaderCompiler` passes the final vertex and fragment GLSL to `CShaderCompiler`.
9. `CShaderCompiler` runs:
   - glslang parse/link
   - SPIR-V generation
   - SPIRV-Cross MSL generation
   - slot reflection
   - uniform-slot compaction
   - promoted uniform address-space rewrites
10. `ShaderPipeline` returns `CompiledShaderPair` with:
   - final vertex GLSL
   - final fragment GLSL
   - discovered combos
   - compiled/reflected MSL payload

## NativeSceneCompatibility Ownership

`Sources/NativeSceneCompatibility/Shaders/` now owns:

- `ShaderTypes.swift`
  Request/result types and error surface.
- `ShaderAssetResolver.swift`
  Asset lookup for shader files and shader libraries.
- `ShaderMetadata.swift`
  Relaxed parsing for malformed combo metadata comments.
- `ComboResolver.swift`
  Combo discovery and `#define` block generation.
- `ShaderPreprocessor.swift`
  `#include` / `#require` expansion and shader sanitizer passes.
- `MetalShaderCompiler.swift`
  Swift wrapper over the standalone C compiler bridge.
- `ShaderPipeline.swift`
  End-to-end orchestration.

This target depends on `NativeSceneCore` for shared type ownership and `CShaderCompiler` for native compilation, but it does not depend on `CWEBridge` or the upstream runtime classes.

## Asset Resolution Rules

The resolver mirrors the upstream shader path expectations:

- vertex shader: `<shaderPath>.vert`
- fragment shader: `<shaderPath>.frag`
- include library: `<path>.h`
- standard lookup root: `<assetRoot>/shaders/...`

Workshop compatibility rewrite:

- if the requested shader path matches `workshop/<id>/effects/<name>`, the resolver first tries:
  - `<assetRoot>/zcompat/scene/shaders/<id>/<name>.<ext>`
- otherwise it falls back to:
  - `<assetRoot>/shaders/workshop/<id>/effects/<name>.<ext>`

This matches the macOS fork behavior where repackaged scene shaders can be staged under `zcompat/scene/shaders/<workshopId>/`.

## Include and Require Behavior

`ShaderPreprocessor` intentionally distinguishes the two upstream directives:

- `#include "file"`
  - loads the target library
  - recursively resolves nested library references inside it
  - stores the resolved content in a separate include block
  - injects that block before `main`
  - leaves a comment marker at the original include site
- `#require lib/name`
  - loads the target library
  - recursively resolves nested library references inside it
  - expands the resolved content inline at the require site

Markers are preserved as comments so the generated GLSL remains debuggable when compared against upstream dumps.

## Combo Parsing and Fork Fixes

Combo discovery is driven by comment metadata in the source, for example:

```glsl
// [COMBO] {"combo":"AA_CATEGORY","default":0}
```

The parser intentionally accepts malformed workshop variants that appeared in the fork patches:

- trailing commas in metadata JSON
- bare keys inside JSON-like metadata objects
- numeric defaults encoded as strings
- float-like/default values that still need to collapse to an integer combo define
- prose comments that should not be treated as metadata at all

If a combo was already provided by material data or explicit overrides, discovery skips it. This preserves the same precedence the renderer expects at runtime.

## GLSL Compatibility Header

Each compiled shader receives the repo-owned compatibility header from `ShaderPipeline`:

- GLSL version declaration
- HLSL-style helper macros such as `mul`, `lerp`, `frac`, `saturate`
- texture sampling aliases
- derivative aliases
- stage-specific mappings:
  - vertex: `#define attribute in`, `#define varying out`
  - fragment: `#define varying in`, `out vec4 out_FragColor`

This is the point where the pipeline stops depending on upstream `ShaderUnit` assembly logic.

## Sanitizer Passes

Two fork-specific shader repairs were carried forward into owned code.

### Conditional repair

Workshop shaders occasionally contain:

- orphan `#endif`
- unclosed `#if` / `#ifdef` / `#ifndef`

`sanitizeConditionals()` drops unmatched closing directives and appends missing `#endif` lines at the end of the source.

### Fragment varying mutation repair

Some workshop fragment shaders assign directly to `varying` inputs, which is illegal after the vertex/fragment interface is mapped to modern GLSL and then MSL.

`sanitizeFragmentVaryings()`:

1. discovers fragment `varying` declarations
2. detects writes to those names inside `main`
3. injects mutable local shadow variables at function entry
4. rewrites name usage through `#define` aliases

This preserves upstream fork behavior and allows SPIR-V/MSL translation to succeed on pathological shaders.

## Native Compiler Bridge

`Sources/CShaderCompiler/ShaderCompilerBridge.cpp` is a standalone extraction of the relevant `GLSLContext.cpp` logic. It does not instantiate the upstream renderer or scene engine.

Responsibilities:

- initialize/finalize glslang process state
- compile vertex and fragment stages
- link both stages into a program
- emit SPIR-V
- cross-compile to MSL through SPIRV-Cross
- reflect:
  - vertex attributes
  - vertex uniform slots
  - fragment uniform slots
  - fragment texture slots
  - fragment sampler slots
- compact Metal buffer slots into the low contiguous range
- rewrite promoted uniform references from `thread const` to `constant` when required by the generated MSL
- return a JSON payload so Swift can decode results without owning C++ structs

Public C API:

- `nsc_compile_shader_pair_to_msl_json`
- `nsc_free_compiler_string`

## Built-In Shader Library Locations

At runtime, shader code can come from:

- wallpaper-local `shaders/`
- workshop compatibility rewrites under `zcompat/scene/shaders/`
- shared Wallpaper Engine asset roots already mounted by the app-side asset locator

The native pipeline does not hardcode library contents; it relies on asset roots passed in through `ShaderCompilationRequest`.

## Known Malformed Workshop Patterns

The current owned pipeline explicitly tolerates these patterns because they were already observed in fork patches and fixture design:

- malformed combo metadata comments
- prose comments adjacent to metadata
- shaders with missing or extra conditional terminators
- fragment shaders that mutate varyings
- workshop shader IDs that must be rewritten through `zcompat`

Still intentionally out of scope for Phase 3:

- semantic validation of every workshop shader variant in the local canary corpus
- renderer-side uniform packing or pass binding behavior
- runtime material/light combo injection performed later by the renderer

## Verification Artifacts

Phase 3 adds repo-owned shader fixtures under `CompatibilitySuite/shader_fixtures/` covering:

- include + require + malformed combo metadata
- fragment varying mutation repair
- workshop `zcompat` shader-path rewrite

Verification runner:

- `CompatibilitySuite/run_shader_fixtures.py`

Compiler fixture emitter:

- `ShaderFixtureTool`

The current acceptance command is:

```bash
python3 CompatibilitySuite/run_shader_fixtures.py
```
