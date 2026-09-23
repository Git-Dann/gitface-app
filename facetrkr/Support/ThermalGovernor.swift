import Foundation

/// Backs off the capture frame rate as the device heats up.
///
/// Front camera, Neural Engine face tracking, a Metal composite and an HEVC
/// encode are a sustained three-subsystem load. Rather than let the system
/// throttle unpredictably mid-clip, drop the recording frame rate on the way
/// up, so the result stays smooth at a lower rate instead of stuttering at a
/// higher one.
@MainActor
final class ThermalGovernor: ObservableObject {

    @Published private(set) var state: ProcessInfo.ThermalState = .nominal

    /// The frame rate recording should target right now.
    var targetFrameRate: Double {
        switch state {
        case .nominal, .fair: 60
        case .serious:        30
        case .critical:       24
        @unknown default:     30
        }
    }

    var isThrottled: Bool {
        state == .serious || state == .critical
    }

    private var observer: (any NSObjectProtocol)?

    init() {
        state = ProcessInfo.processInfo.thermalState
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let current = ProcessInfo.processInfo.thermalState
            Task { @MainActor in self?.state = current }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
