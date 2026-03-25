#!/bin/bash
set -euo pipefail

# Build linux-wallpaperengine as a static library for macOS.
# Products:
#   build/lib/libwallpaperengine.a   — static library
#   build/include/WEBridge.h         — C bridge header

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENGINE_DIR="$SCRIPT_DIR/linux-wallpaperengine"
BUILD_DIR="$SCRIPT_DIR/build"
BRIDGE_SRC="$SCRIPT_DIR/Sources/CWEBridge"
CMAKE_WRAPPER_DIR="$BUILD_DIR/cmake-bridge"

echo "=== Building wallpaperengine bridge ==="
echo "Engine:  $ENGINE_DIR"
echo "Build:   $BUILD_DIR"

# Ensure submodules are initialized
if [ ! -f "$ENGINE_DIR/CMakeLists.txt" ]; then
    echo "Initializing git submodules..."
    cd "$SCRIPT_DIR"
    git submodule update --init --recursive
fi

# Also init nested submodules (glslang, SPIRV-Cross, etc.)
cd "$ENGINE_DIR"
git submodule update --init --recursive 2>/dev/null || true

# Create a wrapper directory with a CMakeLists.txt that includes the bridge config.
# This avoids modifying the engine's own CMakeLists.txt.
mkdir -p "$CMAKE_WRAPPER_DIR"
cat > "$CMAKE_WRAPPER_DIR/CMakeLists.txt" <<'WRAPPER_EOF'
cmake_minimum_required(VERSION 3.12)
# Wrapper that redirects to the bridge CMake configuration.
# All relative paths in CMakeLists-bridge.cmake are resolved relative to
# the engine source directory via CMAKE_CURRENT_SOURCE_DIR override.
include("${ENGINE_SOURCE_DIR}/CMakeLists-bridge.cmake")
WRAPPER_EOF

echo ""
echo "=== Configuring CMake ==="
cmake -S "$CMAKE_WRAPPER_DIR" -B "$BUILD_DIR" \
    -DENGINE_SOURCE_DIR="$ENGINE_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$(xcrun -find cc)" \
    -DCMAKE_CXX_COMPILER="$(xcrun -find c++)" \
    -DCMAKE_OSX_ARCHITECTURES="$(uname -m)" \
    2>&1

echo ""
echo "=== Compiling (this may take a few minutes) ==="
cmake --build "$BUILD_DIR" --parallel "$(sysctl -n hw.logicalcpu)" 2>&1

# Copy products to standard locations
mkdir -p "$BUILD_DIR/lib" "$BUILD_DIR/include"

# Find and copy the static library
find "$BUILD_DIR" -name "libwallpaperengine.a" -maxdepth 1 -exec cp {} "$BUILD_DIR/lib/" \; 2>/dev/null || true

# Copy the bridge header
cp "$BRIDGE_SRC/include/WEBridge.h" "$BUILD_DIR/include/"

echo ""
echo "=== Build complete ==="
if [ -f "$BUILD_DIR/lib/libwallpaperengine.a" ]; then
    LIB_SIZE=$(du -h "$BUILD_DIR/lib/libwallpaperengine.a" | cut -f1)
    echo "Static library: $BUILD_DIR/lib/libwallpaperengine.a ($LIB_SIZE)"
    echo "Bridge header:  $BUILD_DIR/include/WEBridge.h"
else
    echo "WARNING: libwallpaperengine.a not found. Check build output for errors."
    exit 1
fi
echo ""
echo "Required Homebrew dependencies:"
echo "  brew install glew glfw sdl2 lz4 ffmpeg freeglut"
