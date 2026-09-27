#include "ScriptVectorPrelude.h"
#include "ScriptMatrixPrelude.h"
#include "ScriptAssetPrelude.h"
#include "ScriptMediaPrelude.h"
#include "ScriptHostBridge.h"
#include "ScriptSourceRewrite.h"

#include <stdbool.h>
#include <stddef.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "quickjs.h"

struct WEScriptHost {
    JSRuntime* runtime;
    JSContext* context;
    JSValue value_dispatcher;
    JSValue user_properties;
    JSValue engine_snapshot;
    pthread_t stack_thread;
    void* storage_opaque;
    WEScriptStorageHandler storage_handler;
    void* animation_opaque;
    WEScriptStorageHandler animation_handler;
    void* attachment_opaque;
    WEScriptStorageHandler attachment_handler;
    void* text_layout_opaque;
    WEScriptStorageHandler text_layout_handler;
    void* scene_layer_opaque;
    WEScriptStorageHandler scene_layer_handler;
};

// Swift serializes access to each host, but serial queues and async callers
// may use different OS threads between calls. QuickJS's stack limit is an
// address in the previous thread's stack until explicitly refreshed. Do not
// reset it for nested calls on the same thread: recursion stays bounded.
static void configure_stack_thread(WEScriptHost* host) {
    pthread_t current = pthread_self();
    char marker;
    uintptr_t bottom = (uintptr_t)pthread_get_stackaddr_np(current) - pthread_get_stacksize_np(current);
    size_t available = (uintptr_t)&marker - bottom;
    // macOS worker stacks can be smaller than QuickJS's 1MiB default.
    // Reserve native callback/unwinding space so JS recursion throws before
    // reaching the OS guard page.
    size_t budget = available > 65536 ? available - 65536 : available / 2;
    JS_SetMaxStackSize(host->runtime, budget < JS_DEFAULT_STACK_SIZE ? budget : JS_DEFAULT_STACK_SIZE);
    JS_UpdateStackTop(host->runtime);
    host->stack_thread = current;
}

static void update_stack_thread(WEScriptHost* host) {
    pthread_t current = pthread_self();
    if (!pthread_equal(host->stack_thread, current)) {
        configure_stack_thread(host);
    }
}

static JSValue text_layout_request(JSContext* ctx, JSValueConst this_value, int argc, JSValueConst* argv) {
    WEScriptHost* host = JS_GetContextOpaque(ctx);
    if (argc < 1 || host == NULL || host->text_layout_handler == NULL)
        return JS_ThrowInternalError(ctx, "Scene text layout is unavailable");
    const char* request = JS_ToCString(ctx, argv[0]);
    if (request == NULL) return JS_EXCEPTION;
    WEScriptHostEvaluation response = host->text_layout_handler(host->text_layout_opaque, request);
    JS_FreeCString(ctx, request);
    JSValue result = JS_UNDEFINED;
    if (response.error_message != NULL) result = JS_ThrowInternalError(ctx, "%s", response.error_message);
    else if (response.result_json != NULL) result = JS_ParseJSON(ctx, response.result_json, strlen(response.result_json), "<text_layout>");
    we_script_host_free_evaluation(response);
    return result;
}

static JSValue scene_layer_request(JSContext* ctx, JSValueConst this_value, int argc, JSValueConst* argv) {
    WEScriptHost* host = JS_GetContextOpaque(ctx);
    if (argc < 1 || host == NULL || host->scene_layer_handler == NULL)
        return JS_ThrowInternalError(ctx, "Scene layer creation is unavailable");
    const char* request = JS_ToCString(ctx, argv[0]);
    if (request == NULL) return JS_EXCEPTION;
    WEScriptHostEvaluation response = host->scene_layer_handler(host->scene_layer_opaque, request);
    JS_FreeCString(ctx, request);
    JSValue result = JS_UNDEFINED;
    if (response.error_message != NULL) result = JS_ThrowInternalError(ctx, "%s", response.error_message);
    else if (response.result_json != NULL) result = JS_ParseJSON(ctx, response.result_json, strlen(response.result_json), "<scene-layer>");
    we_script_host_free_evaluation(response);
    return result;
}

void we_script_host_set_scene_layer_handler(WEScriptHost* host, void* opaque, WEScriptStorageHandler handler) {
    if (host == NULL || host->context == NULL) return;
    update_stack_thread(host);
    host->scene_layer_opaque = opaque;
    host->scene_layer_handler = handler;
    JS_SetContextOpaque(host->context, host);
    JSValue global = JS_GetGlobalObject(host->context);
    JS_SetPropertyStr(host->context, global, "__weSceneLayerRequest", JS_NewCFunction(host->context, scene_layer_request, "__weSceneLayerRequest", 1));
    JS_FreeValue(host->context, global);
}

void we_script_host_set_text_layout_handler(WEScriptHost* host, void* opaque, WEScriptStorageHandler handler) {
    if (host == NULL || host->context == NULL) return;
    update_stack_thread(host);
    host->text_layout_opaque = opaque;
    host->text_layout_handler = handler;
    JS_SetContextOpaque(host->context, host);
    JSValue global = JS_GetGlobalObject(host->context);
    JS_SetPropertyStr(host->context, global, "__weTextLayoutRequest", JS_NewCFunction(host->context, text_layout_request, "__weTextLayoutRequest", 1));
    JS_FreeValue(host->context, global);
}

static JSValue attachment_request(JSContext* ctx, JSValueConst this_value, int argc, JSValueConst* argv) {
    WEScriptHost* host = JS_GetContextOpaque(ctx);
    if (argc < 1 || host == NULL || host->attachment_handler == NULL)
        return JS_ThrowInternalError(ctx, "Scene attachments are unavailable");
    const char* request = JS_ToCString(ctx, argv[0]);
    if (request == NULL) return JS_EXCEPTION;
    WEScriptHostEvaluation response = host->attachment_handler(host->attachment_opaque, request);
    JS_FreeCString(ctx, request);
    JSValue result = JS_UNDEFINED;
    if (response.error_message != NULL) result = JS_ThrowInternalError(ctx, "%s", response.error_message);
    else if (response.result_json != NULL) result = JS_ParseJSON(ctx, response.result_json, strlen(response.result_json), "<attachment>");
    we_script_host_free_evaluation(response);
    return result;
}

void we_script_host_set_attachment_handler(WEScriptHost* host, void* opaque, WEScriptStorageHandler handler) {
    if (host == NULL || host->context == NULL) return;
    update_stack_thread(host);
    host->attachment_opaque = opaque;
    host->attachment_handler = handler;
    JS_SetContextOpaque(host->context, host);
    JSValue global = JS_GetGlobalObject(host->context);
    JS_SetPropertyStr(host->context, global, "__weAttachmentRequest", JS_NewCFunction(host->context, attachment_request, "__weAttachmentRequest", 1));
    JS_FreeValue(host->context, global);
}

static JSValue animation_request(JSContext* ctx, JSValueConst this_value, int argc, JSValueConst* argv) {
    WEScriptHost* host = JS_GetContextOpaque(ctx);
    if (argc < 1 || host == NULL || host->animation_handler == NULL) return JS_UNDEFINED;
    const char* request = JS_ToCString(ctx, argv[0]);
    if (request == NULL) return JS_EXCEPTION;
    WEScriptHostEvaluation response = host->animation_handler(host->animation_opaque, request);
    JS_FreeCString(ctx, request);
    JSValue result = JS_UNDEFINED;
    if (response.error_message != NULL) result = JS_ThrowInternalError(ctx, "%s", response.error_message);
    else if (response.result_json != NULL) result = JS_ParseJSON(ctx, response.result_json, strlen(response.result_json), "<animation>");
    we_script_host_free_evaluation(response);
    return result;
}

void we_script_host_set_animation_handler(WEScriptHost* host, void* opaque, WEScriptStorageHandler handler) {
    if (host == NULL || host->context == NULL) return;
    update_stack_thread(host);
    host->animation_opaque = opaque;
    host->animation_handler = handler;
    JS_SetContextOpaque(host->context, host);
    JSValue global = JS_GetGlobalObject(host->context);
    JS_SetPropertyStr(host->context, global, "__weAnimationRequest", JS_NewCFunction(host->context, animation_request, "__weAnimationRequest", 1));
    JS_FreeValue(host->context, global);
}

