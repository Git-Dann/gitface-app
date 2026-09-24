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

    private static var cached: [Group]?

    /// Parsed once and held: it is a couple of megabytes and the carousel can
    /// select the lens repeatedly.
    static func groups() -> [Group] {
        if let cached { return cached }
        let parsed = load()
        cached = parsed
        return parsed
    }

    private static func load() -> [Group] {
        guard let asset = NSDataAsset(name: "Wig") else {
            print("[facetrkr] wig asset missing")
            return []
        }

        let data = asset.data
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

        var groups: [Group] = []
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

            var descriptor = MeshDescriptor(name: "wig")
            descriptor.positions = MeshBuffer(stride(from: 0, to: vertexCount * 3, by: 3).map {
                SIMD3(rawPositions[$0], rawPositions[$0 + 1], rawPositions[$0 + 2])
            })
            descriptor.normals = MeshBuffer(stride(from: 0, to: vertexCount * 3, by: 3).map {
                SIMD3(rawNormals[$0], rawNormals[$0 + 1], rawNormals[$0 + 2])
            })
            descriptor.primitives = .triangles(indices)

            guard let mesh = try? MeshResource.generate(from: [descriptor]) else { continue }

            // glTF stores base colour in linear light, but UIColor components
            // are sRGB and RealityKit linearises them again on the way in.
            // Passing the raw values straight through would square the colour
            // and render silver hair as near-black.
            groups.append(Group(
                mesh: mesh,
                baseColour: UIColor(
                    red: CGFloat(encodeSRGB(colour[0])),
                    green: CGFloat(encodeSRGB(colour[1])),
                    blue: CGFloat(encodeSRGB(colour[2])),
                    alpha: 1
                ),
                roughness: colour[3],
                metallic: colour[4]
            ))
        }
        return groups
    }

    /// Linear light to sRGB, the exact transfer function rather than a 1/2.2
    /// approximation — the difference shows in the dark end, which is most of
    /// where this wig's colours sit.
    private static func encodeSRGB(_ value: Float) -> Float {
        let c = min(max(value, 0), 1)
        return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }
}
