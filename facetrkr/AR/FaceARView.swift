import ARKit
import RealityKit
import SwiftUI

/// SwiftUI wrapper around the RealityKit `ARView` running face tracking.
struct FaceARView: UIViewRepresentable {

    @ObservedObject var state: FaceTrackingState

    func makeCoordinator() -> FaceSessionCoordinator {
        FaceSessionCoordinator(state: state)
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

    func updateUIView(_ arView: ARView, context: Context) {
        context.coordinator.setTintSpikeEnabled(state.isTintSpikeEnabled)
    }

    static func dismantleUIView(_ arView: ARView, coordinator: FaceSessionCoordinator) {
        coordinator.detach()
    }
}
