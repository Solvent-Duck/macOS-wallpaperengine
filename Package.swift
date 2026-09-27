// swift-tools-version: 6.2

import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let vendoredRoot = "\(packageRoot)/linux-wallpaperengine"
let buildRoot = "\(packageRoot)/build"

let package = Package(
    name: "macOS-wallpaperengine",
    platforms: [.macOS(.v26)],
    targets: [
        .testTarget(
            name: "WallpaperEngineTests",
            dependencies: ["WallpaperEngine"]
        ),
        .testTarget(
            name: "NativeSceneRendererTests",
            dependencies: ["NativeSceneCore", "NativeSceneRuntime", "NativeSceneRenderer"]
        ),
        .testTarget(
            name: "NativeSceneRuntimeTests",
            dependencies: ["NativeSceneCore", "NativeSceneRuntime"]
        ),
        .target(
            name: "NativeSceneCore",
            path: "Sources/NativeSceneCore"
        ),
        .target(
            name: "CShaderCompiler",
            path: "Sources/CShaderCompiler",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags([
                    "-std=c++20",
                    "-I\(vendoredRoot)/src/External/glslang-WallpaperEngine",
                    "-I\(vendoredRoot)/src/External/SPIRV-Cross-WallpaperEngine",
                    "-I\(vendoredRoot)/src/External/json/include",
                ]),
            ],
            linkerSettings: [
                .linkedLibrary("glslang"),
                .linkedLibrary("MachineIndependent"),
                .linkedLibrary("GenericCodeGen"),
                .linkedLibrary("glslang-default-resource-limits"),
                .linkedLibrary("OSDependent"),
                .linkedLibrary("SPIRV"),
                .linkedLibrary("spirv-cross-core"),
                .linkedLibrary("spirv-cross-glsl"),
                .linkedLibrary("spirv-cross-msl"),
                .linkedLibrary("c++"),
                .unsafeFlags([
                    "-L\(buildRoot)/glslang/glslang",
                    "-L\(buildRoot)/glslang/glslang/OSDependent/Unix",
                    "-L\(buildRoot)/glslang/SPIRV",
                    "-L\(buildRoot)/spirv-cross",
                    "-L/usr/local/lib",
                    "-L/opt/homebrew/lib",
                ]),
            ]
        ),
        .target(
            name: "CScriptHost",
            path: "Sources/CScriptHost",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags([
                    "-I\(vendoredRoot)/src/External/quickjs",
                ]),
            ],
            linkerSettings: [
                .linkedLibrary("qjs"),
                .unsafeFlags([
                    "-L\(buildRoot)/quickjs",
                    "-L/usr/local/lib",
                    "-L/opt/homebrew/lib",
                ]),
            ]
        ),
        .target(
            name: "NativeSceneCompatibility",
            dependencies: ["NativeSceneCore", "CShaderCompiler"],
            path: "Sources/NativeSceneCompatibility"
        ),
        .target(
            name: "NativeSceneRuntime",
            dependencies: ["NativeSceneCore", "CScriptHost"],
            path: "Sources/NativeSceneRuntime"
        ),
        .target(
            name: "NativeSceneRenderer",
            dependencies: ["NativeSceneCore", "NativeSceneRuntime", "NativeSceneCompatibility"],
            path: "Sources/NativeSceneRenderer",
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
            ]
        ),
        .target(
            name: "NativeSceneBridge",
            dependencies: ["NativeSceneCore"],
            path: "Sources/NativeSceneBridge"
        ),
        .executableTarget(
            name: "ShaderFixtureTool",
            dependencies: ["NativeSceneCompatibility"],
            path: "Sources/ShaderFixtureTool"
        ),
        .executableTarget(
            name: "ScriptHostFixtureTool",
            dependencies: ["NativeSceneRuntime"],
            path: "Sources/ScriptHostFixtureTool"
        ),
        .executableTarget(
            name: "SceneRuntimeBenchmarkTool",
            dependencies: ["NativeSceneCore", "NativeSceneBridge", "NativeSceneRuntime"],
            path: "Sources/SceneRuntimeBenchmarkTool"
        ),
        .executableTarget(
            name: "SceneNativeSnapshotTool",
            dependencies: ["NativeSceneBridge", "NativeSceneRenderer"],
            path: "Sources/SceneNativeSnapshotTool",
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
            ]
        ),
        .executableTarget(
            name: "WallpaperEngine",
            dependencies: ["NativeSceneCore", "NativeSceneBridge", "NativeSceneCompatibility", "NativeSceneRuntime", "NativeSceneRenderer"],
            path: "Sources/WallpaperEngine",
            exclude: ["WallpaperEngineInfo.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/WallpaperEngine/WallpaperEngineInfo.plist",
                    "-L\(buildRoot)/glslang/glslang",
                    "-L\(buildRoot)/glslang/glslang/OSDependent/Unix",
                    "-L\(buildRoot)/glslang/SPIRV",
                    "-L\(buildRoot)/spirv-cross",
                    "-L\(buildRoot)/quickjs",
                    "-L/opt/homebrew/lib",
                    "-L/usr/local/lib",
                ]),
            ]
        )
    ]
)
