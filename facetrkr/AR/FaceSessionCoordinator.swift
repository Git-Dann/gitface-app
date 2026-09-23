import ARKit
import RealityKit

/// Owns the ARKit face-tracking session and bridges it to SwiftUI.
///
/// `ARView` rather than `RealityView`: blendshape coefficients only ever arrive
/// through `ARSessionDelegate`, and `ARView` exposes `.session` directly.
/// `RealityView` + `SpatialTrackingSession` makes reaching the underlying
/// anchor data awkward.
final class FaceSessionCoordinator: NSObject, ARSessionDelegate {

    private let state: FaceTrackingState
    private weak var arView: ARView?
    private var spike: PostProcessSpike?
    private var wasTracked = false

    init(state: FaceTrackingState) {
        self.state = state
        super.init()
    }

    // MARK: - Lifecycle

    func attach(to arView: ARView) {
        self.arView = arView

        // Never assume TrueDepth. Face tracking runs on any Neural Engine
        // device since iOS 14, and some 2026 hardware ships without TrueDepth
        // entirely, so the hardware is the wrong thing to branch on.
        guard ARFaceTrackingConfiguration.isSupported else {
            Task { @MainActor in state.update(to: .unsupported) }
            return
        }

        logSupportedVideoFormats()

        arView.session.delegate = self
        addNoseMarker(to: arView)
        spike = PostProcessSpike(arView: arView)

        let config = ARFaceTrackingConfiguration()
        config.maximumNumberOfTrackedFaces = 1
        config.isLightEstimationEnabled = true
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])

        Task { @MainActor in state.update(to: .searching) }
    }

    func detach() {
        arView?.session.pause()
        arView?.session.delegate = nil
        arView?.renderCallbacks.postProcess = nil
        spike = nil
    }

    func setTintSpikeEnabled(_ enabled: Bool) {
        spike?.setTintEnabled(enabled)
    }

    // MARK: - M1 diagnostics

    /// The only public data point for face-tracking capture resolution is
    /// 720p-only, and it is from 2018. Log what this device actually offers
    /// before assuming anything about recording resolution.
    private func logSupportedVideoFormats() {
        for format in ARFaceTrackingConfiguration.supportedVideoFormats {
            let size = format.imageResolution
            print("[facetrkr] face video format: \(Int(size.width))x\(Int(size.height)) @ \(format.framesPerSecond)fps")
        }
    }

    /// A marker cube roughly at the nose tip. The face anchor's origin sits
    /// behind the nose with +Z pointing out of the face.
    private func addNoseMarker(to arView: ARView) {
        let anchor = AnchorEntity(.face)
        let marker = ModelEntity(
            mesh: .generateBox(size: 0.04, cornerRadius: 0.006),
            materials: [SimpleMaterial(color: .systemPink, roughness: 0.3, isMetallic: false)]
        )
        marker.position = [0, 0, 0.06]
        anchor.addChild(marker)
        arView.scene.addAnchor(anchor)
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard let face = anchors.lazy.compactMap({ $0 as? ARFaceAnchor }).first else { return }

        // Fires at 60 Hz, so only cross to the main actor when it actually changes.
        guard face.isTracked != wasTracked else { return }
        wasTracked = face.isTracked
        let tracked = face.isTracked
        Task { @MainActor in state.update(to: tracked ? .tracking : .searching) }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        let message = (error as NSError).localizedDescription
        Task { @MainActor in state.update(to: .failed(message)) }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor in state.update(to: .searching) }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        guard let arView else { return }
        let config = ARFaceTrackingConfiguration()
        config.maximumNumberOfTrackedFaces = 1
        config.isLightEstimationEnabled = true
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }
}
