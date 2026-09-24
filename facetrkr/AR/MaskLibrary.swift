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
    ///
    /// Main-actor isolated because RealityKit entity construction is, and
    /// saying so here is what lets the catalogue below be a plain `static let`.
    let build: @MainActor () -> Entity

    /// A warp applied together with the props, if this mask is a full lens
    /// rather than a plain prop. Nil leaves whatever warp is already selected.
    var warp: WarpStyle? = nil
}

/// Main-actor isolated: every mask builds RealityKit entities, and every
/// caller (the coordinator's anchor setup and mask switching, the SwiftUI
/// carousel) is already on the main actor. Under Swift 6 the alternative the
/// compiler offers is `nonisolated(unsafe)`, which would assert an invariant
/// this code does not have.
@MainActor
enum MaskLibrary {

    static let all: [Mask] = [
        Mask(id: "none",     name: "None",     symbol: "person",            build: { Entity() }),

        // A lens rather than a prop: the props and the warp only read together.
        Mask(id: "grandma",  name: "Grandma",  symbol: "figure.dress.line.vertical.figure",
             build: ProceduralMasks.grandma, warp: .grandma),

        // Animals
        Mask(id: "dog",      name: "Dog",      symbol: "dog.fill",          build: ProceduralMasks.dog),
        Mask(id: "cat",      name: "Cat",      symbol: "cat.fill",          build: ProceduralMasks.cat),
        Mask(id: "bunny",    name: "Bunny",    symbol: "hare.fill",         build: ProceduralMasks.bunny),
        Mask(id: "pig",      name: "Pig",      symbol: "pawprint.fill",     build: ProceduralMasks.pig),
        Mask(id: "frog",     name: "Frog",     symbol: "leaf.fill",         build: ProceduralMasks.frog),
        Mask(id: "bee",      name: "Bee",      symbol: "ant.fill",          build: ProceduralMasks.bee),
        Mask(id: "unicorn",  name: "Unicorn",  symbol: "sparkle",           build: ProceduralMasks.unicorn),
        Mask(id: "antlers",  name: "Antlers",  symbol: "tree.fill",         build: ProceduralMasks.antlers),

        // Characters
        Mask(id: "clown",    name: "Clown",    symbol: "theatermasks.fill", build: ProceduralMasks.clown),
        Mask(id: "pirate",   name: "Pirate",   symbol: "eye.slash.fill",    build: ProceduralMasks.pirate),
        Mask(id: "wizard",   name: "Wizard",   symbol: "wand.and.stars",    build: ProceduralMasks.wizard),
        Mask(id: "knight",   name: "Knight",   symbol: "shield.fill",       build: ProceduralMasks.knight),
        Mask(id: "robot",    name: "Robot",    symbol: "gearshape.fill",    build: ProceduralMasks.robot),
        Mask(id: "alien",    name: "Alien",    symbol: "moon.stars.fill",   build: ProceduralMasks.alien),
        Mask(id: "cyclops",  name: "Cyclops",  symbol: "eye.fill",          build: ProceduralMasks.cyclops),

        // Gear
        Mask(id: "goggles",  name: "Goggles",  symbol: "eyeglasses",        build: ProceduralMasks.goggles),
        Mask(id: "scuba",    name: "Scuba",    symbol: "drop.fill",         build: ProceduralMasks.scuba),
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

    /// Mirrors a position across the face's midline.
    static func mirrored(_ position: SIMD3<Float>, _ side: Side) -> SIMD3<Float> {
        SIMD3(position.x * side.sign, position.y, position.z)
    }
}

// MARK: - Building blocks

@MainActor
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

    /// A part with a material built by the caller.
    ///
    /// `part` covers the common case of a flat colour, which is all the
    /// original seventeen masks need. This is for the props that carry
    /// generated texture maps, where the material is assembled rather than
    /// described by one colour and one roughness.
    static func shaped(
        _ mesh: MeshResource,
        material: RealityKit.Material,
        at position: SIMD3<Float> = .zero,
        rotation: simd_quatf = simd_quatf(angle: 0, axis: [0, 1, 0]),
        scale: SIMD3<Float> = .one
    ) -> ModelEntity {
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.position = position
        entity.orientation = rotation
        entity.scale = scale
        return entity
    }

    /// Builds the same part on both sides of the face.
    ///
    /// Most props are symmetrical, and writing the loop out each time buried
    /// the interesting numbers in boilerplate. The `x` of `at` is treated as a
    /// distance from the midline and mirrored; `tilt` is applied about the
    /// roll axis and mirrored with it.
    static func pair(
        _ mesh: MeshResource,
        color: UIColor,
        at position: SIMD3<Float>,
        tilt: Float = 0,
        scale: SIMD3<Float> = .one,
        roughness: Float = 0.6,
        metallic: Bool = false
    ) -> [Entity] {
        FaceLandmark.Side.allCases.map { side in
            part(
                mesh,
                color: color,
                at: FaceLandmark.mirrored(position, side),
                rotation: simd_quatf(angle: tilt * side.sign, axis: [0, 0, 1]),
                scale: scale,
                roughness: roughness,
                metallic: metallic
            )
        }
    }

    /// Adds several children in one go, so builders read as a parts list.
    func add(_ parts: [Entity]...) {
        for group in parts {
            for part in group { addChild(part) }
        }
    }
}
