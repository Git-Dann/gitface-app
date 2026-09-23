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

    /// Intentionally empty. Mask selection and the spike toggle push straight
    /// through to the coordinator from the view model's `didSet`, so there is
    /// nothing to reconcile on a redraw.
    func updateUIView(_ arView: ARView, context: Context) {}

    static func dismantleUIView(_ arView: ARView, coordinator: FaceSessionCoordinator) {
        coordinator.detach()
    }
}
