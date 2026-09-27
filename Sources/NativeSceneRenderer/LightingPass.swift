import Foundation
import Metal
import NativeSceneRuntime

struct LightingPass {
    func prepare(packet: FramePacket, encoder: MTLRenderCommandEncoder) throws {
        _ = packet
        _ = encoder
        // Shared light buffers have not been split into a dedicated pass yet.
        // MaterialBinder now resolves authored light uniforms directly from the frame packet.
    }
}
