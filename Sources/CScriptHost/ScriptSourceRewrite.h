#pragma once
#include <stdbool.h>

// Rewrite supported SceneScript module declarations for its persistent function
// scope. The returned source is malloc-owned. Authored literals stay unchanged.
char* we_rewrite_script_source(const char* source);
bool we_script_source_is_strict(const char* source);
