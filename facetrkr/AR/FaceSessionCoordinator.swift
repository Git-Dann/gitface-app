import ARKit
import AVFAudio
import CoreMedia
import RealityKit
import UIKit
import os

/// Owns the ARKit face-tracking session and everything hanging off it.
///
/// `ARView` rather than `RealityView`: blendshape coefficients only ever arrive
/// through `ARSessionDelegate`, and `ARView` exposes `.session` directly.
/// `RealityView` plus `SpatialTrackingSession` makes reaching the underlying
/// anchor data awkward, which matters now that expression-driven effects read
/// those coefficients every frame.
final class FaceSessionCoordinator: NSObject, ARSessionDelegate, FaceSessionControlling {

    private let state: FaceTrackingState

    /// Held directly rather than reached through `state`, because audio
    /// buffers arrive on ARKit's delegate queue and `state` is main-actor.
    private let recorder: VideoRecorder

    /// ARKit's delegate queue reads these while the main actor writes them,
    /// so they are behind locks rather than plain properties.
    /// `uncheckedState` because `PostProcessFrameSource` isn't Sendable. The
    /// lock is what makes the access safe, which is exactly what that
    /// initialiser is for.
    private let frameSource = OSAllocatedUnfairLock<PostProcessFrameSource?>(uncheckedState: nil)
    private let warpStyle = OSAllocatedUnfairLock(initialState: WarpStyle.none)
    private let viewport = OSAllocatedUnfairLock(initialState: CGSize.zero)

    /// Written from ARKit's delegate queue, so not plain stored properties.
    private let tracking = OSAllocatedUnfairLock(initialState: TrackingFlags())

    private struct TrackingFlags {
        var wasTracked = false
        var occlusionAdded = false
    }

    // Main actor only, by way of the class's isolation.
    private weak var arView: ARView?
    private var faceAnchor: AnchorEntity?
    private var maskRoot: Entity?

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
        arView.renderOptions.insert(.disableMotionBlur)
        arView.renderOptions.insert(.disableDepthOfField)

        installAnchor(in: arView)
        // Built before the lock is taken. The initialiser is main-actor
        // isolated (it assigns renderCallbacks) and `attach` is already there,
        // but a `withLock` closure is nonisolated, so constructing inside it
        // would be calling across actors. Shorter critical section either way.
        let source = PostProcessFrameSource(arView: arView, recorder: recorder)
        frameSource.withLock { $0 = source }