int we_script_host_value_instance_has_update(WEScriptHost* host, const char* instance_id) {
    if (host == NULL || host->context == NULL) return -1;
    update_stack_thread(host);
    JSContext* ctx = host->context;
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue instances = JS_GetPropertyStr(ctx, global, "__weValueInstances");
    JSValue instance = JS_IsObject(instances)
        ? JS_GetPropertyStr(ctx, instances, instance_id != NULL ? instance_id : "default") : JS_UNDEFINED;
    JSValue module = JS_IsObject(instance) ? JS_GetPropertyStr(ctx, instance, "module") : JS_UNDEFINED;
    JSValue update = JS_IsObject(module) ? JS_GetPropertyStr(ctx, module, "update") : JS_UNDEFINED;
    int result = JS_IsObject(module) ? JS_IsFunction(ctx, update) : -1;
    JS_FreeValue(ctx, update);
    JS_FreeValue(ctx, module);
    JS_FreeValue(ctx, instance);
    JS_FreeValue(ctx, instances);
    JS_FreeValue(ctx, global);
    return result;
}

static JSValue storage_request(JSContext* ctx, JSValueConst this_value, int argc, JSValueConst* argv) {
    WEScriptHost* host = JS_GetContextOpaque(ctx);
    if (host == NULL || host->storage_handler == NULL) return JS_ThrowInternalError(ctx, "SceneScript storage is unavailable");
    if (argc < 1) return JS_ThrowTypeError(ctx, "Missing storage request");
    const char* request = JS_ToCString(ctx, argv[0]);
    if (request == NULL) return JS_EXCEPTION;
    WEScriptHostEvaluation response = host->storage_handler(host->storage_opaque, request);
    JS_FreeCString(ctx, request);
    JSValue result = JS_UNDEFINED;
    if (response.error_message != NULL) result = JS_ThrowInternalError(ctx, "%s", response.error_message);
    else if (response.result_json != NULL) result = JS_ParseJSON(ctx, response.result_json, strlen(response.result_json), "<local-storage>");
    we_script_host_free_evaluation(response);
    return result;
}

void we_script_host_set_storage_handler(WEScriptHost* host, void* opaque, WEScriptStorageHandler handler) {
    if (host == NULL || host->context == NULL) return;
    update_stack_thread(host);
    host->storage_opaque = opaque;
    host->storage_handler = handler;
    JS_SetContextOpaque(host->context, host);
    JSValue global = JS_GetGlobalObject(host->context);
    JS_SetPropertyStr(host->context, global, "__weLocalStorageRequest", JS_NewCFunction(host->context, storage_request, "__weLocalStorageRequest", 1));
    JS_FreeValue(host->context, global);
}

static char* duplicate_c_string(const char* source) {
    if (source == NULL) {
        return NULL;
    }

    const size_t length = strlen(source);
    char* copy = malloc(length + 1);
    if (copy == NULL) {
        return NULL;
    }

    memcpy(copy, source, length + 1);
    return copy;
}

static JSValue console_message(JSContext* ctx, JSValueConst this_value, int argc, JSValueConst* argv, int level) {
    (void) this_value;
    fprintf(stderr, "[SceneScript %s]", level == 0 ? "info" : "error");
    for (int index = 0; index < argc; ++index) {
        const char* value = JS_ToCString(ctx, argv[index]);
        if (value == NULL) { fputc('\n', stderr); return JS_EXCEPTION; }
        fputc(' ', stderr);
        fputs(value, stderr);
        JS_FreeCString(ctx, value);
    }
    fputc('\n', stderr);
    return JS_UNDEFINED;
}

WEScriptHost* we_script_host_create(void) {
    WEScriptHost* host = calloc(1, sizeof(WEScriptHost));
    if (host == NULL) return NULL;
    host->value_dispatcher = JS_UNDEFINED;
    host->user_properties = JS_UNDEFINED;
    host->engine_snapshot = JS_UNDEFINED;
    host->runtime = JS_NewRuntime();
    if (host->runtime != NULL) configure_stack_thread(host);
    if (host->runtime != NULL) host->context = JS_NewContext(host->runtime);
    if (host->context == NULL) {
        we_script_host_destroy(host);
        return NULL;
    }
    JSValue global = JS_GetGlobalObject(host->context);
    JSValue console = JS_NewObject(host->context);
    JS_SetPropertyStr(host->context, console, "log", JS_NewCFunctionMagic(host->context, console_message, "log", 0, JS_CFUNC_generic_magic, 0));
    JS_SetPropertyStr(host->context, console, "error", JS_NewCFunctionMagic(host->context, console_message, "error", 0, JS_CFUNC_generic_magic, 1));
    JS_SetPropertyStr(host->context, global, "console", console);
    JS_FreeValue(host->context, global);
    return host;
}

void we_script_host_destroy(WEScriptHost* host) {
    if (host == NULL) return;
    if (host->context != NULL) {
        we_script_host_shutdown(host);
        JS_FreeValue(host->context, host->value_dispatcher);
        JS_FreeValue(host->context, host->user_properties);
        JS_FreeValue(host->context, host->engine_snapshot);
        JS_FreeContext(host->context);
    }
    if (host->runtime != NULL) JS_FreeRuntime(host->runtime);
    free(host);
}

void we_script_host_shutdown(WEScriptHost* host) {
    if (host == NULL || host->context == NULL) return;
    update_stack_thread(host);
    static const char* source =
        "(function() {"
        " var instances = globalThis.__weValueInstances || {};"
        " globalThis.__weValueInstances = Object.create(null);"
        " var errors = [];"
        " var previousEngine = globalThis.__engine;"
        " Object.keys(instances).forEach(function(key) {"
        "   var state = instances[key];"
        "   globalThis.__engine = state.module.engine;"
        "   try { if (state.initialized && state.module.destroy) state.module.destroy(); }"
        "   catch (error) { errors.push(String(error)); }"
        " });"
        " globalThis.__engine = previousEngine;"
        " if (globalThis.__weClearAnimationCallbacks) globalThis.__weClearAnimationCallbacks();"
        " if (errors.length) throw new Error(errors.join('; '));"
        "})();";
    JSValue result = JS_Eval(host->context, source, strlen(source), "<script-destroy>", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(result)) {
        JSValue exception = JS_GetException(host->context);
        const char* message = JS_ToCString(host->context, exception);
        fprintf(stderr, "[NativeSceneRuntime] Script destroy failed: %s\n", message != NULL ? message : "unknown exception");
        if (message != NULL) JS_FreeCString(host->context, message);
        JS_FreeValue(host->context, exception);
    }
    JS_FreeValue(host->context, result);
}

static char* sanitize_script_body(const char* source) {
    return we_rewrite_script_source(source);
}

