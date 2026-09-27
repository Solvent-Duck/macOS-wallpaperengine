#pragma once

typedef struct WEScriptHostEvaluation {
    char* result_json;
    char* error_message;
    char* mutations_json;
} WEScriptHostEvaluation;

typedef struct WEScriptHost WEScriptHost;
// Returned strings are malloc-owned and released by the bridge after the call.
typedef WEScriptHostEvaluation (*WEScriptStorageHandler)(void* opaque, const char* request_json);
WEScriptHost* we_script_host_create(void);
void we_script_host_set_storage_handler(WEScriptHost* host, void* opaque, WEScriptStorageHandler handler);
void we_script_host_set_animation_handler(WEScriptHost* host, void* opaque, WEScriptStorageHandler handler);
void we_script_host_set_attachment_handler(WEScriptHost* host, void* opaque, WEScriptStorageHandler handler);
void we_script_host_set_text_layout_handler(WEScriptHost* host, void* opaque, WEScriptStorageHandler handler);
void we_script_host_set_scene_layer_handler(WEScriptHost* host, void* opaque, WEScriptStorageHandler handler);
void we_script_host_shutdown(WEScriptHost* host);
void we_script_host_destroy(WEScriptHost* host);
// -1 before the value module exists; otherwise whether it exports update.
int we_script_host_value_instance_has_update(WEScriptHost* host, const char* instance_id);

// Retain a JSON snapshot for value evaluations whose engine omits userProperties.
// Each evaluation receives an independent copy; an explicit engine value wins.
WEScriptHostEvaluation we_script_host_set_user_properties_json(WEScriptHost* host, const char* json);

// Private common engine inputs for value evaluations. Each call receives a
// fresh deep copy, with explicit engine_json members taking precedence.
WEScriptHostEvaluation we_script_host_set_engine_snapshot_json(WEScriptHost* host, const char* json);

// Install the bundled scene binding implementation (source on first call),
// then exchange structured state with that implementation.
WEScriptHostEvaluation we_script_host_scene_json(
    WEScriptHost* host, const char* source, const char* command_json
);

WEScriptHostEvaluation we_script_host_evaluate_json(
    WEScriptHost* host,
    const char* instance_id,
    const char* script_source,
    const char* script_properties_json,
    const char* current_value_json,
    const char* engine_json,
    const char* input_json
);

WEScriptHostEvaluation we_scene_script_host_execute_json(
    WEScriptHost* host,
    const char* instance_id,
    const char* script_source,
    const char* callback_name,
    const char* this_object_json,
    const char* changed_user_properties_json,
    const char* engine_json,
    const char* input_json
);

void we_script_host_free_evaluation(WEScriptHostEvaluation evaluation);
