import ARKit
import RealityKit
import SwiftUI

/// SwiftUI wrapper around the RealityKit `ARView` running face tracking.
struct FaceARView: UIViewRepresentable {

    @ObservedObject var state: FaceTrackingState

    func makeCoordinator() -> FaceSessionCoordinator {
        FaceSessionCoordinator(state: state, recorder: state.recorder)
    }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(
            frame: .zero,
            cameraMode: .ar,
            automaticallyConfigureSession: false
        )
        context.coordinator.attach(to: arView)
        return arView
    }

    /// Mask and effect selection push straight through to the coordinator from
    /// the view model's `didSet`, so the only thing to reconcile here is the
    /// view's size, which isn't known until after layout and which landmark
    /// projection needs in order to normalise screen coordinates.
    func updateUIView(_ arView: ARView, context: Context) {
        state.viewportChanged(to: arView.bounds.size)
    }

    static func dismantleUIView(_ arView: ARView, coordinator: FaceSessionCoordinator) {
        coordinator.detach()
    }
}