/// Shared JS prelude for both script hosts: the built-in WEMath/WEColor
/// modules, the cross-script `shared` object, and stub implementations of
/// the Wallpaper Engine scene API (engine/input/thisScene/thisLayer) so
/// workshop scripts evaluate instead of throwing ReferenceErrors. Stubs
/// only fill fields the host did not supply.
static const char* WE_PRELUDE =
    "  if (!globalThis.shared) globalThis.shared = {};\n"
    "  var shared = globalThis.shared;\n"
    "  function __weImportModule(name) {\n"
    "    if (name === 'WEMath' || name === 'WEColor') return globalThis[name];\n"
    "    throw new Error('Unsupported SceneScript module: ' + name);\n"
    "  }\n"
    "  var localStorage = globalThis.localStorage || (globalThis.localStorage = {\n"
    "    LOCATION_SCREEN: 'screen', LOCATION_GLOBAL: 'global',\n"
    "    get: function(key, location) { return globalThis.__weLocalStorageRequest(JSON.stringify({operation:'get', key:String(key), location:location})); },\n"
    "    set: function(key, value, location) { globalThis.__weLocalStorageRequest(JSON.stringify({operation:'set', key:String(key), value:value, location:location})); },\n"
    "    delete: function(key, location) { return globalThis.__weLocalStorageRequest(JSON.stringify({operation:'delete', key:String(key), location:location})); },\n"
    "    clear: function(location) { globalThis.__weLocalStorageRequest(JSON.stringify({operation:'clear', location:location})); }\n"
    "  });\n"
    "  var Vec3 = globalThis.Vec3;\n"
    "  var Vec2 = globalThis.Vec2;\n"
    "  var Vec4 = globalThis.Vec4;\n"
    "  function __weVec3(x, y, z) { return new Vec3(x, y, z); }\n"
    "  var WEMath = globalThis.WEMath || (globalThis.WEMath = {\n"
    "    clamp: function(x, a, b) { return Math.min(Math.max(x, a), b); },\n"
    "    saturate: function(x) { return Math.min(Math.max(x, 0), 1); },\n"
    "    frac: function(x) { return x - Math.floor(x); },\n"
    "    mix: function(a, b, t) { return a + (b - a) * t; },\n"
    "    lerp: function(a, b, t) { return a + (b - a) * t; },\n"
    "    smoothStep: function(a, b, x) {\n"
    "      var t = Math.min(Math.max((x - a) / (b - a), 0), 1);\n"
    "      return t * t * (3 - 2 * t);\n"
    "    },\n"
    "    smoothstep: function(a, b, x) { return WEMath.smoothStep(a, b, x); },\n"
    "    step: function(edge, x) { return x < edge ? 0 : 1; },\n"
    "    deg: function(r) { return r * 180 / Math.PI; },\n"
    "    rad: function(d) { return d * Math.PI / 180; },\n"
    "    degToRad: function(d) { return d * Math.PI / 180; },\n"
    "    radToDeg: function(r) { return r * 180 / Math.PI; },\n"
    "    rand: function(a, b) {\n"
    "      if (a === undefined) { a = 0; b = 1; }\n"
    "      else if (b === undefined) { b = a; a = 0; }\n"
    "      return a + Math.random() * (b - a);\n"
    "    },\n"
    "    randomInt: function(a, b) { return Math.floor(WEMath.rand(a, b + 1)); }\n"
    "  });\n"
    "  function __weColorComponents(value) { return {x:Number(value.x), y:Number(value.y), z:Number(value.z)}; }\n"
    "  function __weHsvToRgb(h, s, v) {\n"
    "    var i = Math.floor(h * 6), f = h * 6 - i;\n"
    "    var p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s);\n"
    "    var r, g, b;\n"
    "    switch (i % 6) {\n"
    "      case 0: r = v; g = t; b = p; break;\n"
    "      case 1: r = q; g = v; b = p; break;\n"
    "      case 2: r = p; g = v; b = t; break;\n"
    "      case 3: r = p; g = q; b = v; break;\n"
    "      case 4: r = t; g = p; b = v; break;\n"
    "      default: r = v; g = p; b = q; break;\n"
    "    }\n"
    "    return {x:r, y:g, z:b};\n"
    "  }\n"
    "  function __weRgbToHsv(r, g, b) {\n"
    "    var mx = Math.max(r, g, b), mn = Math.min(r, g, b), d = mx - mn;\n"
    "    var h = 0;\n"
    "    if (d > 0) {\n"
    "      if (mx === r) h = ((g - b) / d) % 6;\n"
    "      else if (mx === g) h = (b - r) / d + 2;\n"
    "      else h = (r - g) / d + 4;\n"
    "      h /= 6;\n"
    "      if (h < 0) h += 1;\n"
    "    }\n"
    "    return {x:h, y:mx === 0 ? 0 : d / mx, z:mx};\n"
    "  }\n"
    "  var WEColor = globalThis.WEColor || (globalThis.WEColor = {\n"
    "    hsvToRgb: function(h, s, v) {\n"
    "      return __weHsvToRgb(h, s, v);\n"
    "    },\n"
    "    rgbToHsv: function(r, g, b) {\n"
    "      return __weRgbToHsv(r, g, b);\n"
    "    },\n"
    "    rgb2hsv: function(rgb) { var c = __weColorComponents(rgb), out = __weRgbToHsv(c.x, c.y, c.z); return __weVec3(out.x, out.y, out.z); },\n"
    "    hsv2rgb: function(hsv) { var c = __weColorComponents(hsv); c.x = ((c.x % 1) + 1) % 1; var out = __weHsvToRgb(c.x, c.y, c.z); return __weVec3(out.x, out.y, out.z); },\n"
    "    normalizeColor: function(rgb) { var c = __weColorComponents(rgb); return __weVec3(c.x / 255, c.y / 255, c.z / 255); },\n"
    "    expandColor: function(rgb) { var c = __weColorComponents(rgb); return __weVec3(c.x * 255, c.y * 255, c.z * 255); }\n"
    "  });\n"
    "  function __weStubAnimation() {\n"
    "    return {\n"
    "      frame: 0, frames: 1, rate: 1, duration: 0, playbackMode: 'loop',\n"
    "      play: function() {}, pause: function() {}, stop: function() {},\n"
    "      gotoAndPlay: function() {}, gotoAndStop: function() {}\n"
    "    };\n"
    "  }\n"
    "  function __weStubLayer(name) {\n"
    "    return {\n"
    "      name: name || '', alpha: 1, visible: true, text: '',\n"
    "      alignment: 'center',\n"
    "      origin: new Vec3(0, 0, 0), angles: new Vec3(0, 0, 0),\n"
    "      scale: new Vec3(1, 1, 1), size: new Vec2(0, 0),\n"
    "      color: new Vec3(1, 1, 1),\n"
    "      getTextureAnimation: function() { return __weStubAnimation(); },\n"
    "      getAnimation: function() { return __weStubAnimation(); },\n"
    "      getVideoTexture: function() {\n"
    "        return {\n"
    "          duration: 0, time: 0, rate: 1,\n"
    "          play: function() {}, pause: function() {}, stop: function() {}\n"
    "        };\n"
    "      },\n"
    "      getParticleSystem: function() {\n"
    "        return { start: function() {}, stop: function() {}, setControlPoint: function() {} };\n"
    "      }\n"
    "    };\n"
    "  }\n"
    "  var engine = globalThis.engine;\n"
    "  if (!engine || typeof engine !== 'object') { engine = globalThis.engine = {}; }\n"
    "  if (engine.frametime === undefined) engine.frametime = 1 / 60;\n"
    "  if (engine.runtime === undefined) engine.runtime = 0;\n"
    "  if (engine.timeOfDay === undefined) engine.timeOfDay = 0.5;\n"
    "  engine.registerAsset = globalThis.__weRegisterAsset;\n"
    "  engine.isDesktopDevice = function() { return true; };\n"
    "  engine.isMobileDevice = function() { return false; };\n"
    "  engine.isWallpaper = function() { return true; };\n"
    "  engine.isScreensaver = function() { return false; };\n"
    "  engine.isRunningInEditor = function() { return false; };\n"
    "  engine.isPortrait = function() { return engine.screenResolution.y > engine.screenResolution.x; };\n"
    "  engine.isLandscape = function() { return !engine.isPortrait(); };\n"
    "  if (engine.canvasSize === undefined) engine.canvasSize = { x: 1920, y: 1080 };\n"
    "  if (engine.screenSize === undefined) engine.screenSize = engine.canvasSize;\n"
    "  if (engine.screenResolution === undefined) engine.screenResolution = engine.canvasSize;\n"
    "  if (engine.userProperties === undefined) engine.userProperties = {};\n"
    "  engine.canvasSize = new Vec2(engine.canvasSize);\n"
    "  engine.screenSize = new Vec2(engine.screenSize);\n"
    "  engine.screenResolution = new Vec2(engine.screenResolution);\n"
    "  if (engine.AUDIO_RESOLUTION_16 === undefined) {\n"
    "    engine.AUDIO_RESOLUTION_16 = 16;\n"
    "    engine.AUDIO_RESOLUTION_32 = 32;\n"
    "    engine.AUDIO_RESOLUTION_64 = 64;\n"
    "  }\n"
    "  var __audioBuffers = [];\n"
    "  function __weRefreshAudio(buffer) {\n"
    "    function bucket(src, i, count) {\n"
    "      if (!src || !src.length) return 0;\n"
    "      var start = Math.floor(i * src.length / count);\n"
    "      var end = Math.min(src.length, Math.max(start + 1, Math.floor((i + 1) * src.length / count)));\n"
    "      var sum = 0; for (var k = start; k < end; k++) sum += src[k];\n"
    "      return sum / (end - start);\n"
    "    }\n"
    "    buffer.peak = 0;\n"
    "    for (var i = 0; i < buffer.resolution; i++) {\n"
    "      buffer.left[i] = bucket(engine.audioLeft, i, buffer.resolution);\n"
    "      buffer.right[i] = bucket(engine.audioRight, i, buffer.resolution);\n"
    "      buffer.average[i] = (buffer.left[i] + buffer.right[i]) / 2;\n"
    "      buffer.peak = Math.max(buffer.peak, buffer.average[i]);\n"
    "    }\n"
    "  }\n"
    "  engine.registerAudioBuffers = function(resolution) {\n"
    "    var n = [16, 32, 64].indexOf(resolution) >= 0 ? resolution : 16;\n"
    "    var buffer = {resolution: n, left: [], right: [], average: [], peak: 0};\n"
    "    __audioBuffers.push(buffer); __weRefreshAudio(buffer); return buffer;\n"
    "  };\n"
    "  engine.__refreshAudio = function() { __audioBuffers.forEach(__weRefreshAudio); };\n"
    "  var __timers = [];\n"
    "  function __weTimer(callback, delay, repeat) {\n"
    "    if (typeof callback !== 'function') throw new TypeError('Timer callback must be a function');\n"
    "    var timer = {callback:callback, delay:Math.max(0, Number(delay) || 0), repeat:repeat, cancelled:false};\n"
    "    timer.due = engine.runtime * 1000 + timer.delay;\n"
    "    __timers.push(timer);\n"
    "    return function() { timer.cancelled = true; };\n"
    "  }\n"
    "  engine.setTimeout = function(callback, delay) { return __weTimer(callback, delay, false); };\n"
    "  engine.setInterval = function(callback, delay) { return __weTimer(callback, delay, true); };\n"
    "  engine.clearTimeout = engine.clearInterval = function(cancel) { if (typeof cancel === 'function') cancel(); };\n"
    "  engine.__advanceTimers = function() {\n"
    "    var now = engine.runtime * 1000;\n"
    "    var pending = __timers.slice();\n"
    "    for (var i = 0; i < pending.length; i++) {\n"
    "      var timer = pending[i];\n"
    "      if (timer.cancelled || timer.due > now) continue;\n"
    "      if (!timer.repeat) timer.cancelled = true;\n"
    "      else timer.due = now + timer.delay;\n"
    "      timer.callback();\n"
    "    }\n"
    "    __timers = __timers.filter(function(timer) { return !timer.cancelled; });\n"
    "  };\n"
    "  if (!engine.registerKeyListeners) engine.registerKeyListeners = function() {};\n"
    "  var input = globalThis.input;\n"
    "  if (!input || typeof input !== 'object') { input = globalThis.input = {}; }\n"
    "  if (!input.cursorPosition) input.cursorPosition = { x: 0, y: 0 };\n"
    "  if (!input.cursorWorldPosition) input.cursorWorldPosition = new Vec3(0);\n"
    "  if (!input.cursorScreenPosition) input.cursorScreenPosition = new Vec2(0);\n"
    "  if (input.cursorLeftDown === undefined) input.cursorLeftDown = false;\n"
    "  var thisScene = globalThis.thisScene;\n"
    "  if (!thisScene || typeof thisScene !== 'object') { thisScene = globalThis.thisScene = {}; }\n"
    "  if (!thisScene.getLayer) thisScene.getLayer = function(name) { return __weStubLayer(name); };\n"
    "  if (!thisScene.enumerateLayers) thisScene.enumerateLayers = function() { return []; };\n"
    "  if (!thisScene.createLayer) thisScene.createLayer = function(name) { return __weStubLayer(name); };\n"
    "  if (!thisScene.sortLayer) thisScene.sortLayer = function() {};\n"
    "  if (!thisScene.getLayerIndex) thisScene.getLayerIndex = function() { return 0; };\n"
    "  if (!thisScene.getInitialLayerConfig) thisScene.getInitialLayerConfig = function(name) { return __weStubLayer(name); };\n"
    "  if (!globalThis.thisLayer) globalThis.thisLayer = __weStubLayer('');\n"
    "  if (!globalThis.thisObject) globalThis.thisObject = __weStubLayer('');\n"
    "  (function() {\n"
    "    // Upgrade plain vector fields after their JSON round-trip.\n"
    "    // so scripts can call .copy()/.add()/... on them.\n"
    "    for (var key in thisObject) {\n"
    "      var v = thisObject[key];\n"
    "      if (v && typeof v === 'object' && typeof v.x === 'number' && typeof v.y === 'number' && !(v instanceof Vec4) && !(v instanceof Vec3) && !(v instanceof Vec2)) {\n"
    "        thisObject[key] = (typeof v.w === 'number') ? new Vec4(v) : ((typeof v.z === 'number') ? new Vec3(v) : new Vec2(v));\n"
    "      }\n"
    "    }\n"
    "  })();\n"
    "  if (!globalThis.console) globalThis.console = { log: function() {} };\n";

