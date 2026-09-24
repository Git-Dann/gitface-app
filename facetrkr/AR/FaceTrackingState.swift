import CoreGraphics
import Foundation

/// What the AR session needs the view layer to be able to ask of it.
///
/// Keeps `FaceTrackingState` free of any reference to `ARView`, so the view
/// model stays testable and the coordinator stays the only thing that knows
/// about ARKit.
@MainActor
protocol FaceSessionControlling: AnyObject {
    func setRecordingActive(_ active: Bool)
    func setTintEnabled(_ enabled: Bool)
    func setTargetFrameRate(_ fps: Double)
    func setWarpStyle(_ style: WarpStyle)
    func setViewportSize(_ size: CGSize)
    func applyMask(_ mask: Mask)
}

/// UI state and user intent for the whole app.
///
/// Main actor throughout. The render thread never reads this — it goes through
/// the lock inside `PostProcessFrameSource` instead.
@MainActor
final class FaceTrackingState: ObservableObject {

    enum Status: Equatable {
        case starting
        case unsupported
        case searching
        case tracking
        case failed(String)

        var message: String {
            switch self {
            case .starting:        "Starting camera…"
            case .unsupported:     "This device can't do face tracking."
            case .searching:       "Looking for a face…"
            case .tracking:        "Tracking"
            case .failed(let why): why
            }
        }
    }

    enum Recording: Equatable {
        case idle
        case recording
        case saving
    }

    @Published private(set) var status: Status = .starting
    @Published private(set) var recording: Recording = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lastSavedURL: URL?
    @Published private(set) var isThermallyThrottled = false
    @Published var errorMessage: String?

    /// Selecting a mask that carries a warp applies both. That pairing is what
    /// turns a pile of props into a lens: the reference look is the warp and
    /// the props together, and neither reads without the other.
    @Published var selectedMask: Mask = MaskLibrary.default {
        didSet {
            controller?.applyMask(selectedMask)
            if let warp = selectedMask.warp { selectedWarp = warp }
        }
    }

    @Published var selectedWarp: WarpStyle = .none {
        didSet { controller?.setWarpStyle(selectedWarp) }
    }

    /// M1 spike toggle. Remove once the passthrough question is settled.
    @Published var isTintSpikeEnabled = false {
        didSet { controller?.setTintEnabled(isTintSpikeEnabled) }
    }

    weak var controller: FaceSessionControlling?

    let recorder = VideoRecorder()

    private var ticker: Task<Void, Never>?
    private var thermalObservation: Task<Void, Never>?

    var isSupported: Bool { status != .unsupported }
    var canRecord: Bool { status == .tracking || status == .searching }
    var maximumDuration: TimeInterval { VideoRecorder.maximumDuration }

    // MARK: - Session feedback

    /// Called once the AR view has a real size, so landmark projection can
    /// convert to normalised screen space.
    func viewportChanged(to size: CGSize) {
        controller?.setViewportSize(size)
    }

    /// Follows thermal state so a long clip degrades to a lower frame rate
    /// rather than stuttering at a higher one.
    func startThermalTracking() {
        guard thermalObservation == nil else { return }
        controller?.setTargetFrameRate(ThermalGovernor.targetFrameRate)
        isThermallyThrottled = ThermalGovernor.isThrottled
        thermalObservation = Task { [weak self] in
            var last: ProcessInfo.ThermalState?
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                let current = ThermalGovernor.state
                guard current != last else { continue }
                last = current
                self.isThermallyThrottled = ThermalGovernor.isThrottled
                self.controller?.setTargetFrameRate(ThermalGovernor.targetFrameRate)
            }
        }
    }

    func update(to status: Status) {
        guard self.status != status else { return }
        self.status = status
    }

    // MARK: - Recording

    func toggleRecording() {
        switch recording {
        case .idle:      startRecording()
        case .recording: Task { await stopRecording() }
        case .saving:    break
        }
    }

    private func startRecording() {
        do {
            _ = try recorder.start(
                width: PostProcessFrameSource.recordSize.width,
                height: PostProcessFrameSource.recordSize.height
            )
            controller?.setRecordingActive(true)
            recording = .recording
            elapsed = 0
            startTicker()
        } catch {
            errorMessage = error.localizedDescription
            recorder.cancel()
        }
    }

    private func stopRecording() async {
        guard recording == .recording else { return }

        controller?.setRecordingActive(false)
        stopTicker()
        recording = .saving

        do {
            let url = try await recorder.finish()
            try await MediaSaver.saveToPhotoLibrary(url)
            lastSavedURL = url
        } catch {
            errorMessage = error.localizedDescription
        }

        recording = .idle
        elapsed = 0
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self else { return }
                guard self.recording == .recording else { return }

                self.elapsed += 0.1
                if self.elapsed >= self.maximumDuration {
                    await self.stopRecording()
                    return
                }
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }
}
