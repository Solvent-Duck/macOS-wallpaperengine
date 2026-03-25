// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "macOS-wallpaperengine",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CWEBridge",
            path: "Sources/CWEBridge",
            exclude: ["WEBridge.cpp"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
            ],
            linkerSettings: [
                .linkedLibrary("wallpaperengine"),
                .linkedLibrary("glfw"),
                .linkedLibrary("GLEW"),
                .linkedLibrary("SDL2"),
                .linkedLibrary("lz4"),
                .linkedLibrary("z"),
                .linkedLibrary("avformat"),
                .linkedLibrary("avcodec"),
                .linkedLibrary("avutil"),
                .linkedLibrary("swscale"),
                .linkedLibrary("swresample"),
                // Vendored glslang libraries
                .linkedLibrary("glslang"),
                .linkedLibrary("MachineIndependent"),
                .linkedLibrary("GenericCodeGen"),
                .linkedLibrary("glslang-default-resource-limits"),
                .linkedLibrary("OSDependent"),
                .linkedLibrary("SPIRV"),
                // Vendored SPIRV-Cross libraries
                .linkedLibrary("spirv-cross-core"),
                .linkedLibrary("spirv-cross-glsl"),
                // Other vendored libraries
                .linkedLibrary("kissfft-float"),
                .linkedLibrary("qjs"),
                .linkedLibrary("c++"),
                .linkedFramework("OpenGL"),
                .linkedFramework("GLUT"),
                .linkedFramework("Cocoa"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreVideo"),
                .unsafeFlags([
                    "-Lbuild/lib",
                    "-Lbuild",
                    "-Lbuild/glslang/glslang",
                    "-Lbuild/glslang/glslang/OSDependent/Unix",
                    "-Lbuild/glslang/SPIRV",
                    "-Lbuild/spirv-cross",
                    "-Lbuild/quickjs",
                    "-Lbuild/kissfft",
                    "-L/opt/homebrew/lib",
                    "-L/usr/local/lib",
                ]),
            ]
        ),
        .executableTarget(
            name: "WallpaperEngine",
            dependencies: ["CWEBridge"],
            path: "Sources/WallpaperEngine",
            linkerSettings: [
                .unsafeFlags([
                    "-Lbuild/lib",
                    "-Lbuild",
                    "-Lbuild/glslang/glslang",
                    "-Lbuild/glslang/glslang/OSDependent/Unix",
                    "-Lbuild/glslang/SPIRV",
                    "-Lbuild/spirv-cross",
                    "-Lbuild/quickjs",
                    "-Lbuild/kissfft",
                    "-L/opt/homebrew/lib",
                    "-L/usr/local/lib",
                ]),
            ]
        )
    ]
)