// Keep authored lexical declarations out of the host prelude and bookkeeping
// scopes. Common wallpaper locals such as `state` and `copy` are not reserved.
static const char* WE_AUTHORED_SCOPE =
    "\nvar __we_exports = (function() {\n";
static const char* WE_ASSET_NAMESPACE =
    "globalThis.__engine.__assetNamespace = function() {\n"
    "  try { return typeof __workshopId === 'string' ? __workshopId : undefined; } catch (_) { return undefined; }\n"
    "};\n";

static char* build_eval_script(const char* script_source) {
    static const char* prefix =
        "(function() {\n"
        "  var instances = globalThis.__weValueInstances || (globalThis.__weValueInstances = Object.create(null));\n"
        "  var key = globalThis.__instanceID;\n"
        "  var state = instances[key];\n"
        "  var propertyRevision = globalThis.__engine.__userPropertiesRevision;\n"
        "  var checkProperties = (!state || state.module.applyUserProperties) &&\n"
        "    (propertyRevision === undefined || !state || propertyRevision !== state.userPropertiesRevision);\n"
        // Capture before authored top-level/init code can mutate its engine object.
        "  var hostPropertiesJSON = checkProperties ? JSON.stringify(globalThis.__engine.userProperties || {}) : undefined;\n"
        "  function copy(value) {\n"
        "    if (value && typeof value === 'object') {\n"
        "      if (typeof value.x === 'number' && typeof value.y === 'number') {\n"
        "        if (value.w !== undefined) return new globalThis.Vec4(value);\n"
        "        return value.z !== undefined ? new globalThis.Vec3(value) : new globalThis.Vec2(value);\n"
        "      }\n"
        "      if (Array.isArray(value)) return value.map(copy);\n"
        "      var result = {}; Object.keys(value).forEach(function(k) { result[k] = copy(value[k]); }); return result;\n"
        "    }\n"
        "    return value;\n"
        "  }\n"
        "  function coerce(value) {\n"
        "    var hint = globalThis.__currentValue;\n"
        "    var asset = globalThis.__weAssetPath(value);\n"
        "    if (typeof hint === 'string' && asset !== undefined) return asset;\n"
        "    if (typeof value === 'number' && hint && typeof hint === 'object' && 'x' in hint && 'y' in hint) {\n"
        "      if ('w' in hint) return new globalThis.Vec4(value);\n"
        "      return 'z' in hint ? new globalThis.Vec3(value) : new globalThis.Vec2(value);\n"
        "    }\n"
        "    return copy(value);\n"
        "  }\n"
        "  if (!state) {\n"
        "    state = { properties: globalThis.__scriptProps };\n"
        "    state.module = (function() {\n"
        "      globalThis.engine = globalThis.__engine;\n"
        "      globalThis.input = globalThis.__input;\n"
        "      var __props = state.properties;\n"
        "  function createScriptProperties() {\n"
        "    var builder = {\n"
        "      addSlider: function(opts) {\n"
        "        if (!(opts.name in __props)) __props[opts.name] = opts.value;\n"
        "        return builder;\n"
        "      },\n"
        "      addCheckbox: function(opts) {\n"
        "        if (!(opts.name in __props)) __props[opts.name] = opts.value;\n"
        "        return builder;\n"
        "      },\n"
        "      addCombo: function(opts) {\n"
        "        if (!(opts.name in __props)) __props[opts.name] = opts.value === undefined ? opts.options?.[0]?.value : opts.value;\n"
        "        return builder;\n"
        "      },\n"
        "      addColor: function(opts) {\n"
        "        if (!(opts.name in __props)) __props[opts.name] = opts.value;\n"
        "        return builder;\n"
        "      },\n"
        "      addText: function(opts) {\n"
        "        if (!(opts.name in __props)) __props[opts.name] = opts.value;\n"
        "        return builder;\n"
        "      },\n"
        "      finish: function() { Object.keys(__props).forEach(function(k) { __props[k] = copy(__props[k]); }); return __props; }\n"
        "    };\n"
        "    return builder;\n"
        "  }\n"
        ;
    static const char* suffix =
        "\n"
        "      return {\n"
        "        cursorEnter: typeof cursorEnter === 'function' ? cursorEnter : null,\n"
        "        cursorLeave: typeof cursorLeave === 'function' ? cursorLeave : null,\n"
        "        cursorMove: typeof cursorMove === 'function' ? cursorMove : null,\n"
        "        cursorDown: typeof cursorDown === 'function' ? cursorDown : null,\n"
        "        cursorUp: typeof cursorUp === 'function' ? cursorUp : null,\n"
        "        cursorClick: typeof cursorClick === 'function' ? cursorClick : null,\n"
        "        mediaStatusChanged: typeof mediaStatusChanged === 'function' ? mediaStatusChanged : null,\n"
        "        mediaPlaybackChanged: typeof mediaPlaybackChanged === 'function' ? mediaPlaybackChanged : null,\n"
        "        mediaPropertiesChanged: typeof mediaPropertiesChanged === 'function' ? mediaPropertiesChanged : null,\n"
        "        mediaThumbnailChanged: typeof mediaThumbnailChanged === 'function' ? mediaThumbnailChanged : null,\n"
        "        mediaTimelineChanged: typeof mediaTimelineChanged === 'function' ? mediaTimelineChanged : null,\n"
        "        init: typeof init === 'function' ? init : null,\n"
        "        update: typeof update === 'function' ? update : null,\n"
        "        destroy: typeof destroy === 'function' ? destroy : null,\n"
        "        applyUserProperties: typeof applyUserProperties === 'function' ? applyUserProperties : null\n"
        "      };\n"
        "      })();\n"
        "      return {engine: engine, input: input, mediaCallbacks: __we_exports, init: __we_exports.init,\n"
        "        cursorCallbacks: ['cursorEnter','cursorLeave','cursorMove','cursorDown','cursorUp','cursorClick'].some(function(k) { return __we_exports[k]; }) ? __we_exports : null,\n"
        "        update: __we_exports.update, destroy: __we_exports.destroy,\n"
        "        applyUserProperties: __we_exports.applyUserProperties};\n"
        "    })();\n"
        "    state.value = copy(globalThis.__currentValue);\n"
        "    state.base = JSON.stringify(globalThis.__currentValue);\n"
        "    instances[key] = state;\n"
        "  }\n"
        "  var module = state.module;\n"
        // After module creation, incoming JSON/snapshot objects are fresh and
        // unexposed. Transfer properties directly, converting only object values
        // to SceneScript vectors. Preserve the first module's top-level references.
        "  Object.keys(globalThis.__engine).forEach(function(k) {\n"
        "    var value = globalThis.__engine[k];\n"
        "    if (k === 'userProperties' && propertyRevision !== undefined && module.engine !== globalThis.__engine) {\n"
        "      if (state.propertyShapeRevision !== propertyRevision) {\n"
        "        state.propertyObjectKeys = Object.keys(value).filter(function(name) { return value[name] !== null && typeof value[name] === 'object'; });\n"
        "        state.propertyShapeRevision = propertyRevision;\n"
        "      }\n"
        "      state.propertyObjectKeys.forEach(function(name) { value[name] = copy(value[name]); });\n"
        "      module.engine[k] = value;\n"
        "    } else module.engine[k] = copy(value);\n"
        "  });\n"
        "  module.engine.frameIndex = globalThis.__engine.frameIndex;\n"
        "  module.engine.isPaused = !!globalThis.__engine.isPaused;\n"
        "  Object.keys(globalThis.__input).forEach(function(k) { module.input[k] = copy(globalThis.__input[k]); });\n"
        "  Object.keys(globalThis.__scriptProps).forEach(function(k) { state.properties[k] = copy(globalThis.__scriptProps[k]); });\n"
        "  var base = JSON.stringify(globalThis.__currentValue);\n"
        "  if (base !== state.base) { state.base = base; state.value = copy(globalThis.__currentValue); }\n"
        "  if (globalThis.__engine.__loadOnly) return state.value;\n"
        "  var frame = module.engine.frameIndex;\n"
        "  if (!globalThis.__engine.__initializeOnly && !module.engine.isPaused && (frame === undefined || frame !== state.lastFrame)) {\n"
        "    module.engine.__refreshAudio();\n"
        "    module.engine.__advanceTimers();\n"
        "  }\n"
        "  if (!state.initialized) {\n"
        "    if (module.init) {\n"
        "      var initialized = module.init(copy(state.value));\n"
        "      if (initialized !== undefined) state.value = coerce(initialized);\n"
        "    }\n"
        "    state.initialized = true;\n"
        "  }\n"
        "  if (globalThis.__engine.__initializeOnly) return state.value;\n"
        "  if (module.applyUserProperties && checkProperties) {\n"
        "    var properties = module.engine.userProperties || {};\n"
        "    var changed = {};\n"
        "    Object.keys(properties).forEach(function(k) {\n"
        "      if (!state.userProperties || JSON.stringify(properties[k]) !== JSON.stringify(state.userProperties[k])) changed[k] = copy(properties[k]);\n"
        "    });\n"
        "    if (!state.userProperties || Object.keys(changed).length) module.applyUserProperties(changed);\n"
        "    state.userProperties = copy(properties);\n"
        // A callback may alter engine.userProperties. Preserve the next-call
        // restoration event instead of treating that snapshot as host input.
        "    state.userPropertiesRevision = JSON.stringify(state.userProperties) === JSON.stringify(copy(JSON.parse(hostPropertiesJSON)))\n"
        "      ? propertyRevision : undefined;\n"
        "  }\n"
        "  globalThis.__weDispatchMedia(state, module.mediaCallbacks, globalThis.__engine.__media);\n"
        "  if (module.cursorCallbacks && globalThis.__weDispatchCursor) globalThis.__weDispatchCursor(state, module);\n"
        "  var frame = module.engine.frameIndex;\n"
        "  if (!module.engine.isPaused && (frame === undefined || frame !== state.lastFrame)) {\n"
        "    if (globalThis.__weDispatchAnimationCallbacks) globalThis.__weDispatchAnimationCallbacks(key, frame);\n"
        "    if (module.update) {\n"
        "      var updated = module.update(copy(state.value));\n"
        "      if (updated !== undefined) state.value = coerce(updated);\n"
        "    }\n"
        "    state.lastFrame = frame;\n"
        "  }\n"
        "  return state.value;\n"
        "})();\n"
        ;

    char* body = sanitize_script_body(script_source);
    if (body == NULL) return NULL;
    const char* strict = we_script_source_is_strict(body) ? "'use strict';\n" : "";
    const size_t length = strlen(prefix) + strlen(WE_VECTOR_PRELUDE) + strlen(WE_MATRIX_PRELUDE) + strlen(WE_ASSET_PRELUDE) + strlen(WE_MEDIA_PRELUDE) + strlen(WE_PRELUDE) + strlen(WE_AUTHORED_SCOPE) + strlen(strict) + strlen(WE_ASSET_NAMESPACE) + strlen(body) + strlen(suffix);
    char* script = malloc(length + 1);
    if (script != NULL) {
        script[0] = '\0';
        strcat(script, prefix);
        strcat(script, WE_VECTOR_PRELUDE);
        strcat(script, WE_MATRIX_PRELUDE);
        strcat(script, WE_ASSET_PRELUDE);
        strcat(script, WE_MEDIA_PRELUDE);
        strcat(script, WE_PRELUDE);
        strcat(script, WE_AUTHORED_SCOPE);
        strcat(script, strict);
        strcat(script, WE_ASSET_NAMESPACE);
        strcat(script, body);
        strcat(script, suffix);
    }
    free(body);
    return script;
}

