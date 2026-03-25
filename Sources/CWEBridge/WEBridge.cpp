#include "include/WEBridge.h"

#include <cstring>
#include <iostream>
#include <memory>
#include <string>

#include <GL/glew.h>
#include <GLFW/glfw3.h>

#ifdef __APPLE__
#define GLFW_EXPOSE_NATIVE_COCOA
#define GLFW_EXPOSE_NATIVE_NSGL
#endif
#include <GLFW/glfw3native.h>

#include "WallpaperEngine/Application/ApplicationContext.h"
#include "WallpaperEngine/Application/WallpaperApplication.h"
#include "WallpaperEngine/Render/CWallpaper.h"
#include "WallpaperEngine/Render/Drivers/GLFWOpenGLDriver.h"
#include "WallpaperEngine/Render/Drivers/Output/OutputViewport.h"
#include "WallpaperEngine/Render/RenderContext.h"
#include "WallpaperEngine/Logging/Log.h"

// Global time variables used by the engine
extern float g_Time;
extern float g_TimeLast;
extern float g_Daytime;

using namespace WallpaperEngine::Application;
using namespace WallpaperEngine::Render;

struct WEContext {
    std::unique_ptr<ApplicationContext> appContext;
    std::unique_ptr<WallpaperApplication> app;
    GLFWwindow* glfwWindow = nullptr;  // Stored before driver ownership transfers
    bool initialized = false;
    bool paused = false;
    double totalTime = 0.0;
};

WEContextRef we_create_context(const char* wallpaper_path, const char* assets_path,
                                int viewport_width, int viewport_height) {
    // Wire up logging to stdout/stderr if not already done (main.cpp never runs in the Swift app)
    static bool loggingInitialized = false;
    if (!loggingInitialized) {
        sLog.addOutput (new std::ostream (std::cout.rdbuf ()));
        sLog.addError (new std::ostream (std::cerr.rdbuf ()));
        loggingInitialized = true;
    }

    auto ctx = new WEContext();

    try {
        // Create application context with direct paths (no argv parsing)
        ctx->appContext = std::make_unique<ApplicationContext>(
            std::string(wallpaper_path),
            std::string(assets_path),
            viewport_width,
            viewport_height
        );

        // Create wallpaper application — this loads and parses the wallpaper
        ctx->app = std::make_unique<WallpaperApplication>(*ctx->appContext);

        // Create the GLFW OpenGL driver (GLFW/GLEW already initialized by the driver constructor)
        auto driver = std::make_unique<WallpaperEngine::Render::Drivers::GLFWOpenGLDriver>(
            "wallpaperengine-bridge", *ctx->appContext, *ctx->app
        );

        // Store the GLFW window before ownership transfers
        ctx->glfwWindow = driver->getWindow();

        // Set up for embedding: creates audio, render context, wallpapers
        ctx->app->setupForEmbedding(std::move(driver));

        ctx->initialized = true;
        sLog.out("WEBridge: Context created for ", wallpaper_path);
    } catch (const std::exception& e) {
        sLog.error("WEBridge: Failed to create context: ", e.what());
        delete ctx;
        return nullptr;
    } catch (...) {
        sLog.error("WEBridge: Failed to create context: unknown exception");
        delete ctx;
        return nullptr;
    }

    return ctx;
}

void we_render_frame(WEContextRef ctx, double delta_time) {
    if (!ctx || !ctx->initialized || ctx->paused)
        return;

    try {
        // Make the engine's GLFW context current (FBOs are per-context)
        glfwMakeContextCurrent(ctx->glfwWindow);

        ctx->totalTime += delta_time;

        // Update engine time globals
        g_TimeLast = g_Time;
        g_Time = static_cast<float>(ctx->totalTime);

        // Update daytime
        time_t seconds;
        time(&seconds);
        struct tm* timeinfo = localtime(&seconds);
        g_Daytime = static_cast<float>((timeinfo->tm_hour * 60) + timeinfo->tm_min) / (24.0f * 60.0f);

        // Render to each viewport (typically just "default")
        const auto& viewports = ctx->app->getOutput().getViewports();
        for (const auto& [screen, viewport] : viewports) {
            ctx->app->update(viewport);
        }

        // Ensure rendering is complete before the texture is read from another context
        glFinish();
    } catch (const std::exception& e) {
        sLog.error("WEBridge: Render error: ", e.what());
    }
}

uint32_t we_get_texture(WEContextRef ctx) {
    if (!ctx || !ctx->initialized)
        return 0;

    try {
        const auto* renderCtx = ctx->app->getRenderContext();
        if (!renderCtx)
            return 0;

        const auto& wallpapers = renderCtx->getWallpapers();
        if (wallpapers.empty())
            return 0;

        // Return the first wallpaper's output texture (typically "default")
        return wallpapers.begin()->second->getWallpaperTexture();
    } catch (...) {
        return 0;
    }
}

void we_get_resolution(WEContextRef ctx, int* width, int* height) {
    if (!ctx || !ctx->initialized) {
        if (width) *width = 0;
        if (height) *height = 0;
        return;
    }

    try {
        const auto& output = ctx->app->getOutput();
        if (width) *width = output.getFullWidth();
        if (height) *height = output.getFullHeight();
    } catch (...) {
        if (width) *width = 0;
        if (height) *height = 0;
    }
}

void we_set_mouse_position(WEContextRef ctx, float x, float y) {
    if (!ctx || !ctx->initialized)
        return;

    // The engine reads mouse position from the input context
    // For now, we can't directly set it without modifying GLFWMouseInput
    // TODO: Add direct mouse position injection to InputContext
    (void)x;
    (void)y;
}

void we_set_property(WEContextRef ctx, const char* name, const char* value) {
    if (!ctx || !ctx->initialized || !name || !value)
        return;

    ctx->appContext->settings.general.properties[name] = value;
}

void we_set_paused(WEContextRef ctx, int paused) {
    if (!ctx || !ctx->initialized)
        return;

    ctx->paused = (paused != 0);
}

void we_set_audio_data(WEContextRef ctx, const float* data, int count) {
    if (!ctx || !ctx->initialized || !data || count <= 0)
        return;

    // Audio reactivity is stubbed in v1 — wallpapers see silence
    (void)data;
    (void)count;
}

void we_destroy_context(WEContextRef ctx) {
    if (!ctx)
        return;

    sLog.out("WEBridge: Destroying context");
    ctx->app.reset();
    ctx->appContext.reset();
    delete ctx;
}

void* we_get_gl_context(WEContextRef ctx) {
    if (!ctx || !ctx->initialized || !ctx->glfwWindow)
        return nullptr;

#ifdef __APPLE__
    return (void*)glfwGetNSGLContext(ctx->glfwWindow);
#else
    return nullptr;
#endif
}
