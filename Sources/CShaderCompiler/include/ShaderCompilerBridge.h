#ifndef NSC_SHADER_COMPILER_BRIDGE_H
#define NSC_SHADER_COMPILER_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

char* nsc_compile_shader_pair_to_msl_json(const char* vertex_source, const char* fragment_source);
/// Expand macros and conditional branches, returning null on failure. Free
/// successful results with nsc_free_compiler_string.
char* nsc_preprocess_shader_source(const char* source, int is_fragment);
void nsc_free_compiler_string(char* value);

/// Explicitly finalize glslang process state. Call before exit to avoid
/// crashes from C++ static destructors running in undefined order.
void nsc_finalize_glslang(void);

#ifdef __cplusplus
}
#endif

#endif
