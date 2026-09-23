import RealityKit
import UIKit

/// Masks built from RealityKit primitives.
///
/// Every prop here is rigid: it parents to the face anchor and rides the head
/// transform. Nothing reads blendshapes. That is the whole point — rigid props
/// need no rigged, morph-target-bearing USDZ, which is where this kind of
/// project usually stalls. Real models can replace these one at a time later
/// without touching anything else.
enum ProceduralMasks {

    // MARK: Dog

    static func dog() -> Entity {
        let root = Entity()

        root.addChild(.part(
            .generateSphere(radius: 0.017),
            color: .black,
            at: FaceLandmark.noseTip,
            scale: [1, 0.85, 0.9]
        ))

        for side in FaceLandmark.Side.allCases {
            let ear = Entity.part(
                .generateBox(width: 0.035, height: 0.085, depth: 0.012, cornerRadius: 0.014),
                color: UIColor(red: 0.42, green: 0.27, blue: 0.16, alpha: 1),
                at: FaceLandmark.temple(side) + [0.012 * side.sign, 0.035, -0.01],
                rotation: simd_quatf(angle: 0.35 * side.sign, axis: [0, 0, 1])
            )
            root.addChild(ear)
        }

        // Tongue, because it is funnier with one.
        root.addChild(.part(
            .generateBox(width: 0.026, height: 0.045, depth: 0.008, cornerRadius: 0.012),
            color: UIColor(red: 0.90, green: 0.35, blue: 0.45, alpha: 1),
            at: FaceLandmark.mouth + [0, -0.022, 0.012],
            rotation: simd_quatf(angle: 0.25, axis: [1, 0, 0])
        ))

        return root
    }

    // MARK: Pig

    static func pig() -> Entity {
        let root = Entity()
        let pink = UIColor(red: 0.96, green: 0.65, blue: 0.70, alpha: 1)

        let snout = Entity.part(
            .generateCylinder(height: 0.022, radius: 0.023),
            color: pink,
            at: FaceLandmark.noseTip + [0, 0, 0.004],
            rotation: simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        )
        root.addChild(snout)

        for side in FaceLandmark.Side.allCases {
            root.addChild(.part(
                .generateSphere(radius: 0.005),
                color: UIColor(red: 0.75, green: 0.42, blue: 0.48, alpha: 1),
                at: FaceLandmark.noseTip + [0.008 * side.sign, 0, 0.016]
            ))

            root.addChild(.part(
                .generateCone(height: 0.045, radius: 0.022),
                color: pink,
                at: FaceLandmark.temple(side) + [0, 0.028, -0.012],
                rotation: simd_quatf(angle: 0.25 * side.sign, axis: [0, 0, 1])
            ))
        }

        return root
    }

    // MARK: Goggles

    static func goggles() -> Entity {
        let root = Entity()
        let frame = UIColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1)

        for side in FaceLandmark.Side.allCases {
            let lens = Entity.part(
                .generateCylinder(height: 0.010, radius: 0.026),
                color: UIColor(red: 0.20, green: 0.55, blue: 0.85, alpha: 1),
                at: FaceLandmark.eye(side) + [0, 0, 0.012],
                rotation: simd_quatf(angle: .pi / 2, axis: [1, 0, 0]),
                roughness: 0.15,
                metallic: true
            )
            root.addChild(lens)

            // Arm running back towards the ear. The occlusion mesh is what
            // makes this read correctly when the head turns.
            root.addChild(.part(
                .generateBox(width: 0.075, height: 0.006, depth: 0.005, cornerRadius: 0.002),
                color: frame,
                at: FaceLandmark.eye(side) + [0.030 * side.sign, 0.004, -0.030]
            ))
        }

        root.addChild(.part(
            .generateBox(width: 0.022, height: 0.006, depth: 0.006, cornerRadius: 0.002),
            color: frame,
            at: FaceLandmark.noseBase + [0, 0.018, 0.012]
        ))

        return root
    }

    // MARK: Knight

    static func knight() -> Entity {
        let root = Entity()
        let steel = UIColor(red: 0.62, green: 0.65, blue: 0.70, alpha: 1)

        root.addChild(.part(
            .generateSphere(radius: 0.098),
            color: steel,
            at: FaceLandmark.crown + [0, -0.045, 0.005],
            scale: [1.0, 1.05, 1.0],
            roughness: 0.25,
            metallic: true
        ))

        // Visor slot, sitting proud of the dome so it reads as a separate part.
        root.addChild(.part(
            .generateBox(width: 0.105, height: 0.014, depth: 0.020, cornerRadius: 0.004),
            color: .black,
            at: FaceLandmark.browCentre + [0, -0.010, 0.042]
        ))

        root.addChild(.part(
            .generateBox(width: 0.010, height: 0.070, depth: 0.028, cornerRadius: 0.003),
            color: steel,
            at: FaceLandmark.noseBase + [0, -0.020, 0.048],
            roughness: 0.25,
            metallic: true
        ))

        return root
    }

    // MARK: Antlers

    static func antlers() -> Entity {
        let root = Entity()
        let bone = UIColor(red: 0.80, green: 0.73, blue: 0.58, alpha: 1)

        for side in FaceLandmark.Side.allCases {
            let branch = Entity()
            branch.position = FaceLandmark.temple(side) + [0, 0.045, -0.005]
            branch.orientation = simd_quatf(angle: 0.45 * side.sign, axis: [0, 0, 1])

            branch.addChild(.part(
                .generateCylinder(height: 0.090, radius: 0.007),
                color: bone,
                at: [0, 0.045, 0]
            ))

            for (index, height) in [0.055, 0.042, 0.030].enumerated() {
                let tine = Entity.part(
                    .generateCylinder(height: Float(height), radius: 0.0045),
                    color: bone,
                    at: [0.018 * side.sign, 0.045 + Float(index) * 0.026, 0],
                    rotation: simd_quatf(angle: 0.7 * side.sign, axis: [0, 0, -1])
                )
                branch.addChild(tine)
            }

            root.addChild(branch)
        }

        return root
    }
}
