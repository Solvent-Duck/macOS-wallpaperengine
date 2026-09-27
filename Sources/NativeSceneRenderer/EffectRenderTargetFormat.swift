import Metal

/// Numerical storage for authored effect buffers, independent of image codecs.
enum EffectRenderTargetFormat: String {
    case r8
    case rg88
    case rgba8888
    case r16f
    case rg1616f
    case rgb161616f
    case rgba16161616f
    case backbuffer = "rgba_backbuffer"

    func pixelFormat(backbuffer: MTLPixelFormat) -> MTLPixelFormat {
        switch self {
        case .r8: .r8Unorm
        case .rg88: .rg8Unorm
        case .rgba8888: .rgba8Unorm
        case .r16f: .r16Float
        case .rg1616f: .rg16Float
        case .rgb161616f, .rgba16161616f: .rgba16Float
        case .backbuffer: backbuffer
        }
    }

    // Metal has no ordinary RGB16Float attachment. Ignore the backing alpha
    // channel on reads so RGB targets retain their absent-alpha semantics.
    var alphaSwizzle: MTLTextureSwizzle { self == .rgb161616f ? .one : .alpha }
}
