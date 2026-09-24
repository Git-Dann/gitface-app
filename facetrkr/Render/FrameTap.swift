import CoreVideo
import Metal

/// Supplies pooled, Metal-writable pixel buffers for the recorder.
///
/// Buffers come from a `CVPixelBufferPool` rather than being allocated per
/// frame, and are IOSurface-backed so the GPU can write them without a copy.
final class FrameTap {

    /// A pixel buffer and the Metal texture that views it.
    ///
    /// `metalTexture` must be held until the GPU has finished with it.
    /// `CVMetalTextureCacheCreateTextureFromImage` bumps the buffer's use count,
    /// and dropping the reference early lets the pool recycle a buffer that is
    /// still being written.
    ///
    /// `@unchecked Sendable` because handing this to a command-buffer
    /// completion handler is the type's entire purpose: it is created on the
    /// render thread and consumed once the GPU finishes. The three members are
    /// thread-safe references; what is not checkable is that only one slot
    /// refers to a given buffer at a time, and the pool is what guarantees it.
    struct Slot: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let metalTexture: CVMetalTexture
        let texture: MTLTexture
    }

    let width: Int
    let height: Int

    private let pool: CVPixelBufferPool
    private let textureCache: CVMetalTextureCache

    init?(device: MTLDevice, width: Int, height: Int) {
        self.width = width
        self.height = height

        let bufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 6
        ]

        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                poolAttributes as CFDictionary,
                bufferAttributes as CFDictionary,
                &pool) == kCVReturnSuccess,
              let pool
        else { return nil }
        self.pool = pool

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(
                kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache
        else { return nil }
        self.textureCache = cache
    }

    /// Dequeues the next writable slot, or nil if the pool is exhausted.
    ///
    /// Exhaustion means the encoder is falling behind. Returning nil so the
    /// caller drops the frame is correct; blocking the render thread is not.
    func nextSlot() -> Slot? {
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(
                kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer
        else { return nil }

        var metalTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                textureCache,
                pixelBuffer,
                nil,
                .bgra8Unorm,
                width,
                height,
                0,
                &metalTexture) == kCVReturnSuccess,
              let metalTexture,
              let texture = CVMetalTextureGetTexture(metalTexture)
        else { return nil }

        return Slot(pixelBuffer: pixelBuffer, metalTexture: metalTexture, texture: texture)
    }

    func flush() {
        CVMetalTextureCacheFlush(textureCache, 0)
    }
}
