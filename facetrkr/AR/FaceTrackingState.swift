import Foundation

/// Observable UI state for the face tracking session.
///
/// Only ever mutated on the main actor. The render thread never reads this —
/// see `PostProcessSpike` for the lock-protected snapshot it uses instead.
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
            case .starting:       "Starting camera…"
            case .unsupported:    "This device can't do face tracking."
            case .searching:      "Looking for a face…"
            case .tracking:       "Tracking"
            case .failed(let why): why
            }
        }
    }

    @Published private(set) var status: Status = .starting

    /// M1 spike toggle. Tints the composited frame red to prove what the
    /// post-process source texture actually contains. Remove once M1 passes.
    @Published var isTintSpikeEnabled = false

    var isSupported: Bool { status != .unsupported }

    func update(to status: Status) {
        guard self.status != status else { return }
        self.status = status
    }
}
