import Foundation
import RealityKit
import UIKit
import simd

/// Loads the wig geometry converted from the supplied GLB.
///
/// Why a private format rather than USDZ: RealityKit takes a `MeshDescriptor`
/// directly, which is already how `CylinderMesh` builds the rollers, so the USD
/// pipeline can be skipped entirely. That matters because Apple retired
/// `usdzconvert` and Google's replacement has to be built from source — neither
/// belongs in this project's build.
///
/// `tools/wig_to_mesh.py` writes the file. It drops the nine roller assemblies
/// (244,800 of the source's 640,144 triangles, rebuilt here with real texture
/// maps instead), thins the hair by dropping whole strands rather than merging
/// vertices, and scales the result into the metres `FaceLandmark` uses.
///
/// Layout, little-endian throughout:
/// ```
/// "FTWG" | version u32 | groupCount u32
/// per group:
///   baseColour 3 x f32 | roughness f32 | metallic f32
///   vertexCount u32 | indexCount u32
///   positions vertexCount x 3 x f32
///   normals   vertexCount x 3 x f32
///   indices   indexCount x u32
/// ```
@MainActor
enum WigMesh {

    struct Group {
        let mesh: MeshResource
        let baseColour: UIColor
        let roughness: Float
        let metallic: Float
    }

    /// One group as it comes off disk, before RealityKit sees it.
    ///
    /// Split out because `MeshResource.generate(from:)` is main-actor isolated
    /// but the parsing is not, and the parsing is nearly all of the cost:
    /// 3.6 MB of little-endian floats turned into vertex arrays. This part runs
    /// off the main actor and is `Sendable` so it can cross back.
    private struct Parsed: Sendable {
        var positions: [SIMD3<Float>]
        var normals: [SIMD3<Float>]
        var indices: [UInt32]
        var baseColour: SIMD3<Float>
        var roughness: Float
        var metallic: Float
    }

    private static var cached: [Group] = []

    static var isWarm: Bool { !cached.isEmpty }

    /// The groups, or empty until `warm()` has run.
    ///
    /// Deliberately not parse-on-demand. `Mask.build` is synchronous and the
    /// carousel calls it between frames, so doing 146,000 triangles' worth of
    /// work there would drop a visible number of them.
    static func groups() -> [Group] { cached }

    /// Parses off the main actor, then builds the meshes on it.
    static func warm() async {
        guard cached.isEmpty else { return }
        guard let asset = NSDataAsset(name: "Wig") else {
            print("[facetrkr] wig asset missing")
            return
        }

        let data = asset.data
        let parsed = await Task.detached(priority: .userInitiated) {
            load(data)
        }.value

        cached = parsed.compactMap { group in
            var descriptor = MeshDescriptor(name: "wig")
            descriptor.positions = MeshBuffer(group.positions)
            descriptor.normals = MeshBuffer(group.normals)
            descriptor.primitives = .triangles(group.indices)

            guard let mesh = try? MeshResource.generate(from: [descriptor]) else { return nil }

            // glTF stores base colour in linear light, but UIColor components
            // are sRGB and RealityKit linearises them again on the way in.
            // Passing the raw values straight through would square the colour
            // and render silver hair as near-black.
            return Group(
                mesh: mesh,
                baseColour: UIColor(
                    red: CGFloat(encodeSRGB(group.baseColour.x)),
                    green: CGFloat(encodeSRGB(group.baseColour.y)),
                    blue: CGFloat(encodeSRGB(group.baseColour.z)),
                    alpha: 1
                ),
                roughness: group.roughness,
                metallic: group.metallic
            )
        }
    }

    nonisolated private static func load(_ data: Data) -> [Parsed] {
        var cursor = 0

        func read<T>(_ type: T.Type, count: Int) -> [T]? {
            let size = MemoryLayout<T>.size * count
            guard cursor + size <= data.count else { return nil }
            defer { cursor += size }
            // The file is written with no padding between fields, so the source
            // bytes are not aligned for T. Copying through withUnsafeBytes is
            // what makes that safe; binding the memory directly would not be.
            let start = cursor
            return data.withUnsafeBytes { raw in
                [T](unsafeUninitializedCapacity: count) { buffer, filled in
                    memcpy(buffer.baseAddress!, raw.baseAddress!.advanced(by: start), size)
                    filled = count
                }
            }
        }

        // Indexed through prefix rather than by integer subscript: a Data can
        // carry a non-zero start index, and this one comes from a framework.
        guard data.count > 12, data.prefix(4).elementsEqual([0x46, 0x54, 0x57, 0x47]) else {
            print("[facetrkr] wig asset is not FTWG")
            return []
        }
        cursor = 4

        guard let header = read(UInt32.self, count: 2), header[0] == 1 else {
            print("[facetrkr] unsupported wig version")
            return []
        }

        var groups: [Parsed] = []
        for _ in 0..<Int(header[1]) {
            guard let colour = read(Float.self, count: 5),
                  let counts = read(UInt32.self, count: 2)
            else { break }

            let vertexCount = Int(counts[0])
            let indexCount = Int(counts[1])

            guard let rawPositions = read(Float.self, count: vertexCount * 3),
                  let rawNormals = read(Float.self, count: vertexCount * 3),
                  let indices = read(UInt32.self, count: indexCount)
            else { break }

            // SIMD3<Float> is sixteen bytes, not twelve, so the file's packed
            // triples cannot be memcpy'd straight in.
            groups.append(Parsed(
                positions: stride(from: 0, to: vertexCount * 3, by: 3).map {
                    SIMD3(rawPositions[$0], rawPositions[$0 + 1], rawPositions[$0 + 2])
                },
                normals: stride(from: 0, to: vertexCount * 3, by: 3).map {
                    SIMD3(rawNormals[$0], rawNormals[$0 + 1], rawNormals[$0 + 2])
                },
                indices: indices,
                baseColour: SIMD3(colour[0], colour[1], colour[2]),
                roughness: colour[3],
                metallic: colour[4]
            ))
        }
        return groups
    }

    /// Linear light to sRGB, the exact transfer function rather than a 1/2.2
    /// approximation — the difference shows in the dark end, which is most of
    /// where this wig's colours sit.
    nonisolated private static func encodeSRGB(_ value: Float) -> Float {
        let c = min(max(value, 0), 1)
        return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }
}