static char* build_scene_callback_script(const char* script_source, const char* callback_name) {
    (void) callback_name;
    static const char* prefix =
        "(function() {\n"
        "  var instances = globalThis.__weCallbackInstances || (globalThis.__weCallbackInstances = Object.create(null));\n"
        "  var key = globalThis.__instanceID;\n"
        "  var module = instances[key];\n"
        "  if (!module) {\n"
        "    module = (function() {\n"
        "      globalThis.thisObject = globalThis.__thisObject;\n"
        "      if (!globalThis.__weSceneBridge) globalThis.thisScene = globalThis.__thisScene;\n"
        "      globalThis.engine = globalThis.__engine;\n"
        "      globalThis.input = globalThis.__input;\n"
        ;
    static const char* suffix =
        "\n"
        "      return {\n"
        "        mediaStatusChanged: typeof mediaStatusChanged === 'function' ? mediaStatusChanged : null,\n"
        "        mediaPlaybackChanged: typeof mediaPlaybackChanged === 'function' ? mediaPlaybackChanged : null,\n"
        "        mediaPropertiesChanged: typeof mediaPropertiesChanged === 'function' ? mediaPropertiesChanged : null,\n"
        "        mediaThumbnailChanged: typeof mediaThumbnailChanged === 'function' ? mediaThumbnailChanged : null,\n"
        "        mediaTimelineChanged: typeof mediaTimelineChanged === 'function' ? mediaTimelineChanged : null,\n"
        "        init: typeof init === 'function' ? init : null,\n"
        "        applyUserProperties: typeof applyUserProperties === 'function' ? applyUserProperties : null,\n"
        "        destroy: typeof destroy === 'function' ? destroy : null\n"
        "      };\n"
        "      })();\n"
        "      return {thisObject: thisObject, engine: engine, input: input, callbacks: __we_exports};\n"
        "    })();\n"
        "    instances[key] = module;\n"
        "  }\n"
        "  function copy(value) {\n"
        "    if (value && typeof value === 'object' && 'x' in value && 'y' in value) {\n"
        "      return 'w' in value ? new globalThis.Vec4(value) : ('z' in value ? new globalThis.Vec3(value) : new globalThis.Vec2(value));\n"
        "    }\n"
        "    return value;\n"
        "  }\n"
        "  if (!globalThis.__weSceneBridge) Object.keys(globalThis.__thisObject).forEach(function(k) { module.thisObject[k] = copy(globalThis.__thisObject[k]); });\n"
        "  globalThis.thisObject = module.thisObject;\n"
        "  Object.keys(globalThis.__engine).forEach(function(k) { module.engine[k] = copy(globalThis.__engine[k]); });\n"
        "  Object.keys(globalThis.__input).forEach(function(k) { module.input[k] = copy(globalThis.__input[k]); });\n"
        "  var callback = module.callbacks[globalThis.__callbackName];\n"
        "  if (callback) callback(globalThis.__callbackName === 'applyUserProperties' ? globalThis.__changedUserProperties : undefined);\n"
        "  if (globalThis.__callbackName !== 'destroy') globalThis.__weDispatchMedia(module, module.callbacks, globalThis.__engine.__media);\n"
        "  if (globalThis.__callbackName === 'destroy') delete instances[key];\n"
        "  return module.thisObject;\n"
        "})();\n"
        ;

    char* body = sanitize_script_body(script_source);
    if (body == NULL) return NULL;
    const char* strict = we_script_source_is_strict(body) ? "'use strict';\n" : "";
    const size_t length = strlen(prefix) + strlen(WE_VECTOR_PRELUDE) + strlen(WE_MATRIX_PRELUDE) + strlen(WE_ASSET_PRELUDE) + strlen(WE_MEDIA_PRELUDE) + strlen(WE_PRELUDE) + strlen(WE_AUTHORED_SCOPE) + strlen(strict) + strlen(WE_ASSET_NAMESPACE) + strlen(body) + strlen(suffix);
    char* script = malloc(length + 1);
    if (script != NULL) {
        script[0] = '\0';
        strcat(script, prefix);
        strcat(script, WE_VECTOR_PRELUDE);
        strcat(script, WE_MATRIX_PRELUDE);
        strcat(script, WE_ASSET_PRELUDE);
        strcat(script, WE_MEDIA_PRELUDE);
        strcat(script, WE_PRELUDE);
        strcat(script, WE_AUTHORED_SCOPE);
        strcat(script, strict);
        strcat(script, WE_ASSET_NAMESPACE);
        strcat(script, body);
        strcat(script, suffix);
    }
    free(body);
    return script;
}

