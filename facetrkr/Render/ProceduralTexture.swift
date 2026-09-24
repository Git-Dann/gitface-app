import CoreGraphics
import Foundation
import RealityKit
import simd

/// Texture maps generated in code, so the app carries no art.
///
/// The props looked like plastic because they were: `SimpleMaterial` with one
/// flat colour and one roughness number has no surface detail for light to
/// catch, so a roller reads as a smooth cylinder however well it is placed.
/// A normal map and a varying roughness map are what "definition" means here,
/// and both can be computed.
///
/// Same argument as `tools/make_icon.py`, which writes the app icon by hand
/// rather than shipping one: generating is cheaper than sourcing, carries no
/// licence, and stays tunable against a live face.
///
/// **Why the cache exists.** Both routes from a `CGImage` to a
/// `TextureResource` are `@MainActor async throws` — the synchronous
/// `generate(from:withName:options:)` is deprecated. But `Mask.build` is
/// synchronous, because the carousel calls it between frames. So textures are
/// generated once into this cache at launch and builders read from it. A mask
/// built before the cache is warm falls back to the flat material, which is
/// why `isWarm` is published rather than hidden.
@MainActor
enum ProceduralTexture {

    enum Key: String, CaseIterable {
        /// The perforated drum of a hair roller.
        case rollerNormal
        /// Glossy plastic web against matte holes.
        case rollerRoughness
        /// White mesh with the pink barrel showing through the holes, which is
        /// what the reference photograph shows.
        case rollerBase

        /// Big enough for the perforations to survive mipmapping at arm's
        /// length, small enough that building them is not felt at launch.
        var size: Int { 256 }
    }

    private static var cache: [Key: TextureResource] = [:]

    static func resource(_ key: Key) -> TextureResource? { cache[key] }

    static var isWarm: Bool { cache.count == Key.allCases.count }

    /// Builds every texture. Safe to call more than once.
    ///
    /// The pixel loops run off the main actor and hand back plain byte arrays;
    /// only the `TextureResource` construction has to come back, because it is
    /// main-actor isolated. Passing `CGImage` across that boundary instead
    /// would mean vouching for its Sendability, which is not ours to give.
    static func warm() async {
        guard !isWarm else { return }

        let size = Key.rollerNormal.size

        let built = await Task.detached(priority: .userInitiated) {
            (
                normal: normalMapPixels(size: size, strength: 2.4, height: rollerHeight),
                roughness: scalarMapPixels(size: size, value: rollerRoughness),
                base: colourMapPixels(size: size, colour: rollerBaseColour)
            )
        }.value

        await store(built.normal, as: .rollerNormal, semantic: .normal)
        await store(built.roughness, as: .rollerRoughness, semantic: .raw)
        await store(built.base, as: .rollerBase, semantic: .color)
    }

    private static func store(
        _ pixels: [UInt8],
        as key: Key,
        semantic: TextureResource.Semantic
    ) async {
        guard let image = Self.image(from: pixels, size: key.size) else { return }
        do {
            cache[key] = try await TextureResource(
                image: image,
                withName: key.rawValue,
                options: .init(semantic: semantic, mipmapsMode: .allocateAndGenerateAll)
            )
        } catch {
            // A missing texture degrades to the flat material rather than
            // failing the lens, so this is reported and dropped.
            print("[facetrkr] could not build \(key.rawValue): \(error)")
        }
    }

    // MARK: - Height fields

    /// A roller is a perforated drum: a staggered grid of holes in a plastic
    /// web, with fine ridges running around it. That pattern is the whole
    /// reason a real one reads as an object rather than a cylinder.
    ///
    /// `u` runs around the drum and `v` along it, matching the UVs written by
    /// `CylinderMesh`.
    nonisolated static func rollerHeight(_ u: Float, _ v: Float) -> Float {
        let columns: Float = 14
        let rows: Float = 7

        var x = u * columns
        let y = v * rows
        // Stagger alternate rows, or the holes line up into stripes.
        if Int(y.rounded(.down)) % 2 == 1 { x += 0.5 }

        let fx = x - x.rounded(.down) - 0.5
        let fy = y - y.rounded(.down) - 0.5
        let hole = smoothstep(0.20, 0.33, (fx * fx + fy * fy).squareRoot())

        // Fine circumferential ridges, so the web is not flat either.
        let ridge = 0.5 + 0.5 * sin(v * .pi * 2 * rows * 2)

        return hole * 0.86 + ridge * 0.14
    }

