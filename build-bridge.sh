#!/bin/bash
set -euo pipefail

# Build only the vendored shader and script libraries used by Package.swift.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENGINE_DIR="$SCRIPT_DIR/linux-wallpaperengine"
BUILD_DIR="$SCRIPT_DIR/build"
CMAKE_SOURCE_DIR="$SCRIPT_DIR/cmake/dependencies"

# Fail before changing build state if the selected toolchain is unavailable.
C_COMPILER="$(xcrun -find cc)"
CXX_COMPILER="$(xcrun -find c++)"

# Initialize only missing dependencies. Do not reset existing local checkouts,
# silently ignore failures, or fetch unrelated nested test suites.
if [ ! -f "$ENGINE_DIR/CMakeLists.txt" ]; then
    git -C "$SCRIPT_DIR" submodule update --init -- linux-wallpaperengine
fi
for dependency in glslang-WallpaperEngine SPIRV-Cross-WallpaperEngine quickjs json; do
    if [ ! -f "$ENGINE_DIR/src/External/$dependency/CMakeLists.txt" ]; then
        git -C "$ENGINE_DIR" submodule update --init -- "src/External/$dependency"
    fi
done

mkdir -p "$BUILD_DIR"
# Patch a generated copy, leaving the nested dependency checkout untouched.
# Stage first so a malformed patch cannot damage the last usable build source.
QUICKJS_STAGE="$(mktemp -d "$BUILD_DIR/quickjs-stage.XXXXXX")"
trap 'rm -rf "$QUICKJS_STAGE"' EXIT
rsync -a --exclude=.git "$ENGINE_DIR/src/External/quickjs/" "$QUICKJS_STAGE/"
QUICKJS_PATCH="$SCRIPT_DIR/patches/quickjs-mapped-arguments-gc.patch"
if git -C "$QUICKJS_STAGE" apply --reverse --check "$QUICKJS_PATCH" 2>/dev/null; then
    : # Accept an already-applied fix in an existing developer checkout.
else
    git -C "$QUICKJS_STAGE" apply --check "$QUICKJS_PATCH"
    git -C "$QUICKJS_STAGE" apply "$QUICKJS_PATCH"
fi
mkdir -p "$BUILD_DIR/quickjs-source"
# Checksums keep unchanged patched inputs from forcing recompilation every run.
rsync -rc --delete "$QUICKJS_STAGE/" "$BUILD_DIR/quickjs-source/"

# CMake cannot reuse a cache after its source directory changes. Preserve other
# build products; discard only generated configuration from the former bridge.
if [ -f "$BUILD_DIR/CMakeCache.txt" ] && ! grep -Fqx "CMAKE_HOME_DIRECTORY:INTERNAL=$CMAKE_SOURCE_DIR" "$BUILD_DIR/CMakeCache.txt"; then
    cmake -E remove -f "$BUILD_DIR/CMakeCache.txt"
    cmake -E remove_directory "$BUILD_DIR/CMakeFiles"
fi

cmake -S "$CMAKE_SOURCE_DIR" -B "$BUILD_DIR" \
    -DENGINE_SOURCE_DIR="$ENGINE_DIR" \
    -DQUICKJS_SOURCE_DIR="$BUILD_DIR/quickjs-source" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$C_COMPILER" \
    -DCMAKE_CXX_COMPILER="$CXX_COMPILER" \
    -DCMAKE_OSX_ARCHITECTURES="$(uname -m)"
cmake --build "$BUILD_DIR" --target wallpaper-dependencies --parallel "$(sysctl -n hw.logicalcpu)"
