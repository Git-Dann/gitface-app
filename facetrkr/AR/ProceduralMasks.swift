import RealityKit
import UIKit

/// Masks built from RealityKit primitives.
///
/// Every prop here is rigid: it parents to the face anchor and rides the head
/// transform. Nothing reads blendshapes. That is the whole point — rigid props
/// need no rigged, morph-target-bearing USDZ, which is where this kind of
/// project usually stalls. Real models can replace these one at a time without
/// touching anything else.
@MainActor
enum ProceduralMasks {

    // MARK: - Palette

    private enum Shade {
        static let brown = UIColor(red: 0.42, green: 0.27, blue: 0.16, alpha: 1)
        static let pink = UIColor(red: 0.96, green: 0.65, blue: 0.70, alpha: 1)
        static let deepPink = UIColor(red: 0.75, green: 0.42, blue: 0.48, alpha: 1)
        static let tongue = UIColor(red: 0.90, green: 0.35, blue: 0.45, alpha: 1)
        static let grey = UIColor(red: 0.55, green: 0.56, blue: 0.60, alpha: 1)
        static let steel = UIColor(red: 0.62, green: 0.65, blue: 0.70, alpha: 1)
        static let bone = UIColor(red: 0.80, green: 0.73, blue: 0.58, alpha: 1)
        static let frogGreen = UIColor(red: 0.36, green: 0.66, blue: 0.32, alpha: 1)
        static let alienGreen = UIColor(red: 0.62, green: 0.82, blue: 0.55, alpha: 1)
        static let gold = UIColor(red: 0.90, green: 0.72, blue: 0.24, alpha: 1)
        static let purple = UIColor(red: 0.40, green: 0.24, blue: 0.62, alpha: 1)
        static let crimson = UIColor(red: 0.78, green: 0.14, blue: 0.18, alpha: 1)
        static let charcoal = UIColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1)
        static let hair = UIColor(red: 0.80, green: 0.80, blue: 0.82, alpha: 1)
        static let roller = UIColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1)
        static let rollerBand = UIColor(red: 0.91, green: 0.29, blue: 0.56, alpha: 1)
        static let frame = UIColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1)
    }

    // MARK: - Grandma

    /// The reference lens: curler crown, grey hair, heavy square frames.
    ///
    /// The curlers carry the silhouette, which is what makes this work without
    /// a real hair asset. Snap's own lens leans on the same trick: get the
    /// crown right and the eye reads "hair" without any strands being modelled.
    static func grandma() -> Entity {
        let root = Entity()
        root.addChild(hairCap())
        root.addChild(curlerCrown())
        root.addChild(readingGlasses())
        return root
    }

    /// A skullcap sitting behind the curlers. Not meant to be seen directly —
    /// it stops the scalp showing through the gaps in the crown.
    private static func hairCap() -> Entity {
        let root = Entity()
        root.addChild(.part(
            .generateSphere(radius: 0.093),
            color: Shade.hair,
            at: FaceLandmark.crown + [0, -0.038, -0.004],
            scale: [1.02, 0.86, 1.04],
            roughness: 0.85
        ))

        // A few wisps at the temples. Kept sparse and opaque: RealityKit's
        // transparency is unreliable on 26, so these are solid slivers rather
        // than alpha-blended hair cards.
        for side in FaceLandmark.Side.allCases {
            for (index, tilt) in [Float(0.55), 0.20, -0.15].enumerated() {
                root.addChild(.part(
                    .generateBox(width: 0.010, height: 0.052, depth: 0.006, cornerRadius: 0.005),
                    color: Shade.hair,
                    at: FaceLandmark.temple(side) + [0.020 * side.sign,
                                                     0.030 - Float(index) * 0.016,
                                                     -0.016],
                    rotation: simd_quatf(angle: tilt * side.sign, axis: [0, 0, 1]),
                    roughness: 0.9
                ))
            }
        }
        return root
    }

    /// Curlers around the hairline.
    ///
    /// Placed around an arc rather than built as a ring, because RealityKit has
    /// no torus primitive. Each is a cylinder lying on its side with a pink
    /// band at each end, which is the whole read at this size.
    private static func curlerCrown() -> Entity {
        let root = Entity()
        let count = 9
        let arc: Float = .pi * 1.15
        let radius: Float = 0.098

        for index in 0..<count {
            let t = Float(index) / Float(count - 1)
            let angle = -arc / 2 + arc * t

            let curler = Entity()
            curler.position = FaceLandmark.crown + [
                sin(angle) * radius,
                cos(angle) * radius * 0.42 - 0.012,
                -0.014
            ]
            // Each curler lies tangent to the arc, so the crown reads as a ring
            // of rollers rather than a row of loose cylinders.
            curler.orientation = simd_quatf(angle: angle, axis: [0, 0, 1])

            curler.addChild(.part(
                .generateCylinder(height: 0.042, radius: 0.019),
                color: Shade.roller,
                at: .zero,
                rotation: simd_quatf(angle: .pi / 2, axis: [0, 0, 1]),
                roughness: 0.55
            ))
            for end in [Float(-1), 1] {
                curler.addChild(.part(
                    .generateCylinder(height: 0.009, radius: 0.0205),
                    color: Shade.rollerBand,
                    at: [0.017 * end, 0, 0],
                    rotation: simd_quatf(angle: .pi / 2, axis: [0, 0, 1]),
                    roughness: 0.45
                ))
            }
            // Hair wound over the roller.
            curler.addChild(.part(
                .generateCylinder(height: 0.020, radius: 0.0215),
                color: Shade.hair,
                at: .zero,
                rotation: simd_quatf(angle: .pi / 2, axis: [0, 0, 1]),
                roughness: 0.9
            ))

            root.addChild(curler)
        }
        return root
    }

    /// Heavy square frames. The reference pair are wide, thick and sit low.
    private static func readingGlasses() -> Entity {
        let root = Entity()

        for side in FaceLandmark.Side.allCases {
            let centre = FaceLandmark.mirrored(
                FaceLandmark.eye(.right) + [0.006, -0.004, 0.020], side
            )

            // Four bars per lens rather than a solid plate, so the frame reads
            // as a rim with the eye visible through it.
            let width: Float = 0.052
            let height: Float = 0.040
            let bar: Float = 0.0055

            for vertical in [Float(-1), 1] {
                root.addChild(.part(
                    .generateBox(width: width, height: bar, depth: 0.007, cornerRadius: 0.002),
                    color: Shade.frame,
                    at: centre + [0, height / 2 * vertical, 0],
                    roughness: 0.3
                ))
            }
            for horizontal in [Float(-1), 1] {
                root.addChild(.part(
                    .generateBox(width: bar, height: height, depth: 0.007, cornerRadius: 0.002),
                    color: Shade.frame,
                    at: centre + [width / 2 * horizontal, 0, 0],
                    roughness: 0.3
                ))
            }

            // Arm back towards the ear. The occlusion mesh is what makes this
            // disappear correctly when the head turns.
            root.addChild(.part(
                .generateBox(width: 0.070, height: 0.005, depth: 0.005, cornerRadius: 0.002),
                color: Shade.frame,
                at: centre + [0.042 * side.sign, 0.012, -0.034],
                roughness: 0.3
            ))
        }

        root.addChild(.part(
            .generateBox(width: 0.020, height: 0.005, depth: 0.006, cornerRadius: 0.002),
            color: Shade.frame,
            at: FaceLandmark.noseBase + [0, 0.008, 0.020],
            roughness: 0.3
        ))
        return root
    }

    // MARK: - Animals

    static func dog() -> Entity {
        let root = Entity()
        root.add(
            [.part(.generateSphere(radius: 0.017), color: .black,
                   at: FaceLandmark.noseTip, scale: [1, 0.85, 0.9])],
            Entity.pair(.generateBox(width: 0.035, height: 0.085, depth: 0.012, cornerRadius: 0.014),
                  color: Shade.brown,
                  at: FaceLandmark.temple(.right) + [0.012, 0.035, -0.010],
                  tilt: 0.35),
            // Tongue, because it is funnier with one.
            [.part(.generateBox(width: 0.026, height: 0.045, depth: 0.008, cornerRadius: 0.012),
                   color: Shade.tongue,
                   at: FaceLandmark.mouth + [0, -0.022, 0.012],
                   rotation: simd_quatf(angle: 0.25, axis: [1, 0, 0]))]
        )
        return root
    }

    static func cat() -> Entity {
        let root = Entity()
        root.add(
            [.part(.generateSphere(radius: 0.011), color: Shade.pink,
                   at: FaceLandmark.noseTip, scale: [1.2, 0.8, 0.8])],
            Entity.pair(.generateCone(height: 0.050, radius: 0.026),
                  color: Shade.grey,
                  at: FaceLandmark.temple(.right) + [0.004, 0.030, -0.008],
                  tilt: 0.20),
            // Inner ear, slightly forward so it catches the light differently.
            Entity.pair(.generateCone(height: 0.030, radius: 0.014),
                  color: Shade.pink,
                  at: FaceLandmark.temple(.right) + [0.004, 0.026, 0.004],
                  tilt: 0.20)
        )

        // Whiskers fan out from beside the nose.
        for side in FaceLandmark.Side.allCases {
            for (index, angle) in [Float(0.22), 0, -0.22].enumerated() {
                root.addChild(.part(
                    .generateBox(width: 0.070, height: 0.0018, depth: 0.0018, cornerRadius: 0.0009),
                    color: .white,
                    at: FaceLandmark.noseTip + [0.038 * side.sign, Float(index) * 0.001 - 0.004, -0.008],
                    rotation: simd_quatf(angle: angle * side.sign, axis: [0, 0, 1])
                ))
            }
        }
        return root
    }

    static func bunny() -> Entity {
        let root = Entity()
        root.add(
            [.part(.generateSphere(radius: 0.010), color: Shade.pink,
                   at: FaceLandmark.noseTip, scale: [1.2, 0.8, 0.8])],
            Entity.pair(.generateBox(width: 0.030, height: 0.130, depth: 0.014, cornerRadius: 0.015),
                  color: .white,
                  at: FaceLandmark.temple(.right) + [-0.004, 0.070, -0.010],
                  tilt: 0.14),
            Entity.pair(.generateBox(width: 0.018, height: 0.100, depth: 0.006, cornerRadius: 0.009),
                  color: Shade.pink,
                  at: FaceLandmark.temple(.right) + [-0.004, 0.070, 0.002],
                  tilt: 0.14),
            // Buck teeth.
            Entity.pair(.generateBox(width: 0.013, height: 0.024, depth: 0.007, cornerRadius: 0.002),
                  color: .white,
                  at: SIMD3(0.007, FaceLandmark.mouth.y - 0.006, FaceLandmark.mouth.z + 0.008))
        )
        return root
    }

    static func pig() -> Entity {
        let root = Entity()
        root.add(
            [.part(.generateCylinder(height: 0.022, radius: 0.023),
                   color: Shade.pink,
                   at: FaceLandmark.noseTip + [0, 0, 0.004],
                   rotation: simd_quatf(angle: .pi / 2, axis: [1, 0, 0]))],
            Entity.pair(.generateSphere(radius: 0.005), color: Shade.deepPink,
                  at: FaceLandmark.noseTip + [0.008, 0, 0.016]),
            Entity.pair(.generateCone(height: 0.045, radius: 0.022),
                  color: Shade.pink,
                  at: FaceLandmark.temple(.right) + [0, 0.028, -0.012],
                  tilt: 0.25)
        )
        return root
    }

    static func frog() -> Entity {
        let root = Entity()
        root.add(
            // Eyes ride high on the skull, the way a frog's do.
            Entity.pair(.generateSphere(radius: 0.028), color: Shade.frogGreen,
                  at: SIMD3(0.045, 0.085, 0.030)),
            Entity.pair(.generateSphere(radius: 0.014), color: .white,
                  at: SIMD3(0.045, 0.088, 0.052)),
            Entity.pair(.generateSphere(radius: 0.007), color: .black,
                  at: SIMD3(0.045, 0.088, 0.062)),
            // A wide flat mouth across the whole jaw.
            [.part(.generateBox(width: 0.115, height: 0.012, depth: 0.020, cornerRadius: 0.005),
                   color: Shade.frogGreen,
                   at: FaceLandmark.mouth + [0, -0.008, 0.008])]
        )
        return root
    }

    static func bee() -> Entity {
        let root = Entity()
        root.add(
            Entity.pair(.generateSphere(radius: 0.020), color: Shade.charcoal,
                  at: FaceLandmark.eye(.right) + [0.006, 0.004, 0.014],
                  scale: [1, 1.25, 0.7], roughness: 0.2, metallic: true),
            // Antennae: a stalk with a bobble on the end.
            Entity.pair(.generateCylinder(height: 0.060, radius: 0.0025),
                  color: Shade.charcoal,
                  at: FaceLandmark.temple(.right) + [-0.012, 0.045, -0.004],
                  tilt: 0.30),
            Entity.pair(.generateSphere(radius: 0.008), color: Shade.gold,
                  at: FaceLandmark.temple(.right) + [-0.022, 0.075, -0.004])
        )
        return root
    }

    static func unicorn() -> Entity {
        let root = Entity()
        root.addChild(.part(
            .generateCone(height: 0.110, radius: 0.020),
            color: Shade.gold,
            at: FaceLandmark.browCentre + [0, 0.075, 0.010],
            rotation: simd_quatf(angle: -0.25, axis: [1, 0, 0]),
            roughness: 0.15,
            metallic: true
        ))
        root.add(
            Entity.pair(.generateCone(height: 0.040, radius: 0.018), color: .white,
                  at: FaceLandmark.temple(.right) + [0.006, 0.026, -0.010], tilt: 0.30)
        )
        // Mane: a row of tufts running back over the crown.
        for (index, tint) in [Shade.pink, Shade.purple, Shade.gold, Shade.frogGreen].enumerated() {
            root.addChild(.part(
                .generateSphere(radius: 0.022),
                color: tint,
                at: FaceLandmark.crown + [0, 0.010 - Float(index) * 0.018, -0.030 - Float(index) * 0.022],
                scale: [0.9, 1, 1.1]
            ))
        }
        return root
    }

    static func antlers() -> Entity {
        let root = Entity()
        for side in FaceLandmark.Side.allCases {
            let branch = Entity()
            branch.position = FaceLandmark.temple(side) + [0, 0.045, -0.005]
            branch.orientation = simd_quatf(angle: 0.45 * side.sign, axis: [0, 0, 1])
            branch.addChild(.part(.generateCylinder(height: 0.090, radius: 0.007),
                                  color: Shade.bone, at: [0, 0.045, 0]))

            for (index, height) in [0.055, 0.042, 0.030].enumerated() {
                branch.addChild(.part(
                    .generateCylinder(height: Float(height), radius: 0.0045),
                    color: Shade.bone,
                    at: [0.018 * side.sign, 0.045 + Float(index) * 0.026, 0],
                    rotation: simd_quatf(angle: 0.7 * side.sign, axis: [0, 0, -1])
                ))
            }
            root.addChild(branch)
        }
        return root
    }

    // MARK: - Characters

    static func clown() -> Entity {
        let root = Entity()
        root.addChild(.part(.generateSphere(radius: 0.021), color: Shade.crimson,
                            at: FaceLandmark.noseTip + [0, 0, 0.006], roughness: 0.2))
        // Hair: three tufts either side, stepping down past the ear.
        for side in FaceLandmark.Side.allCases {
            for index in 0..<3 {
                root.addChild(.part(
                    .generateSphere(radius: 0.028 - Float(index) * 0.004),
                    color: UIColor(red: 0.95, green: 0.45, blue: 0.15, alpha: 1),
                    at: FaceLandmark.temple(side) + [0.022 * side.sign,
                                                     0.020 - Float(index) * 0.034,
                                                     -0.020]
                ))
            }
        }
        root.add(
            Entity.pair(.generateBox(width: 0.030, height: 0.010, depth: 0.006, cornerRadius: 0.004),
                  color: Shade.crimson,
                  at: FaceLandmark.mouth + [0.026, -0.010, 0.004], tilt: -0.55)
        )
        return root
    }

    static func pirate() -> Entity {
        let root = Entity()

        // Patch over one eye only, which is the whole joke.
        root.addChild(.part(.generateBox(width: 0.042, height: 0.034, depth: 0.008, cornerRadius: 0.004),
                            color: Shade.charcoal,
                            at: FaceLandmark.eye(.left) + [0, 0, 0.012]))
        root.addChild(.part(.generateBox(width: 0.140, height: 0.004, depth: 0.004, cornerRadius: 0.002),
                            color: Shade.charcoal,
                            at: FaceLandmark.eye(.left) + [0.030, 0.012, -0.020],
                            rotation: simd_quatf(angle: -0.12, axis: [0, 0, 1])))

        // Bandana: a flattened dome with a knot trailing off one side.
        root.addChild(.part(.generateSphere(radius: 0.093), color: Shade.crimson,
                            at: FaceLandmark.crown + [0, -0.030, 0.004],
                            scale: [1, 0.72, 1]))
        root.addChild(.part(.generateSphere(radius: 0.020), color: Shade.crimson,
                            at: FaceLandmark.temple(.right) + [0.030, 0.020, -0.030],
                            scale: [1, 0.8, 1.4]))

        root.addChild(.part(.generateSphere(radius: 0.010), color: Shade.gold,
                            at: FaceLandmark.ear(.right) + [0.006, -0.028, 0.006],
                            scale: [0.4, 1, 1], roughness: 0.15, metallic: true))
        return root
    }

    static func wizard() -> Entity {
        let root = Entity()
        root.addChild(.part(.generateCone(height: 0.220, radius: 0.085),
                            color: Shade.purple,
                            at: FaceLandmark.crown + [0, 0.105, -0.010],
                            rotation: simd_quatf(angle: -0.12, axis: [1, 0, 0])))
        root.addChild(.part(.generateCylinder(height: 0.012, radius: 0.105),
                            color: Shade.purple,
                            at: FaceLandmark.crown + [0, 0.005, -0.005],
                            rotation: simd_quatf(angle: .pi / 2, axis: [1, 0, 0])))
        root.addChild(.part(.generateSphere(radius: 0.016), color: Shade.gold,
                            at: FaceLandmark.crown + [0, 0.215, -0.030],
                            roughness: 0.1, metallic: true))

        // Beard: overlapping spheres tapering from jaw to point.
        for index in 0..<5 {
            let drop = Float(index) * 0.026
            root.addChild(.part(
                .generateSphere(radius: 0.038 - Float(index) * 0.005),
                color: UIColor(white: 0.92, alpha: 1),
                at: FaceLandmark.chin + [0, 0.010 - drop, 0.004 - Float(index) * 0.004]
            ))
        }
        return root
    }

    static func knight() -> Entity {
        let root = Entity()
        root.addChild(.part(.generateSphere(radius: 0.098), color: Shade.steel,
                            at: FaceLandmark.crown + [0, -0.045, 0.005],
                            scale: [1.0, 1.05, 1.0], roughness: 0.25, metallic: true))
        // Visor slot, proud of the dome so it reads as a separate part.
        root.addChild(.part(.generateBox(width: 0.105, height: 0.014, depth: 0.020, cornerRadius: 0.004),
                            color: .black,
                            at: FaceLandmark.browCentre + [0, -0.010, 0.042]))
        root.addChild(.part(.generateBox(width: 0.010, height: 0.070, depth: 0.028, cornerRadius: 0.003),
                            color: Shade.steel,
                            at: FaceLandmark.noseBase + [0, -0.020, 0.048],
                            roughness: 0.25, metallic: true))
        return root
    }

    static func robot() -> Entity {
        let root = Entity()
        root.addChild(.part(.generateBox(width: 0.125, height: 0.030, depth: 0.014, cornerRadius: 0.006),
                            color: Shade.charcoal,
                            at: FaceLandmark.browCentre + [0, -0.004, 0.030],
                            roughness: 0.2, metallic: true))
        root.addChild(.part(.generateBox(width: 0.100, height: 0.012, depth: 0.004, cornerRadius: 0.004),
                            color: UIColor(red: 0.20, green: 0.95, blue: 0.85, alpha: 1),
                            at: FaceLandmark.browCentre + [0, -0.004, 0.039],
                            roughness: 0.05))
        root.add(
            Entity.pair(.generateCylinder(height: 0.016, radius: 0.022),
                  color: Shade.grey,
                  at: FaceLandmark.ear(.right) + [0.006, 0.010, 0.004],
                  roughness: 0.2, metallic: true)
        )
        root.addChild(.part(.generateCylinder(height: 0.055, radius: 0.004),
                            color: Shade.grey,
                            at: FaceLandmark.crown + [0.030, 0.030, -0.010],
                            roughness: 0.2, metallic: true))
        root.addChild(.part(.generateSphere(radius: 0.011), color: .systemRed,
                            at: FaceLandmark.crown + [0.030, 0.060, -0.010], roughness: 0.1))
        return root
    }

    static func alien() -> Entity {
        let root = Entity()
        root.addChild(.part(.generateSphere(radius: 0.098), color: Shade.alienGreen,
                            at: FaceLandmark.crown + [0, -0.020, -0.010],
                            scale: [0.92, 1.25, 1.0]))
        // Almond eyes, angled inwards.
        root.add(
            Entity.pair(.generateSphere(radius: 0.026), color: .black,
                  at: FaceLandmark.eye(.right) + [0.006, 0.004, 0.012],
                  tilt: 0.45, scale: [1.5, 0.75, 0.55], roughness: 0.1)
        )
        return root
    }

    static func cyclops() -> Entity {
        let root = Entity()
        root.addChild(.part(.generateSphere(radius: 0.040), color: .white,
                            at: FaceLandmark.browCentre + [0, -0.004, 0.018],
                            scale: [1, 1, 0.75], roughness: 0.15))
        root.addChild(.part(.generateSphere(radius: 0.017),
                            color: UIColor(red: 0.30, green: 0.55, blue: 0.85, alpha: 1),
                            at: FaceLandmark.browCentre + [0, -0.004, 0.048],
                            scale: [1, 1, 0.5], roughness: 0.1))
        root.addChild(.part(.generateSphere(radius: 0.008), color: .black,
                            at: FaceLandmark.browCentre + [0, -0.004, 0.055],
                            scale: [1, 1, 0.4]))
        return root
    }

    // MARK: - Gear

    static func goggles() -> Entity {
        let root = Entity()

        // Lenses are cylinders laid flat, which needs a rotation about X that
        // the pair helper's roll-only tilt can't express.
        for side in FaceLandmark.Side.allCases {
            root.addChild(.part(
                .generateCylinder(height: 0.010, radius: 0.026),
                color: UIColor(red: 0.20, green: 0.55, blue: 0.85, alpha: 1),
                at: FaceLandmark.mirrored(FaceLandmark.eye(.right) + [0, 0, 0.012], side),
                rotation: simd_quatf(angle: .pi / 2, axis: [1, 0, 0]),
                roughness: 0.15,
                metallic: true
            ))
        }

        root.add(
            // Arms running back towards the ear. The occlusion mesh is what
            // makes these read correctly when the head turns.
            Entity.pair(.generateBox(width: 0.075, height: 0.006, depth: 0.005, cornerRadius: 0.002),
                        color: Shade.charcoal,
                        at: FaceLandmark.eye(.right) + [0.030, 0.004, -0.030]),
            [.part(.generateBox(width: 0.022, height: 0.006, depth: 0.006, cornerRadius: 0.002),
                   color: Shade.charcoal,
                   at: FaceLandmark.noseBase + [0, 0.018, 0.012])]
        )
        return root
    }

    static func scuba() -> Entity {
        let root = Entity()
        root.addChild(.part(.generateBox(width: 0.130, height: 0.070, depth: 0.030, cornerRadius: 0.018),
                            color: Shade.charcoal,
                            at: FaceLandmark.browCentre + [0, -0.010, 0.020]))
        root.addChild(.part(.generateBox(width: 0.110, height: 0.052, depth: 0.010, cornerRadius: 0.014),
                            color: UIColor(red: 0.45, green: 0.75, blue: 0.85, alpha: 0.85),
                            at: FaceLandmark.browCentre + [0, -0.010, 0.038],
                            roughness: 0.05))
        root.addChild(.part(.generateBox(width: 0.150, height: 0.014, depth: 0.006, cornerRadius: 0.003),
                            color: Shade.charcoal,
                            at: FaceLandmark.browCentre + [0, 0.006, -0.030]))
        // Snorkel up one side.
        root.addChild(.part(.generateCylinder(height: 0.130, radius: 0.009),
                            color: Shade.gold,
                            at: FaceLandmark.temple(.right) + [0.024, 0.040, -0.006],
                            rotation: simd_quatf(angle: -0.12, axis: [0, 0, 1])))
        return root
    }
}
