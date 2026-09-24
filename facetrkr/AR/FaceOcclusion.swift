import ARKit
import RealityKit

/// Invisible face-shaped geometry that writes depth but not colour, so props
/// positioned behind the head are hidden by it.
///
/// This is what makes goggle arms disappear correctly when you turn your head,
/// rather than floating through your skull.
enum FaceOcclusion {

    /// Builds the occlusion entity from a face geometry snapshot.
    ///
    /// Deliberately built once from the first tracked geometry rather than
    /// regenerated every frame. `MeshResource.generate` allocates, and doing
    /// that 60 times a second for 1220 vertices is a real cost for no visible
    /// gain: the head's silhouette barely changes with expression, and this
    /// mesh is never seen, only used for depth. It still rides the anchor
    /// transform, so it tracks head movement exactly.
    @MainActor
    static func makeEntity(from geometry: ARFaceGeometry) -> ModelEntity? {
        guard let mesh = makeMesh(from: geometry) else { return nil }
        let entity = ModelEntity(mesh: mesh, materials: [OcclusionMaterial()])
        entity.name = "faceOcclusion"
        return entity
    }

    @MainActor
    private static func makeMesh(from geometry: ARFaceGeometry) -> MeshResource? {
        var descriptor = MeshDescriptor(name: "faceOcclusion")
        descriptor.positions = MeshBuffers.Positions(geometry.vertices)
        descriptor.primitives = .triangles(geometry.triangleIndices.map { UInt32($0) })
        return try? MeshResource.generate(from: [descriptor])
    }
}