        run(on: arView.session)
        state.update(to: .searching)
    }

    @MainActor
    func detach() {
        arView?.session.pause()
        arView?.session.delegate = nil
        arView?.renderCallbacks.postProcess = nil
        frameSource.withLock { $0 = nil }
        state.controller = nil
    }

    nonisolated private func run(on session: ARSession) {
        let configuration = ARFaceTrackingConfiguration()
        configuration.maximumNumberOfTrackedFaces = 1
        configuration.isLightEstimationEnabled = true

        // Audio on the same clock as the video frames, which is the whole
        // reason for taking it from ARKit rather than a separate capture
        // session.
        configuration.providesAudioData = true

        if let format = Self.preferredVideoFormat() {
            configuration.videoFormat = format
            let size = format.imageResolution
            print("[facetrkr] using \(Int(size.width))x\(Int(size.height)) @ \(format.framesPerSecond)fps")
        }

        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    /// Picks the capture format rather than accepting ARKit's default.
    ///
    /// The default is conservative, and passthrough resolution is the ceiling
    /// on recording quality: whatever the camera hands RealityKit is what ends
    /// up in the encoder. A 2026 iPhone offers 1920x1080 at 60fps, which in
    /// portrait is exactly the 1080x1920 encode size, so taking the default
    /// would mean recording a softer image than the hardware can produce.
    ///
    /// Frame rate wins over resolution: 60fps matters more than extra pixels
    /// for a face that moves, and the 4:3 formats would be cropped to portrait
    /// 16:9 anyway. Falls back to the largest format if nothing offers 60.
    nonisolated private static func preferredVideoFormat() -> ARConfiguration.VideoFormat? {
        let formats = ARFaceTrackingConfiguration.supportedVideoFormats

        func pixels(_ format: ARConfiguration.VideoFormat) -> CGFloat {
            format.imageResolution.width * format.imageResolution.height
        }

        let fast = formats.filter { $0.framesPerSecond >= 60 }
        return (fast.isEmpty ? formats : fast).max { pixels($0) < pixels($1) }
    }

    /// Must be active before the session starts, or the mic route is wrong.
    nonisolated private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .videoRecording,
                // No Bluetooth option on purpose. Routing to an HFP headset
                // would hand us a narrowband mic, which is the wrong trade for
                // recording, and the non-deprecated spelling is iOS 26 only.
                options: [.mixWithOthers, .defaultToSpeaker]
            )
            try session.setActive(true)
        } catch {
            print("[facetrkr] audio session setup failed: \(error.localizedDescription)")
        }
    }

    // MARK: - FaceSessionControlling

    @MainActor
    func setRecordingActive(_ active: Bool) {
        frameSource.withLock { $0?.setRecording(active) }
    }

    @MainActor
    func setTintEnabled(_ enabled: Bool) {
        frameSource.withLock { $0?.setTintEnabled(enabled) }
    }

    @MainActor
    func setTargetFrameRate(_ fps: Double) {
        frameSource.withLock { $0?.setTargetFrameRate(fps) }
    }

    @MainActor
    func setWarpStyle(_ style: WarpStyle) {
        warpStyle.withLock { $0 = style }
        // Clear immediately so switching to "off" takes effect even if tracking
        // has dropped and no frame update is coming to rebuild the regions.
        if style.specs.isEmpty {
            frameSource.withLock { $0?.clearWarp() }
        }
    }

    @MainActor
    func setViewportSize(_ size: CGSize) {
        viewport.withLock { $0 = size }
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
    nonisolated private func logSupportedVideoFormats() {
        for format in ARFaceTrackingConfiguration.supportedVideoFormats {
            let size = format.imageResolution
            print("[facetrkr] face video format: \(Int(size.width))x\(Int(size.height)) @ \(format.framesPerSecond)fps")
        }
    }

    // MARK: - ARSessionDelegate

    /// Projects the warp anchors to screen space and rebuilds the regions.
    ///
    /// Uses `ARCamera.projectPoint` rather than `ARView.project` so this can
    /// stay on ARKit's delegate queue instead of hopping to the main actor 60
    /// times a second.
    ///
    /// Everything is derived from ARKit's real eye transforms rather than fixed
    /// constants: cheeks and mouth are offsets from the eyes measured in eye
    /// spans, and every radius scales with the projected eye separation. That
    /// makes a warp land in the same place on any face at any distance, which
    /// fixed screen-space numbers cannot do.
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let face = frame.anchors.lazy.compactMap({ $0 as? ARFaceAnchor }).first,
              face.isTracked
        else {
            // Otherwise the last frame's distortion stays frozen on screen.
            frameSource.withLock { $0?.clearWarp() }
            return
        }

        let size = viewport.withLock { $0 }
        guard size.width > 1, size.height > 1 else { return }

        let style = warpStyle.withLock { $0 }
        guard !style.specs.isEmpty else {
            frameSource.withLock { $0?.clearWarp() }
            return
        }

        let camera = frame.camera
        func project(_ local: SIMD3<Float>) -> SIMD2<Float> {
            let world = face.transform * SIMD4<Float>(local.x, local.y, local.z, 1)
            let point = camera.projectPoint(
                SIMD3<Float>(world.x, world.y, world.z),
                orientation: .portrait,
                viewportSize: size
            )
            return SIMD2<Float>(Float(point.x / size.width), Float(point.y / size.height))
        }

        func position(_ transform: simd_float4x4) -> SIMD3<Float> {
            SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        }

        let leftEye = position(face.leftEyeTransform)
        let rightEye = position(face.rightEyeTransform)
        let eyeMid = (leftEye + rightEye) / 2
        let eyeSpan = max(0.001, simd_distance(leftEye, rightEye))

        // Offsets are taken from each eye outward rather than from a signed X
        // axis, so nothing here depends on which way the anchor's X points.
        func cheek(of eye: SIMD3<Float>) -> SIMD3<Float> {
            eye + (eye - eyeMid) * 0.22 + SIMD3(0, -0.58, 0.26) * eyeSpan
        }

        let leftEyeScreen = project(leftEye)
        let rightEyeScreen = project(rightEye)
        let leftCheekScreen = project(cheek(of: leftEye))
        let rightCheekScreen = project(cheek(of: rightEye))
        let mouthScreen = project(eyeMid + SIMD3(0, -1.15, 0.38) * eyeSpan)
        let centreScreen = project(eyeMid + SIMD3(0, -0.40, 0.10) * eyeSpan)

        func point(_ anchor: WarpAnchor) -> SIMD2<Float> {
            switch anchor {
            case .leftEye:    leftEyeScreen
            case .rightEye:   rightEyeScreen
            case .leftCheek:  leftCheekScreen
            case .rightCheek: rightCheekScreen
            case .mouth:      mouthScreen
            case .faceCentre: centreScreen
            }
        }

        // The one measurement everything scales from.
        let span = max(0.01, simd_distance(leftEyeScreen, rightEyeScreen))
        let jawOpen = face.blendShapes[.jawOpen]?.floatValue ?? 0

        let regions = style.specs.prefix(FaceUniforms.maximumRegions).map { spec in
            WarpRegion(
                centre: point(spec.anchor),
                radius: spec.radius * span,
                kind: spec.kind.rawValue,
                weight: spec.jawDriven ? spec.weight * (0.55 + 0.45 * jawOpen) : spec.weight
            )
        }

        // Everything is computed before the lock is taken: this runs 60 times a
        // second and the render thread contends for the same lock.
        frameSource.withLock {
            $0?.setWarp(
                regions: Array(regions),
                hullCentre: centreScreen,
                hullRadius: span * 1.6
            )
        }
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard let face = anchors.lazy.compactMap({ $0 as? ARFaceAnchor }).first else { return }

        let shouldAddOcclusion = tracking.withLock { flags -> Bool in
            guard !flags.occlusionAdded, face.isTracked else { return false }
            flags.occlusionAdded = true
            return true
        }

        if shouldAddOcclusion {
            let geometry = face.geometry
            Task { @MainActor [weak self] in
                guard let self, let anchor = self.faceAnchor,
                      let occlusion = FaceOcclusion.makeEntity(from: geometry) else { return }
                anchor.addChild(occlusion)
            }
        }

        // Fires at 60Hz, so only hop to the main actor when it actually changes.
        let tracked = face.isTracked
        let changed = tracking.withLock { flags -> Bool in
            guard flags.wasTracked != tracked else { return false }
            flags.wasTracked = tracked
            return true
        }
        guard changed else { return }

        Task { @MainActor [weak self] in
            self?.state.update(to: tracked ? .tracking : .searching)
        }
    }

    nonisolated func session(_ session: ARSession, didOutputAudioSampleBuffer audioSampleBuffer: CMSampleBuffer) {
        recorder.appendAudio(audioSampleBuffer)
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let message = (error as NSError).localizedDescription
        Task { @MainActor [weak self] in self?.state.update(to: .failed(message)) }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor [weak self] in self?.state.update(to: .searching) }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        tracking.withLock { $0.occlusionAdded = false }
        run(on: session)
    }
}
