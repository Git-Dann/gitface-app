import Metal
import RealityKit
import os

/// M1 spike: proves what `sourceColorTexture` actually contains.
///
/// The whole recording architecture rests on one inferred claim — that the
/// post-process source texture is the *composited* frame, camera passthrough
/// included. That comes from a WWDC21 example, not from documentation, so it
/// gets verified on day one rather than in week three.
///
/// Toggle the tint on device:
///   - camera feed turns red  → passthrough is included, architecture holds.
///   - only the cube turns red → fall back to compositing `ARFrame.capturedImage`
///     ourselves, and recording gets substantially more expensive.
///
/// This class is also the shape every later effect takes, so the threading
/// rules are established here:
///   1. Always write `targetColorTexture`. Skip it and the screen goes black.
///   2. The closure runs on RealityKit's render thread, never main. It must not
///      block and must not touch `@Published` state — hence the unfair lock.
final class PostProcessSpike {

    private let pipeline: MTLComputePipelineState
    private let tintEnabled = OSAllocatedUnfairLock(initialState: false)

    init?(arView: ARView) {
        guard let device = arView.device ?? MTLCreateSystemDefaultDevice(),
              let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "spikeTint"),
              let pipeline = try? device.makeComputePipelineState(function: function)
        else { return nil }

        self.pipeline = pipeline

        arView.renderCallbacks.postProcess = { [weak self] context in
            self?.encode(context)
        }
    }

    func setTintEnabled(_ enabled: Bool) {
        tintEnabled.withLock { $0 = enabled }
    }

    private func encode(_ context: ARView.PostProcessContext) {
        guard let encoder = context.commandBuffer.makeComputeCommandEncoder() else { return }

        var tint: Float = tintEnabled.withLock { $0 } ? 1 : 0

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(context.sourceColorTexture, index: 0)
        encoder.setTexture(context.targetColorTexture, index: 1)
        encoder.setBytes(&tint, length: MemoryLayout<Float>.size, index: 0)

        let width = pipeline.threadExecutionWidth
        let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
        encoder.dispatchThreads(
            MTLSize(width: context.targetColorTexture.width,
                    height: context.targetColorTexture.height,
                    depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1)
        )
        encoder.endEncoding()
    }
}