static char* exception_to_string(JSContext* ctx) {
    JSValue exception = JS_GetException(ctx);
    const char* c_string = JS_ToCString(ctx, exception);
    char* result = duplicate_c_string(c_string != NULL ? c_string : "Unknown QuickJS exception");
    if (c_string != NULL) {
        JS_FreeCString(ctx, c_string);
    }
    if (JS_IsError(exception)) {
        JSValue stack = JS_GetPropertyStr(ctx, exception, "stack");
        if (JS_IsException(stack)) {
            // A user-defined stack getter must not replace the original error
            // or leave an exception pending for the next script evaluation.
            JS_FreeValue(ctx, JS_GetException(ctx));
        } else if (JS_IsString(stack) && result != NULL) {
            const char* trace = JS_ToCString(ctx, stack);
            if (trace != NULL && trace[0] != '\0') {
                const size_t message_length = strlen(result);
                const size_t trace_length = strnlen(trace, 16384);
                char* combined = malloc(message_length + trace_length + 2);
                if (combined != NULL) {
                    memcpy(combined, result, message_length);
                    combined[message_length] = '\n';
                    memcpy(combined + message_length + 1, trace, trace_length);
                    combined[message_length + trace_length + 1] = '\0';
                    free(result);
                    result = combined;
                }
            }
            if (trace != NULL) JS_FreeCString(ctx, trace);
        }
        JS_FreeValue(ctx, stack);
    }
    JS_FreeValue(ctx, exception);
    return result;
}

static JSValue parse_json(JSContext* ctx, const char* json, const char* filename) {
    const char* safe_json = json != NULL ? json : "null";
    return JS_ParseJSON(ctx, safe_json, strlen(safe_json), filename);
}

WEScriptHostEvaluation we_script_host_set_user_properties_json(WEScriptHost* host, const char* json) {
    WEScriptHostEvaluation evaluation = {0};
    if (host == NULL || host->context == NULL) {
        evaluation.error_message = duplicate_c_string("Failed to create QuickJS runtime/context");
        return evaluation;
    }
    update_stack_thread(host);
    JSValue value = parse_json(host->context, json, "<userProperties>");
    if (JS_IsException(value)) {
        evaluation.error_message = exception_to_string(host->context);
        return evaluation;
    }
    JS_FreeValue(host->context, host->user_properties);
    host->user_properties = value;
    return evaluation;
}

WEScriptHostEvaluation we_script_host_set_engine_snapshot_json(WEScriptHost* host, const char* json) {
    WEScriptHostEvaluation evaluation = {0};
    if (host == NULL || host->context == NULL) {
        evaluation.error_message = duplicate_c_string("Failed to create QuickJS runtime/context");
        return evaluation;
    }
    update_stack_thread(host);
    JSContext* ctx = host->context;
    JSValue value = parse_json(ctx, json, "<engineSnapshot>");
    if (!JS_IsException(value) && (!JS_IsObject(value) || JS_IsArray(value))) {
        JS_FreeValue(ctx, value);
        value = JS_ThrowTypeError(ctx, "Engine snapshot must be an object");
    }
    if (JS_IsException(value)) {
        evaluation.error_message = exception_to_string(ctx);
        return evaluation;
    }
    JS_FreeValue(ctx, host->engine_snapshot);
    host->engine_snapshot = value;
    return evaluation;
}

