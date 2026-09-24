import RealityKit
import simd

/// An ellipsoid with the parts you do not want left out.
///
/// `MeshResource.generateSphere` gives a whole sphere, and a whole sphere is
/// exactly what went wrong the first time hair was attempted here: a ball
/// larger than a head, centred inside the skull, protruding past the nose. A
/// scalp is a sphere with the face cut off it, so the cut belongs in the mesh
/// rather than being approximated by shrinking until it stops covering things.
///
/// Quads whose corners all fail `keep` are dropped. That leaves a ragged edge
/// at the cut, which suits a hairline better than a clean one would.
@MainActor
enum EllipsoidMesh {

    /// - Parameters:
    ///   - radii: half-extent on each axis.
    ///   - centre: in the same face-anchor metres as `FaceLandmark`.
    ///   - rings: subdivisions from pole to pole.
    ///   - segments: subdivisions around.
    ///   - keep: called with each candidate position; false drops it.
    static func generate(
        radii: SIMD3<Float>,
        centre: SIMD3<Float>,
        rings: Int = 28,
        segments: Int = 36,
        keep: (SIMD3<Float>) -> Bool
    ) -> MeshResource? {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []

        func point(_ u: Float, _ v: Float) -> SIMD3<Float> {
            let polar = u * .pi
            let azimuth = v * 2 * .pi
            return centre + SIMD3(
                radii.x * sin(polar) * cos(azimuth),
                radii.y * cos(polar),
                radii.z * sin(polar) * sin(azimuth)
            )
        }

        for ring in 0..<rings {
            for segment in 0..<segments {
                let u0 = Float(ring) / Float(rings)
                let u1 = Float(ring + 1) / Float(rings)
                let v0 = Float(segment) / Float(segments)
                let v1 = Float(segment + 1) / Float(segments)

                let corners = [point(u0, v0), point(u1, v0), point(u1, v1), point(u0, v1)]
                guard corners.contains(where: keep) else { continue }

                let base = UInt32(positions.count)
                for (index, corner) in corners.enumerated() {
                    positions.append(corner)
                    // Ellipsoid normals are the gradient, not the radius.
                    let local = (corner - centre) / (radii * radii)
                    normals.append(simd_normalize(local))
                    uvs.append(index < 2
                        ? SIMD2(v0, index == 0 ? u0 : u1)
                        : SIMD2(v1, index == 2 ? u1 : u0))
                }
                indices += [base, base + 1, base + 2, base, base + 2, base + 3]
            }
        }

        guard !indices.isEmpty else { return nil }

        var descriptor = MeshDescriptor(name: "ellipsoid")
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(normals)
        descriptor.textureCoordinates = MeshBuffer(uvs)
        descriptor.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [descriptor])
    }
}
