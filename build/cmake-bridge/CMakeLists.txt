cmake_minimum_required(VERSION 3.12)
# Wrapper that redirects to the bridge CMake configuration.
# All relative paths in CMakeLists-bridge.cmake are resolved relative to
# the engine source directory via CMAKE_CURRENT_SOURCE_DIR override.
include("${ENGINE_SOURCE_DIR}/CMakeLists-bridge.cmake")