// Only called on the private JSON snapshot, never on authored objects/getters.
// Immutable strings/scalars can share storage; objects must remain independent.
static JSValue copy_json_value(JSContext* ctx, JSValueConst value, unsigned depth) {
    if (!JS_IsObject(value)) return JS_DupValue(ctx, value);
    if (depth > 256) return JS_ThrowRangeError(ctx, "User properties exceed the snapshot nesting limit");
    JSPropertyEnum* properties = NULL;
    uint32_t count = 0;
    if (JS_GetOwnPropertyNames(ctx, &properties, &count, value,
                              JS_GPN_STRING_MASK | JS_GPN_ENUM_ONLY) < 0) return JS_EXCEPTION;
    JSValue result = JS_IsArray(value) ? JS_NewArray(ctx) : JS_NewObject(ctx);
    for (uint32_t i = 0; i < count && !JS_IsException(result); ++i) {
        JSValue member = JS_GetProperty(ctx, value, properties[i].atom);
        JSValue copy = JS_IsException(member) ? JS_EXCEPTION : copy_json_value(ctx, member, depth + 1);
        JS_FreeValue(ctx, member);
        if (JS_IsException(copy) || JS_DefinePropertyValue(ctx, result, properties[i].atom, copy,
                JS_PROP_C_W_E) < 0) {
            JS_FreeValue(ctx, result);
            result = JS_EXCEPTION;
        }
    }
    for (uint32_t i = 0; i < count; ++i) JS_FreeAtom(ctx, properties[i].atom);
    js_free(ctx, properties);
    return result;
}

// Both inputs are private parsed JSON, never authored objects or accessors.
// Consumes overrides and returns a fresh engine object (or an exception).
static JSValue merge_engine_snapshot(WEScriptHost* host, JSValue overrides) {
    if (JS_IsUndefined(host->engine_snapshot) || !JS_IsObject(overrides)) return overrides;
    JSContext* ctx = host->context;
    JSValue result = copy_json_value(ctx, host->engine_snapshot, 0);
    JSPropertyEnum* properties = NULL;
    uint32_t count = 0;
    if (!JS_IsException(result) && JS_GetOwnPropertyNames(ctx, &properties, &count, overrides,
            JS_GPN_STRING_MASK | JS_GPN_ENUM_ONLY) < 0) {
        JS_FreeValue(ctx, result);
        result = JS_EXCEPTION;
    }
    for (uint32_t i = 0; i < count && !JS_IsException(result); ++i) {
        JSValue member = JS_GetProperty(ctx, overrides, properties[i].atom);
        if (JS_IsException(member) || JS_DefinePropertyValue(ctx, result, properties[i].atom,
                member, JS_PROP_C_W_E) < 0) {
            JS_FreeValue(ctx, result);
            result = JS_EXCEPTION;
        }
    }
    for (uint32_t i = 0; i < count; ++i) JS_FreeAtom(ctx, properties[i].atom);
    js_free(ctx, properties);
    JS_FreeValue(ctx, overrides);
    return result;
}

static WEScriptHostEvaluation json_evaluation(JSContext* ctx, JSValue result) {
    WEScriptHostEvaluation evaluation = {0};
    if (JS_IsException(result)) {
        evaluation.error_message = exception_to_string(ctx);
        return evaluation;
    }
    JSValue json = JS_JSONStringify(ctx, result, JS_UNDEFINED, JS_UNDEFINED);
    JS_FreeValue(ctx, result);
    if (JS_IsException(json)) {
        evaluation.error_message = exception_to_string(ctx);
        return evaluation;
    }
    const char* string = JS_IsUndefined(json) ? NULL : JS_ToCString(ctx, json);
    evaluation.result_json = duplicate_c_string(string != NULL ? string : "null");
    if (string != NULL) JS_FreeCString(ctx, string);
    JS_FreeValue(ctx, json);
    return evaluation;
}

static char* collect_scene_mutations(JSContext* ctx);

WEScriptHostEvaluation we_script_host_scene_json(
    WEScriptHost* host, const char* source, const char* command_json
) {
    WEScriptHostEvaluation evaluation = {0};
    if (host == NULL || host->context == NULL) {
        evaluation.error_message = duplicate_c_string("Failed to create QuickJS runtime/context");
        return evaluation;
    }
    update_stack_thread(host);
    JSContext* ctx = host->context;
    if (source != NULL) {
        JSValue loaded = JS_Eval(ctx, source, strlen(source), "<scene-bindings>", JS_EVAL_TYPE_GLOBAL);
        if (JS_IsException(loaded)) return json_evaluation(ctx, loaded);
        JS_FreeValue(ctx, loaded);
    }
    JSValue command = parse_json(ctx, command_json, "<scene-state>");
    if (JS_IsException(command)) return json_evaluation(ctx, command);
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue bridge = JS_GetPropertyStr(ctx, global, "__weSceneBridge");
    JSValue result = JS_Call(ctx, bridge, global, 1, &command);
    JS_FreeValue(ctx, bridge);
    JS_FreeValue(ctx, global);
    JS_FreeValue(ctx, command);
    evaluation = json_evaluation(ctx, result);
    evaluation.mutations_json = collect_scene_mutations(ctx);
    return evaluation;
}

static char* collect_scene_mutations(JSContext* ctx) {
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue drain = JS_GetPropertyStr(ctx, global, "__weDrainSceneMutations");
    char* json = NULL;
    if (JS_IsFunction(ctx, drain)) {
        WEScriptHostEvaluation changes = json_evaluation(ctx, JS_Call(ctx, drain, global, 0, NULL));
        json = changes.result_json;
        if (changes.error_message != NULL) free(changes.error_message);
    }
    JS_FreeValue(ctx, drain);
    JS_FreeValue(ctx, global);
    return json;
}

WEScriptHostEvaluation we_script_host_evaluate_json(
    WEScriptHost* host,
    const char* instance_id,
    const char* script_source,
    const char* script_properties_json,
    const char* current_value_json,
    const char* engine_json,
    const char* input_json
) {
    WEScriptHostEvaluation evaluation = {0};

    if (host == NULL || host->context == NULL) {
        evaluation.error_message = duplicate_c_string("Failed to create QuickJS runtime/context");
        return evaluation;
    }

    update_stack_thread(host);
    JSContext* ctx = host->context;
    JSValue props = parse_json(ctx, script_properties_json != NULL ? script_properties_json : "{}", "<scriptProperties>");
    if (JS_IsException(props)) {
        evaluation.error_message = exception_to_string(ctx);
        return evaluation;
    }

    JSValue current_value = parse_json(ctx, current_value_json, "<currentValue>");
    if (JS_IsException(current_value)) {
        JS_FreeValue(ctx, props);
        evaluation.error_message = exception_to_string(ctx);
        return evaluation;
    }

    JSValue engine = merge_engine_snapshot(host,
        parse_json(ctx, engine_json != NULL ? engine_json : "{}", "<engine>"));
    if (JS_IsObject(engine) && !JS_IsUndefined(host->user_properties)) {
        // Match a JSON member: inherited authored accessors must not intercept
        // either the missing-value check or delivery of the host snapshot.
        JSAtom property = JS_NewAtom(ctx, "userProperties");
        int supplied = property == JS_ATOM_NULL ? -1 : JS_GetOwnProperty(ctx, NULL, engine, property);
        if (supplied < 0) {
            JS_FreeValue(ctx, engine);
            engine = JS_EXCEPTION;
        } else if (supplied == 0) {
            JSValue snapshot = copy_json_value(ctx, host->user_properties, 0);
            if (JS_IsException(snapshot) || JS_DefinePropertyValue(ctx, engine, property, snapshot, JS_PROP_C_W_E) < 0) {
                JS_FreeValue(ctx, engine);
                engine = JS_EXCEPTION;
            }
        }
        JS_FreeAtom(ctx, property);
    }
    if (JS_IsException(engine)) {
        JS_FreeValue(ctx, props);
        JS_FreeValue(ctx, current_value);
        evaluation.error_message = exception_to_string(ctx);
        return evaluation;
    }

    JSValue input = parse_json(ctx, input_json != NULL ? input_json : "{}", "<input>");
    if (JS_IsException(input)) {
        JS_FreeValue(ctx, props);
        JS_FreeValue(ctx, current_value);
        JS_FreeValue(ctx, engine);
        evaluation.error_message = exception_to_string(ctx);
        return evaluation;
    }

    JSValue global_object = JS_GetGlobalObject(ctx);
    JSValue instances = JS_GetPropertyStr(ctx, global_object, "__weValueInstances");
    JSValue instance = JS_IsObject(instances)
        ? JS_GetPropertyStr(ctx, instances, instance_id != NULL ? instance_id : "default") : JS_UNDEFINED;
    const bool initialized = JS_IsObject(instance);
    JS_FreeValue(ctx, instance);
    JS_FreeValue(ctx, instances);

    char* eval_script = build_eval_script(initialized ? NULL : script_source);
    if (eval_script == NULL) {
        JS_FreeValue(ctx, props);
        JS_FreeValue(ctx, current_value);
        JS_FreeValue(ctx, engine);
        JS_FreeValue(ctx, input);
        JS_FreeValue(ctx, global_object);
        evaluation.error_message = duplicate_c_string("Failed to allocate script wrapper");
        return evaluation;
    }

    JS_SetPropertyStr(ctx, global_object, "__instanceID", JS_NewString(ctx, instance_id != NULL ? instance_id : "default"));
    JS_SetPropertyStr(ctx, global_object, "__scriptProps", JS_DupValue(ctx, props));
    JS_SetPropertyStr(ctx, global_object, "__currentValue", JS_DupValue(ctx, current_value));
    JS_SetPropertyStr(ctx, global_object, "__engine", JS_DupValue(ctx, engine));
    JS_SetPropertyStr(ctx, global_object, "__input", JS_DupValue(ctx, input));

    JSValue result;
    if (initialized) {
        if (JS_IsUndefined(host->value_dispatcher)) {
            host->value_dispatcher = JS_Eval(ctx, eval_script, strlen(eval_script), "<script-dispatch>",
                                             JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_COMPILE_ONLY);
        }
        result = JS_IsException(host->value_dispatcher) ? JS_EXCEPTION
            : JS_EvalFunction(ctx, JS_DupValue(ctx, host->value_dispatcher));
    } else {
        result = JS_Eval(ctx, eval_script, strlen(eval_script), instance_id != NULL ? instance_id : "<script>", JS_EVAL_TYPE_GLOBAL);
    }

    JS_SetPropertyStr(ctx, global_object, "__scriptProps", JS_UNDEFINED);
    JS_SetPropertyStr(ctx, global_object, "__currentValue", JS_UNDEFINED);
    JS_SetPropertyStr(ctx, global_object, "__engine", JS_UNDEFINED);
    JS_SetPropertyStr(ctx, global_object, "__input", JS_UNDEFINED);

    free(eval_script);
    JS_FreeValue(ctx, global_object);
    JS_FreeValue(ctx, props);
    JS_FreeValue(ctx, current_value);
    JS_FreeValue(ctx, engine);
    JS_FreeValue(ctx, input);

    if (JS_IsException(result)) {
        JS_FreeValue(ctx, result);
        evaluation.error_message = exception_to_string(ctx);
        evaluation.mutations_json = collect_scene_mutations(ctx);
        return evaluation;
    }
    evaluation.mutations_json = collect_scene_mutations(ctx);

    JSValue result_json = JS_JSONStringify(ctx, result, JS_UNDEFINED, JS_UNDEFINED);
    JS_FreeValue(ctx, result);

    if (JS_IsException(result_json)) {
        evaluation.error_message = exception_to_string(ctx);
        return evaluation;
    }

    const char* json_string = JS_ToCString(ctx, result_json);
    evaluation.result_json = duplicate_c_string(json_string != NULL ? json_string : "null");
    if (json_string != NULL) {
        JS_FreeCString(ctx, json_string);
    }
    JS_FreeValue(ctx, result_json);
    return evaluation;
}

