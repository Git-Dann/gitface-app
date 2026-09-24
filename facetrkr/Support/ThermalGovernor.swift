import Foundation

/// Decides the capture frame rate from the device's thermal state.
///
/// Front camera, Neural Engine face tracking, a Metal composite and an HEVC
/// encode are a sustained three-subsystem load. Rather than let the system
/// throttle unpredictably mid-clip, drop the recording frame rate on the way
/// up, so the result stays smooth at a lower rate instead of stuttering at a
/// higher one.
///
/// Stateless on purpose. This began as an observable object caching the state
/// from a `NotificationCenter` observer, which meant a token to remove in
/// `deinit` — and a nonisolated `deinit` cannot touch a non-Sendable property
/// of a main-actor class, which Swift 6 rejects. The cache was never needed:
/// `ProcessInfo` is cheap to read, and the only consumer already polls on a
/// timer and acts on change. Reading on demand removes the observer, the
/// token, the `deinit` and the error together.
enum ThermalGovernor {

    static var state: ProcessInfo.ThermalState {
        ProcessInfo.processInfo.thermalState
    }

    /// The frame rate recording should target right now.
    static var targetFrameRate: Double {
        switch state {
        case .nominal, .fair: 60
        case .serious:        30
        case .critical:       24
        @unknown default:     30
        }
    }

    static var isThrottled: Bool {
        switch state {
        case .serious, .critical: true
        default:                  false
        }
    }
}
