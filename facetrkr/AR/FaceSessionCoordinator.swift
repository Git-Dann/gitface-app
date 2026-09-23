import ARKit
import AVFAudio
import CoreMedia
import RealityKit

/// Owns the ARKit face-tracking session and everything hanging off it.
///
/// `ARView` rather than `RealityView`: blendshape coefficients only ever arrive
/// through `ARSessionDelegate`, and `ARView` exposes `.session` directly.
/// `RealityView` plus `SpatialTrackingSession` makes reaching the underlying
/// anchor data awkward, which matters as soon as expression-driven effects
/// arrive.
final class FaceSessionCoordinator: NSObject, ARSessionDelegate, FaceSessionControlling {

    private let state: FaceTrackingState

    /// Held directly rather than reached through `state`, because audio
    /// buffers arrive on ARKit's delegate queue and `state` is main-actor.
    private let recorder: VideoRecorder
    private weak var arView: ARView?
    private var frameSource: PostProcessFrameSource?

    private var faceAnchor: AnchorEntity?
    private var maskRoot: Entity?
    private var occlusionAdded = false
    private var wasTracked = false

    init(state: FaceTrackingState, recorder: VideoRecorder) {
        self.state = state
        self.recorder = recorder
        super.init()
    }

    // MARK: - Lifecycle

    @MainActor
    func attach(to arView: ARView) {
        self.arView = arView
        state.controller = self

        // Never branch on hardware. Face tracking has run on any Neural Engine
        // device since iOS 14, and 2026 models ship without TrueDepth entirely.
        guard ARFaceTrackingConfiguration.isSupported else {
            state.update(to: .unsupported)
            return
        }

        logSupportedVideoFormats()
        configureAudioSession()

        arView.session.delegate = self
        arView.automaticallyConfigureSession = false
        arView.renderOptions.insert(.disableMotionBlur)
        arView.renderOptions.insert(.disableDepthOfField)

        installAnchor(in: arView)
        frameSource = PostProcessFrameSource(arView: arView, recorder: recorder)

        run(on: arView.session)
        state.update(to: .searching)
    }

    @MainActor
    func detach() {
        arView?.session.pause()
        arView?.session.delegate = nil
        arView?.renderCallbacks.postProcess = nil
        frameSource = nil
        state.controller = nil
    }

    private func run(on session: ARSession) {
        let configuration = ARFaceTrackingConfiguration()
        configuration.maximumNumberOfTrackedFaces = 1
        configuration.isLightEstimationEnabled = true

        // Audio on the same clock as the video frames, which is the whole
        // reason for taking it from ARKit rather than a separate capture
        // session.
        configuration.providesAudioData = true

        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    /// Must be active before the session starts, or the mic route is wrong.
    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .videoRecording,
                options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth]
            )
            try session.setActive(true)
        } catch {
            print("[facetrkr] audio session setup failed: \(error.localizedDescription)")
        }
    }

    // MARK: - FaceSessionControlling

    @MainActor
    func setRecordingActive(_ active: Bool) {
        frameSource?.setRecording(active)
    }

    @MainActor
    func setTintEnabled(_ enabled: Bool) {
        frameSource?.setTintEnabled(enabled)
    }

    @MainActor
    func applyMask(_ mask: Mask) {
        guard let maskRoot else { return }
        maskRoot.children.removeAll()
        maskRoot.addChild(mask.build())
    }

    // MARK: - Scene

    @MainActor
    private func installAnchor(in arView: ARView) {
        let anchor = AnchorEntity(.face)

        // Masks live under their own node so switching is a child swap rather
        // than tearing down and re-adding the anchor, which would drop tracking
        // for a frame.
        let root = Entity()
        anchor.addChild(root)
        arView.scene.addAnchor(anchor)

        faceAnchor = anchor
        maskRoot = root
        root.addChild(state.selectedMask.build())
    }

    /// The only public figure for face-tracking capture resolution is 720p-only
    /// and dates from 2018. It caps recording quality, so log what this device
    /// actually offers rather than assuming.
    private func logSupportedVideoFormats() {
        for format in ARFaceTrackingConfiguration.supportedVideoFormats {
            let size = format.imageResolution
            print("[facetrkr] face video format: \(Int(size.width))x\(Int(size.height)) @ \(format.framesPerSecond)fps")
        }
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard let face = anchors.lazy.compactMap({ $0 as? ARFaceAnchor }).first else { return }

        if !occlusionAdded, face.isTracked {
            occlusionAdded = true
            let geometry = face.geometry
            Task { @MainActor [weak self] in
                guard let self, let anchor = self.faceAnchor,
                      let occlusion = FaceOcclusion.makeEntity(from: geometry) else { return }
                anchor.addChild(occlusion)
            }
        }

        // Fires at 60Hz, so only hop to the main actor when it actually changes.
        guard face.isTracked != wasTracked else { return }
        wasTracked = face.isTracked
        let tracked = face.isTracked
        Task { @MainActor [weak self] in
            self?.state.update(to: tracked ? .tracking : .searching)
        }
    }

    func session(_ session: ARSession, didOutputAudioSampleBuffer audioSampleBuffer: CMSampleBuffer) {
        recorder.appendAudio(audioSampleBuffer)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        let message = (error as NSError).localizedDescription
        Task { @MainActor [weak self] in self?.state.update(to: .failed(message)) }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor [weak self] in self?.state.update(to: .searching) }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        guard let session = arView?.session else { return }
        occlusionAdded = false
        run(on: session)
    }
}