WEScriptHostEvaluation we_scene_script_host_execute_json(
    WEScriptHost* host,
    const char* instance_id,
    const char* script_source,
    const char* callback_name,
    const char* this_object_json,
    const char* changed_user_properties_json,
    const char* engine_json,
    const char* input_json
) {
    WEScriptHostEvaluation evaluation = {0};

    if (host == NULL || host->context == NULL) {
        evaluation.error_message = duplicate_c_string("Failed to create QuickJS runtime/context");
        return evaluation;
    }

    update_stack_thread(host);
    JSContext* ctx = host->context;
    JSValue this_object = parse_json(ctx, this_object_json, "<thisObject>");
    if (JS_IsException(this_object)) {
        evaluation.error_message = exception_to_string(ctx);
        return evaluation;
    }

    JSValue changed_user_properties = parse_json(
        ctx,
        changed_user_properties_json != NULL ? changed_user_properties_json : "{}",
        "<changedUserProperties>"
    );
    if (JS_IsException(changed_user_properties)) {
        JS_FreeValue(ctx, this_object);
        evaluation.error_message = exception_to_string(ctx);
        return evaluation;
    }

    JSValue engine = parse_json(ctx, engine_json != NULL ? engine_json : "{}", "<engine>");
    if (JS_IsException(engine)) {
        JS_FreeValue(ctx, this_object);
        JS_FreeValue(ctx, changed_user_properties);
        evaluation.error_message = exception_to_string(ctx);
        return evaluation;
    }

    JSValue input = parse_json(ctx, input_json != NULL ? input_json : "{}", "<input>");
    if (JS_IsException(input)) {
        JS_FreeValue(ctx, this_object);
        JS_FreeValue(ctx, changed_user_properties);
        JS_FreeValue(ctx, engine);
        evaluation.error_message = exception_to_string(ctx);
        return evaluation;
    }

    char* eval_script = build_scene_callback_script(script_source, callback_name);
    if (eval_script == NULL) {
        JS_FreeValue(ctx, this_object);
        JS_FreeValue(ctx, changed_user_properties);
        JS_FreeValue(ctx, engine);
        JS_FreeValue(ctx, input);
        evaluation.error_message = duplicate_c_string("Failed to allocate scene script wrapper");
        return evaluation;
    }

    JSValue global_object = JS_GetGlobalObject(ctx);
    JS_SetPropertyStr(ctx, global_object, "__instanceID", JS_NewString(ctx, instance_id != NULL ? instance_id : "default"));
    JS_SetPropertyStr(ctx, global_object, "__callbackName", JS_NewString(ctx, callback_name != NULL ? callback_name : ""));
    JS_SetPropertyStr(ctx, global_object, "__thisObject", JS_DupValue(ctx, this_object));
    JS_SetPropertyStr(ctx, global_object, "__thisScene", JS_NewObject(ctx));
    JS_SetPropertyStr(ctx, global_object, "__changedUserProperties", JS_DupValue(ctx, changed_user_properties));
    JS_SetPropertyStr(ctx, global_object, "__engine", JS_DupValue(ctx, engine));
    JS_SetPropertyStr(ctx, global_object, "__input", JS_DupValue(ctx, input));

    JSValue result = JS_Eval(ctx, eval_script, strlen(eval_script), "<scene-script>", JS_EVAL_TYPE_GLOBAL);

    JS_SetPropertyStr(ctx, global_object, "__thisObject", JS_UNDEFINED);
    JS_SetPropertyStr(ctx, global_object, "__thisScene", JS_UNDEFINED);
    JS_SetPropertyStr(ctx, global_object, "__changedUserProperties", JS_UNDEFINED);
    JS_SetPropertyStr(ctx, global_object, "__engine", JS_UNDEFINED);
    JS_SetPropertyStr(ctx, global_object, "__input", JS_UNDEFINED);

    free(eval_script);
    JS_FreeValue(ctx, global_object);
    JS_FreeValue(ctx, this_object);
    JS_FreeValue(ctx, changed_user_properties);
    JS_FreeValue(ctx, engine);
    JS_FreeValue(ctx, input);

    if (JS_IsException(result)) {
        JS_FreeValue(ctx, result);
        evaluation.error_message = exception_to_string(ctx);
        evaluation.mutations_json = collect_scene_mutations(ctx);
        return evaluation;
    }
    evaluation.mutations_json = collect_scene_mutations(ctx);

    JSValue result_json = JS_JSONStringify(ctx, result, JS_UNDEFINED, JS_UNDEFINED);
    JS_FreeValue(ctx, result);

    if (JS_IsException(result_json)) {
        evaluation.error_message = exception_to_string(ctx);
        return evaluation;
    }

    const char* json_string = JS_ToCString(ctx, result_json);
    evaluation.result_json = duplicate_c_string(json_string != NULL ? json_string : "{}");
    if (json_string != NULL) {
        JS_FreeCString(ctx, json_string);
    }
    JS_FreeValue(ctx, result_json);
    return evaluation;
}

void we_script_host_free_evaluation(WEScriptHostEvaluation evaluation) {
    if (evaluation.result_json != NULL) {
        free(evaluation.result_json);
    }
    if (evaluation.error_message != NULL) {
        free(evaluation.error_message);
    }
    if (evaluation.mutations_json != NULL) free(evaluation.mutations_json);
}