    /// Glossy where the plastic is, matte down in the holes. Varying roughness
    /// across one surface is as strong a realism cue as the normal map.
    nonisolated static func rollerRoughness(_ u: Float, _ v: Float) -> Float {
        0.22 + (1 - rollerHeight(u, v)) * 0.62
    }

    /// White mesh over a pink barrel.
    ///
    /// Measured off the reference photograph, where each roller is a white
    /// plastic grille with the pink drum visible through it. Shipping a solid
    /// pink barrel made them read as bobbins.
    nonisolated static func rollerBaseColour(_ u: Float, _ v: Float) -> SIMD3<Float> {
        let web = rollerHeight(u, v)
        let pink = SIMD3<Float>(0.72, 0.13, 0.38)
        let white = SIMD3<Float>(0.97, 0.95, 0.95)
        return pink + (white - pink) * web
    }

    // MARK: - Map building

    /// Converts a height field to a tangent-space normal map.
    ///
    /// Central differences across the field, scaled by `strength`, packed into
    /// the 0-1 range the sampler unpacks from. Coordinates wrap, so a texture
    /// tiled around a drum has no seam down it.
    nonisolated static func normalMapPixels(
        size: Int,
        strength: Float,
        height: (Float, Float) -> Float
    ) -> [UInt8] {
        let step = 1 / Float(size)

        return pixels(size: size) { x, y in
            let u = (Float(x) + 0.5) * step
            let v = (Float(y) + 0.5) * step

            let dx = height(wrap(u + step), v) - height(wrap(u - step), v)
            let dy = height(u, wrap(v + step)) - height(u, wrap(v - step))

            let normal = simd_normalize(SIMD3<Float>(-dx * strength, -dy * strength, 1))
            return (
                byte(normal.x * 0.5 + 0.5),
                byte(normal.y * 0.5 + 0.5),
                byte(normal.z * 0.5 + 0.5)
            )
        }
    }

    /// A single value written to all three channels, for roughness, occlusion
    /// or anything else the renderer reads as data rather than colour.
    nonisolated static func scalarMapPixels(
        size: Int,
        value: (Float, Float) -> Float
    ) -> [UInt8] {
        let step = 1 / Float(size)

        return pixels(size: size) { x, y in
            let level = byte(value((Float(x) + 0.5) * step, (Float(y) + 0.5) * step))
            return (level, level, level)
        }
    }

    /// A full-colour map.
    nonisolated static func colourMapPixels(
        size: Int,
        colour: (Float, Float) -> SIMD3<Float>
    ) -> [UInt8] {
        let step = 1 / Float(size)

        return pixels(size: size) { x, y in
            let c = colour((Float(x) + 0.5) * step, (Float(y) + 0.5) * step)
            return (byte(c.x), byte(c.y), byte(c.z))
        }
    }

    /// Fills an opaque 8-bit RGBA buffer a pixel at a time.
    ///
    /// Written straight into the buffer rather than drawn with CoreGraphics
    /// paths, because every map here is a function of position and a per-pixel
    /// closure says that far more directly than a sequence of draw calls.
    nonisolated private static func pixels(
        size: Int,
        _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)
    ) -> [UInt8] {
        let bytesPerRow = size * 4
        var data = [UInt8](repeating: 255, count: bytesPerRow * size)

        for y in 0..<size {
            let row = y * bytesPerRow
            for x in 0..<size {
                let (r, g, b) = pixel(x, y)
                let index = row + x * 4
                data[index] = r
                data[index + 1] = g
                data[index + 2] = b
            }
        }
        return data
    }

    nonisolated private static func image(from pixels: [UInt8], size: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }

        return CGImage(
            width: size,
            height: size,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    // MARK: - Small maths

    nonisolated private static func byte(_ value: Float) -> UInt8 {
        UInt8(clamping: Int((min(max(value, 0), 1) * 255).rounded()))
    }

    nonisolated private static func wrap(_ value: Float) -> Float {
        value - value.rounded(.down)
    }

    nonisolated static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        guard edge1 > edge0 else { return x < edge0 ? 0 : 1 }
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
