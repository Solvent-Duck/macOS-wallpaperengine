import Foundation
import NativeSceneCore
import simd

/// The 2D renderer and pointer unprojection must use the same camera convention.
public enum SceneCameraGeometry {
    public static func worldPosition(normalized: RuntimeVector2, scene: SceneDescription,
                                     viewportSize: CGSize, cameraZoom: Float) -> RuntimeVector2? {
        guard scene.scene?.camera.projection.isPerspective != true else { return nil }
        let matrix = projectionMatrix(scene: scene, viewportSize: viewportSize, cameraZoom: cameraZoom)
            * sceneCoordinateConversion(scene: scene, viewportSize: viewportSize)
        let determinant = simd_determinant(matrix)
        guard determinant.isFinite, determinant != 0 else { return nil }
        let inverse = simd_inverse(matrix)
        let clip = SIMD2<Float>(normalized.x * 2 - 1, normalized.y * 2 - 1)
        let a = inverse * SIMD4<Float>(clip.x, clip.y, 0, 1)
        let b = inverse * SIMD4<Float>(clip.x, clip.y, 1, 1)
        guard abs(a.w) > 1e-8, abs(b.w) > 1e-8 else { return nil }
        let near = SIMD3<Float>(a.x, a.y, a.z) / a.w
        let far = SIMD3<Float>(b.x, b.y, b.z) / b.w
        let direction = far - near
        guard abs(direction.z) > 1e-8 else { return nil }
        let point = near - direction * (near.z / direction.z)
        guard point.x.isFinite, point.y.isFinite else { return nil }
        return RuntimeVector2(x: point.x, y: point.y)
    }

    public static func cameraViewMatrix(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let forward = center - eye
        let z = simd_length_squared(forward) > 1e-12 ? -simd_normalize(forward) : SIMD3<Float>(0, 0, 1)
        var right = simd_cross(up, z)
        if simd_length_squared(right) <= 1e-12 {
            let fallbackUp = abs(z.y) < 0.99 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
            right = simd_cross(fallbackUp, z)
        }
        let x = simd_normalize(right)
        let y = simd_cross(z, x)
        return simd_float4x4(SIMD4(x.x, y.x, z.x, 0), SIMD4(x.y, y.y, z.y, 0), SIMD4(x.z, y.z, z.z, 0),
            SIMD4(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1))
    }

    public static func projectionMatrix(scene: SceneDescription, viewportSize: CGSize, cameraZoom: Float) -> simd_float4x4 {
        let projectionSize = resolvedProjectionSize(scene: scene, viewportSize: viewportSize)
        let width = Float(projectionSize.width)
        let height = Float(projectionSize.height)
        let nearZ = Float(scene.scene?.camera.projection.nearZ ?? -1)
        let farZ = Float(scene.scene?.camera.projection.farZ ?? 1)
        // Mirror the reference implementation (linux-wallpaperengine Camera.cpp):
        // positive nearZ clips z=0 geometry since NDC z would be negative (outside Metal's [0,1] range).
        let clampedNearZ = nearZ > 0 ? -nearZ : nearZ
        let zoom: Float = scene.scene?.camera.projection.isPerspective == true ? 1 : cameraZoom
        let ortho = simd_float4x4(
            SIMD4<Float>(2 * zoom / width, 0, 0, 0),
            SIMD4<Float>(0, 2 * zoom / height, 0, 0),
            SIMD4<Float>(0, 0, 1 / max(farZ - clampedNearZ, 0.0001), 0),
            SIMD4<Float>(0, 0, -clampedNearZ / max(farZ - clampedNearZ, 0.0001), 1)
        )
        // The reference 2D projection includes an eye translation, paired
        // with the camera's look-at view in CImage/CParticle. Omitting that
        // view leaves an unintended offset and ignores camera roll.
        let eye = scene.scene?.camera.configuration.eye ?? [0, 0, 0]
        let resolvedEye = RuntimeVector3(eye, default: RuntimeVector3(x: 0, y: 0, z: 0))
        let eyeTranslation = simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(resolvedEye.x, resolvedEye.y, resolvedEye.z, 1)
        )
        let configuration = scene.scene?.camera.configuration
        let center = RuntimeVector3(configuration?.center ?? [0, 0, -1], default: RuntimeVector3(x: 0, y: 0, z: -1))
        let up = RuntimeVector3(configuration?.up ?? [0, 1, 0], default: RuntimeVector3(x: 0, y: 1, z: 0))
        let view = Self.cameraViewMatrix(eye: resolvedEye.simdValue, center: center.simdValue, up: up.simdValue)
        return ortho * eyeTranslation * view
    }

    public static func sceneCoordinateConversion(scene: SceneDescription, viewportSize: CGSize) -> simd_float4x4 {
        let projectionSize = resolvedProjectionSize(scene: scene, viewportSize: viewportSize)
        let width = Float(projectionSize.width)
        let height = Float(projectionSize.height)
        // Wallpaper Engine scene coordinates are Y-up. Metal's viewport
        // maps positive clip Y to the top row, so no scene-axis flip is needed.
        return simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(-width / 2, -height / 2, 0, 1)
        )
    }

    public static func resolvedProjectionSize(scene: SceneDescription, viewportSize: CGSize) -> CGSize {
        let projection = scene.scene?.camera.projection
        let width = projection.map { $0.isAuto || $0.width <= 0 ? Int(viewportSize.width) : $0.width } ?? Int(viewportSize.width)
        let height = projection.map { $0.isAuto || $0.height <= 0 ? Int(viewportSize.height) : $0.height } ?? Int(viewportSize.height)
        return CGSize(width: max(width, 1), height: max(height, 1))
    }

}
