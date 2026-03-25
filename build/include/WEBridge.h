#ifndef WEBRIDGE_H
#define WEBRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque handle to the Wallpaper Engine rendering context.
typedef struct WEContext* WEContextRef;

/// Create a rendering context for a scene wallpaper.
///
/// @param wallpaper_path  Path to the wallpaper directory (containing project.json).
/// @param assets_path     Path to Wallpaper Engine's shared assets directory.
/// @param viewport_width  Width of the rendering viewport in pixels.
/// @param viewport_height Height of the rendering viewport in pixels.
/// @return A context handle, or NULL on failure.
WEContextRef we_create_context(const char* wallpaper_path, const char* assets_path,
                                int viewport_width, int viewport_height);

/// Render one frame of the wallpaper.
///
/// Must be called with the GL context current.
/// @param ctx        The rendering context.
/// @param delta_time Time elapsed since the last frame in seconds.
void we_render_frame(WEContextRef ctx, double delta_time);

/// Get the OpenGL texture ID of the most recently rendered frame.
///
/// @param ctx The rendering context.
/// @return The OpenGL texture name, or 0 if no frame has been rendered.
uint32_t we_get_texture(WEContextRef ctx);

/// Get the native resolution of the wallpaper.
///
/// @param ctx    The rendering context.
/// @param width  Output: wallpaper width in pixels.
/// @param height Output: wallpaper height in pixels.
void we_get_resolution(WEContextRef ctx, int* width, int* height);

/// Update the mouse cursor position for interactive wallpapers.
///
/// @param ctx The rendering context.
/// @param x   Normalized X coordinate (0.0–1.0).
/// @param y   Normalized Y coordinate (0.0–1.0).
void we_set_mouse_position(WEContextRef ctx, float x, float y);

/// Set a user property on the wallpaper.
///
/// @param ctx   The rendering context.
/// @param name  Property name.
/// @param value Property value as a string.
void we_set_property(WEContextRef ctx, const char* name, const char* value);

/// Pause or unpause the wallpaper rendering.
///
/// When paused, the engine stops updating animations but retains its state.
/// @param ctx    The rendering context.
/// @param paused Non-zero to pause, zero to resume.
void we_set_paused(WEContextRef ctx, int paused);

/// Provide audio frequency data for audio-reactive wallpapers.
///
/// @param ctx   The rendering context.
/// @param data  Array of frequency amplitudes.
/// @param count Number of elements in the data array.
void we_set_audio_data(WEContextRef ctx, const float* data, int count);

/// Destroy a rendering context and release all resources.
///
/// @param ctx The rendering context.
void we_destroy_context(WEContextRef ctx);

/// Get the underlying NSOpenGLContext* for GL context sharing.
///
/// On macOS, returns the NSGL context from the GLFW window, which can be
/// used to create a shared NSOpenGLView.
/// @param ctx The rendering context.
/// @return An NSOpenGLContext* (as void*), or NULL on failure.
void* we_get_gl_context(WEContextRef ctx);

#ifdef __cplusplus
}
#endif

#endif /* WEBRIDGE_H */
