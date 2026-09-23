import CoreMedia
import Metal
import QuartzCore
import RealityKit
import os

/// Taps RealityKit's finished frame for both the screen and the recorder.
///
/// RealityKit's post-process callback hands back the composited frame — camera
/// passthrough and rendered 3D content together — as a texture, plus a live
/// command buffer. That single hook is why recording here is cheap: we never
/// composite camera and 3D ourselves, never convert YCbCr, and never fight
/// `displayTransform`. The texture arrives in display orientation.
///
/// Threading: the callback runs on RealityKit's render thread, never main.
/// Everything main touches goes through the lock; everything else in here is
/// render-thread-only and marked as such.
final class PostProcessFrameSource {

    /// Encode size. Portrait, and independent of the drawable, which is an
    /// awkward shape and larger than is worth encoding.
    static let recordSize = (width: 1080, height: 1920)

    private struct Settings {
        var tintEnabled = false
        var isRecording = false
        var minimumFrameInterval: Double = 1.0 / 60.0
    }

    private let device: MTLDevice
    private let compositePipeline: MTLComputePipelineState
    private let downscalePipeline: MTLComputePipelineState
    private let recorder: VideoRecorder
    private let settings = OSAllocatedUnfairLock(initialState: Settings())

    // MARK: Render thread only

    private var workTexture: MTLTexture?
    private var frameTap: FrameTap?
    private var lastCaptureTime: CFTimeInterval = 0

    // MARK: Setup

    init?(arView: ARView, recorder: VideoRecorder) {
        guard let device = arView.device ?? MTLCreateSystemDefaultDevice(),
              let library = device.makeDefaultLibrary(),
              let compositeFunction = library.makeFunction(name: "composite"),
              let downscaleFunction = library.makeFunction(name: "downscaleToRecord"),
              let compositePipeline = try? device.makeComputePipelineState(function: compositeFunction),
              let downscalePipeline = try? device.makeComputePipelineState(function: downscaleFunction)
        else { return nil }

        self.device = device
        self.compositePipeline = compositePipeline
        self.downscalePipeline = downscalePipeline
        self.recorder = recorder

        arView.renderCallbacks.postProcess = { [weak self] context in
            self?.encode(context)
        }
    }

    // MARK: Main-thread API

    /// M1 spike. Tints the composited frame red to reveal whether the source
    /// texture includes camera passthrough. Remove once that is settled.
    func setTintEnabled(_ enabled: Bool) {
        settings.withLock { $0.tintEnabled = enabled }
    }

    func setRecording(_ recording: Bool) {
        settings.withLock { $0.isRecording = recording }
    }

    func setTargetFrameRate(_ fps: Double) {
        let clamped = max(1, fps)
        settings.withLock { $0.minimumFrameInterval = 1.0 / clamped }
    }

    // MARK: Render thread

    private func encode(_ context: ARView.PostProcessContext) {
        let current = settings.withLock { $0 }
        let now = CACurrentMediaTime()

        // The callback fires at display refresh, up to 120Hz on ProMotion,
        // while face tracking runs at 60. Appending every callback would write
        // duplicate frames and wreck the bitrate, so gate on elapsed time.
        let wantsFrame = current.isRecording
            && (now - lastCaptureTime) >= (current.minimumFrameInterval - 0.001)

        let work = wantsFrame ? workTexture(matching: context.targetColorTexture) : nil

        guard let encoder = context.commandBuffer.makeComputeCommandEncoder() else { return }
        var tint = Float(current.tintEnabled ? 1 : 0)
        encoder.setComputePipelineState(compositePipeline)
        encoder.setTexture(context.sourceColorTexture, index: 0)
        encoder.setTexture(context.targetColorTexture, index: 1)
        encoder.setTexture(work, index: 2)
        encoder.setBytes(&tint, length: MemoryLayout<Float>.size, index: 0)
        dispatch(
            encoder,
            pipeline: compositePipeline,
            width: context.targetColorTexture.width,
            height: context.targetColorTexture.height
        )
        encoder.endEncoding()

        guard wantsFrame,
              let work,
              let tap = frameTap(for: device),
              let slot = tap.nextSlot()
        else { return }

        // A nil slot means the pool is exhausted and the encoder is behind.
        // Dropping the frame is correct; blocking the render thread is not.
        lastCaptureTime = now

        guard let downscaleEncoder = context.commandBuffer.makeComputeCommandEncoder() else { return }
        downscaleEncoder.setComputePipelineState(downscalePipeline)
        downscaleEncoder.setTexture(work, index: 0)
        downscaleEncoder.setTexture(slot.texture, index: 1)
        dispatch(
            downscaleEncoder,
            pipeline: downscalePipeline,
            width: tap.width,
            height: tap.height
        )
        downscaleEncoder.endEncoding()

        // `CACurrentMediaTime` is the host clock, the same domain ARKit's audio
        // sample buffers are stamped in, so video and audio line up without
        // any conversion.
        let presentationTime = CMTime(seconds: now, preferredTimescale: 1_000_000_000)
        let recorder = self.recorder

        context.commandBuffer.addCompletedHandler { _ in
            // Capturing `slot` holds the CVMetalTexture until the GPU is done.
            // Releasing it earlier would let the pool recycle a buffer that is
            // still being written.
            recorder.appendVideo(slot.pixelBuffer, at: presentationTime)
        }
    }

    private func dispatch(
        _ encoder: MTLComputeCommandEncoder,
        pipeline: MTLComputePipelineState,
        width: Int,
        height: Int
    ) {
        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = max(1, pipeline.maxTotalThreadsPerThreadgroup / threadWidth)
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        )
    }

    private func workTexture(matching texture: MTLTexture) -> MTLTexture? {
        if let existing = workTexture,
           existing.width == texture.width,
           existing.height == texture.height {
            return existing
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: texture.width,
            height: texture.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        workTexture = device.makeTexture(descriptor: descriptor)
        return workTexture
    }

    private func frameTap(for device: MTLDevice) -> FrameTap? {
        if let frameTap { return frameTap }
        frameTap = FrameTap(
            device: device,
            width: Self.recordSize.width,
            height: Self.recordSize.height
        )
        return frameTap
    }
}
