import RealityKit
import UIKit

/// A selectable mask.
///
/// Deliberately a struct with a closure rather than a protocol: masks go in an
/// array and drive a SwiftUI carousel, and an existential protocol buys nothing
/// here.
struct Mask: Identifiable {
    let id: String
    let name: String
    /// SF Symbol shown in the carousel.
    let symbol: String
    /// Builds a fresh entity tree. Called on every selection, so it must not
    /// share mutable state between calls.
    let build: () -> Entity
}

enum MaskLibrary {

    static let all: [Mask] = [
        Mask(id: "none",    name: "None",    symbol: "person",              build: { Entity() }),
        Mask(id: "dog",     name: "Dog",     symbol: "pawprint.fill",       build: ProceduralMasks.dog),
        Mask(id: "pig",     name: "Pig",     symbol: "snowflake",           build: ProceduralMasks.pig),
        Mask(id: "goggles", name: "Goggles", symbol: "eyeglasses",          build: ProceduralMasks.goggles),
        Mask(id: "knight",  name: "Knight",  symbol: "shield.fill",         build: ProceduralMasks.knight),
        Mask(id: "antlers", name: "Antlers", symbol: "tree.fill",           build: ProceduralMasks.antlers),
    ]

    static var `default`: Mask { all[1] }
}

// MARK: - Face landmark reference

/// Approximate landmark positions in `ARFaceAnchor` space, in metres.
///
/// The anchor's origin sits behind the nose, +Y up and +Z out of the face.
/// These are eyeballed averages, not measured — they are here so the prop
/// builders read as anatomy rather than magic numbers, and so there is one
/// place to nudge when something sits wrong on a real face.
enum FaceLandmark {
    static let noseTip   = SIMD3<Float>(0,      -0.005,  0.075)
    static let noseBase  = SIMD3<Float>(0,       0.005,  0.055)
    static let mouth     = SIMD3<Float>(0,      -0.045,  0.065)
    static let chin      = SIMD3<Float>(0,      -0.080,  0.045)
    static let browCentre = SIMD3<Float>(0,      0.045,  0.060)
    static let crown     = SIMD3<Float>(0,       0.105,  0.010)

    static func eye(_ side: Side) -> SIMD3<Float> {
        SIMD3(0.033 * side.sign, 0.028, 0.055)
    }

    static func ear(_ side: Side) -> SIMD3<Float> {
        SIMD3(0.077 * side.sign, 0.015, -0.015)
    }

    static func temple(_ side: Side) -> SIMD3<Float> {
        SIMD3(0.068 * side.sign, 0.060, 0.010)
    }

    enum Side: CaseIterable {
        case left, right
        var sign: Float { self == .left ? -1 : 1 }
    }
}

// MARK: - Building blocks

extension Entity {

    /// Convenience for a coloured primitive at a position.
    static func part(
        _ mesh: MeshResource,
        color: UIColor,
        at position: SIMD3<Float>,
        rotation: simd_quatf = simd_quatf(angle: 0, axis: [0, 1, 0]),
        scale: SIMD3<Float> = .one,
        roughness: Float = 0.6,
        metallic: Bool = false
    ) -> ModelEntity {
        let entity = ModelEntity(
            mesh: mesh,
            materials: [SimpleMaterial(color: color, roughness: .float(roughness), isMetallic: metallic)]
        )
        entity.position = position
        entity.orientation = rotation
        entity.scale = scale
        return entity
    }
}
