import RealityKit
import UIKit
import simd

/// Hair set in rollers, as one object.
///
/// The reference photograph is not a wig with rollers placed on top of it; it
/// is hair that has been *set*, where the rollers are embedded in the mass and
/// hair is wound thickly over each one. A supplied wig was tried and could not
/// get there: its own rollers are 0.081 m against the photograph's 0.038 m and
/// its hair is modelled wound around them, so at the right roller size every
/// sleeve hangs off both ends of the roller inside it. Rendering both settled
/// it; see `tools/preview_lens.py`.
///
/// Everything here is in the face-anchor metres `FaceLandmark` uses.
@MainActor
enum RollerHair {

    // MARK: Geometry, measured off the photograph

    /// Eleven rollers around a horseshoe, 0.58 x 0.46 eye-spans each, where an
    /// eye span is the 0.066 m between `FaceLandmark.eye(.left)` and `.right`.
    /// Thirteen over a wider arc than the eleven this started with. In the
    /// reference the lowest roller sits at about eye height; at 2.05 radians
    /// the arc stopped 20 mm short of that, leaving the set as a cap rather
    /// than a crown that comes down past the temples.
    static let count = 13
    static let arc: Float = 2.35
    static let barrelLength: Float = 0.0383
    static let barrelRadius: Float = 0.0152
    static let rimRadius = barrelRadius * 1.12
    static let rimLength: Float = 0.0042

    /// Hair wound over the drum. Thick and long, because in the photograph a
    /// roller is mostly grey hair with the rims peeking out at each end — the
    /// thin sleeve this started with left it reading as a bare plastic drum.
    static let sleeveRadius = barrelRadius * 1.45
    static let sleeveLength = barrelLength * 0.80

    /// Where a roller sits, for `index` in `0..<count`.
    static func placement(_ index: Int) -> (position: SIMD3<Float>, angle: Float) {
        let t = Float(index) / Float(count - 1)
        let angle = -arc + arc * 2 * t
        return (
            SIMD3(
                // Solved against the scalp so every roller stands 10 to 31 mm
                // proud of it. Tucked closer they sink in and the set reads as
                // a smooth helmet with pink smudges.
                sin(angle) * 0.112,
                0.078 + cos(angle) * 0.068,
                // The ones down the sides sit further back, following the skull.
                0.012 - (1 - cos(angle)) * 0.016
            ),
            angle
        )
    }

    // MARK: The mass behind the rollers

    /// The scalp, as an ellipsoid with the face cut off it.
    ///
    /// **The clip is the whole safety argument.** The first attempt at hair here
    /// was an unclipped sphere centred inside the skull, which covered the face
    /// entirely — it reached brow level at the front and 2.8 cm past the nose
    /// tip. So the cut is stated against real landmarks rather than tuned by
    /// eye: nothing is kept in front of `frontLimit`, which is well behind
    /// `FaceLandmark.noseTip` at z = 0.075, and nothing below the hairline,
    /// which slopes from the forehead down past the temples toward the nape.
    ///
    /// Deliberately smaller than the roller ring, so the rollers stand proud of
    /// it rather than sinking in.
    static func scalp(material: RealityKit.Material) -> Entity? {
        guard let mesh = EllipsoidMesh.generate(
            // Sized to *enclose* the head, not sit inside it. The first attempt
            // was smaller than the skull, so the occlusion mesh hid all of it
            // and the lens showed the wearer's own hair colour throughout — a
            // wig goes over a head. Checked numerically: every kept vertex is
            // outside an ellipsoid fitted to FaceLandmark's crown, temple and
            // ear.
            // Wide enough that grey shows beside the head rather than only as
            // a rim: 15 mm of it at eye height, against 10 mm when this was
            // first solved. Pushed further the rollers stop standing proud.
            radii: SIMD3(0.094, 0.094, 0.098),
            centre: SIMD3(0, 0.044, -0.014),
            keep: { point in point.z <= frontLimit && point.y >= hairline(at: point.z) }
        ) else { return nil }
        return .shaped(mesh, material: material)
    }

    /// No hair forward of this. `FaceLandmark.browCentre` is at z = 0.060 and
    /// the nose tip at 0.075, so this clears both.
    static let frontLimit: Float = 0.040

    /// The lowest hair at a given depth.
    ///
    /// Hair sits high at the front, where a forehead is, and comes down at the
    /// back and sides. Linear between the two is enough at this size.
    static func hairline(at z: Float) -> Float {
        // Solved rather than eyeballed. In the reference the hairline sits
        // about one eye span (0.066 m) above the eyes at y = 0.028, so near
        // y = 0.094; these two points put the lowest central hair at 0.0941.
        let front: (z: Float, y: Float) = (0.040, 0.098)   // well above the brow
        let back: (z: Float, y: Float) = (-0.050, 0.005)   // down to the nape
        let t = (z - back.z) / (front.z - back.z)
        return back.y + (front.y - back.y) * min(max(t, 0), 1)
    }

    /// Flyaways at the crown.
    ///
    /// The photograph has a few loose strands standing up out of the set, and
    /// they matter more than their size suggests: without them the scalp reads
    /// as a smooth helmet. Solid slivers rather than alpha cards, because
    /// RealityKit transparency is unreliable on 26 and cutout is the documented
    /// workaround.
    static func wisps(material: RealityKit.Material) -> Entity {
        let root = Entity()
        let mesh = MeshResource.generateBox(
            width: 0.0022, height: 0.030, depth: 0.0022, cornerRadius: 0.001
        )

        // Spread across the crown, leaning outward, at stable pseudo-random
        // angles so the set looks combed rather than spiked.
        for index in 0..<14 {
            let t = Float(index) / 13
            let around = (t - 0.5) * 2.6
            let jitter = sin(Float(index) * 12.9898) * 0.5

            root.addChild(.shaped(
                mesh,
                material: material,
                at: SIMD3(
                    sin(around) * 0.070 + jitter * 0.010,
                    0.128 + cos(around) * 0.012 + jitter * 0.008,
                    -0.030 + jitter * 0.022
                ),
                rotation: simd_quatf(angle: around * 0.6 + jitter * 0.3, axis: [0, 0, 1])
            ))
        }
        return root
    }
}
