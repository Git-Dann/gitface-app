import RealityKit
import simd

/// A cylinder with UVs we control.
///
/// `MeshResource.generateCylinder` exists, but two things rule it out for the
/// rollers: it is coarse enough that the silhouette shows at this size, and its
/// UV layout is undocumented. A normal map wrapped around a drum needs `u` to
/// run once around the circumference and `v` along the axis, and guessing at
/// that is how you end up with the perforations smeared diagonally.
///
/// Built lying along X rather than Y, because a roller in hair is on its side
/// and every caller would otherwise rotate it back.
///
/// Main-actor isolated to match `MaskLibrary`: everything that builds a mesh
/// here is called from mask building, which already runs there.
@MainActor
enum CylinderMesh {

    /// - Parameters:
    ///   - length: extent along X.
    ///   - radius: cross-section radius.
    ///   - segments: faces around the circumference. 24 holds its shape at
    ///     arm's length without being wasteful; below about 16 it reads as a
    ///     prism.
    ///   - capped: whether to close the ends. The flanges hide them on a
    ///     roller, so it is worth saving the triangles when they are covered.
    static func generate(
        length: Float,
        radius: Float,
        segments: Int = 24,
        capped: Bool = true
    ) -> MeshResource {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []

        let half = length / 2

        // The seam vertex is duplicated (hence `segments + 1` rings) so `u` can
        // reach 1 instead of wrapping back to 0 across one face, which would
        // squeeze the whole texture into that face.
        for index in 0...segments {
            let t = Float(index) / Float(segments)
            let angle = t * 2 * .pi
            let normal = SIMD3<Float>(0, cos(angle), sin(angle))

            positions.append(SIMD3(-half, normal.y * radius, normal.z * radius))
            normals.append(normal)
            uvs.append(SIMD2(t, 0))

            positions.append(SIMD3(half, normal.y * radius, normal.z * radius))
            normals.append(normal)
            uvs.append(SIMD2(t, 1))
        }

        for index in 0..<segments {
            let base = UInt32(index * 2)
            indices += [base, base + 1, base + 3]
            indices += [base, base + 3, base + 2]
        }

        if capped {
            for (end, direction) in [(-half, Float(-1)), (half, Float(1))] {
                let centre = UInt32(positions.count)
                positions.append(SIMD3(end, 0, 0))
                normals.append(SIMD3(direction, 0, 0))
                uvs.append(SIMD2(0.5, 0.5))

                for index in 0...segments {
                    let angle = Float(index) / Float(segments) * 2 * .pi
                    positions.append(SIMD3(end, cos(angle) * radius, sin(angle) * radius))
                    normals.append(SIMD3(direction, 0, 0))
                    uvs.append(SIMD2(0.5 + cos(angle) * 0.5, 0.5 + sin(angle) * 0.5))
                }

                for index in 0..<segments {
                    let a = centre + 1 + UInt32(index)
                    let b = a + 1
                    // Wind the far cap the other way, or it faces inward and
                    // is culled.
                    indices += direction > 0 ? [centre, a, b] : [centre, b, a]
                }
            }
        }

        var descriptor = MeshDescriptor(name: "cylinder")
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(normals)
        descriptor.textureCoordinates = MeshBuffer(uvs)
        descriptor.primitives = .triangles(indices)

        // The descriptor is well formed by construction, but falling back beats
        // trapping in a shipped app. The fallback is oriented along Y rather
        // than X, so a roller that suddenly points the wrong way means this
        // line was taken.
        return (try? MeshResource.generate(from: [descriptor]))
            ?? .generateCylinder(height: length, radius: radius)
    }
}
