cmake_minimum_required(VERSION 3.12)
project(wallpaperengine-vendored-deps C CXX)

if(NOT ENGINE_SOURCE_DIR OR NOT QUICKJS_SOURCE_DIR)
    message(FATAL_ERROR "Use build-bridge.sh to prepare the dependency sources")
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_C_STANDARD 11)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(ENABLE_OPT OFF)
set(SPIRV_CROSS_FORCE_PIC ON)
set(QJS_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)

add_subdirectory("${ENGINE_SOURCE_DIR}/src/External/glslang-WallpaperEngine" glslang)
add_subdirectory("${ENGINE_SOURCE_DIR}/src/External/SPIRV-Cross-WallpaperEngine" spirv-cross)
add_subdirectory("${QUICKJS_SOURCE_DIR}" quickjs)

# Match Package.swift's link inputs. Upstream command-line utilities and test
# executables are not needed by the app and can rebuild on timestamp changes.
add_custom_target(wallpaper-dependencies DEPENDS
    glslang MachineIndependent GenericCodeGen glslang-default-resource-limits
    OSDependent SPIRV spirv-cross-core spirv-cross-glsl spirv-cross-msl qjs)
