import simd

/// How a single region distorts the image beneath it.
///
/// Raw values are read by `Shaders.metal`, so the order here and the constants
/// there must stay in step.
enum WarpKind: Int32 {
    /// Pulls samples toward the centre, which magnifies what is there.
    case magnify = 1
    /// Widens horizontally and squashes vertically. The grandma mouth.
    case widen = 2
    /// Compresses vertically only.
    case squash = 3
    case swirl = 4
    /// Slides the image along a direction. The radial kinds cannot express a
    /// jowl or a downturned mouth corner, which are the shapes that read as
    /// age; both are one-way displacements, not symmetrical bulges.
    case pull = 5
}

/// A point on the face a warp attaches to.
///
/// Positions come from ARKit's real eye transforms and proportions derived from
/// them, rather than fixed constants, so a warp lands in the same place on any
/// face at any distance.
enum WarpAnchor {
    case leftEye, rightEye
    case leftCheek, rightCheek
    case leftJowl, rightJowl
    case mouth
    case chin
    case noseTip
    case brow
    case faceCentre
}

/// One distortion in a style. A style is several of these at once, which is
/// what the previous single-effect model could not express.
struct WarpSpec {
    var anchor: WarpAnchor
    var kind: WarpKind
    /// Radius in eye-spans, so it scales with the face rather than the screen.
    var radius: Float
    /// Snap's face-stretch weights run roughly -0.5 to 2.0, where a negative
    /// value inverts the effect. Worth matching; the range is well judged.
    var weight: Float
    /// Which way `.pull` drags, in screen space where +y is down. Ignored by
    /// every other kind.
    var direction: SIMD2<Float> = SIMD2(0, 1)
    /// Winds the weight up as the mouth opens.
    var jawDriven: Bool = false
}

/// What a lens does to skin, as opposed to what it does to shape.
///
/// Separate from the warp because they fail differently: a warp that is too
/// strong looks like a funhouse mirror, whereas skin that is too strong looks
/// painted on. They want tuning independently.
struct SkinTreatment {
    /// How strongly creases are multiplied over the camera.
    var creases: Float = 0
    /// How brightly the lit side of each crease is raised.
    ///
    /// A fold in skin is a dark valley *and* a bright ridge. Drawing only the
    /// shadow is what made the first attempt read as pen marks.
    var ridge: Float = 0
    /// Toward grey. Age takes saturation out of skin.
    var desaturate: Float = 0
    /// Toward yellow. Sallowness is a stronger age cue than wrinkles alone.
    var sallow: Float = 0
    /// Uneven pigmentation. Without it the face looks airbrushed, which reads
    /// young however many lines are drawn on it.
    var blotch: Float = 0
    /// Greys the eyebrows. Cheap, and one of the strongest cues there is.
    var browGrey: Float = 0
    /// Darkens the underside of the jaw, which is where sagging shows.
    var jawShade: Float = 0

    static let none = SkinTreatment()

    static let aged = SkinTreatment(
        creases: 0.55,
        ridge: 0.45,
        desaturate: 0.22,
        sallow: 0.18,
        blotch: 0.28,
        browGrey: 0.70,
        jawShade: 0.30
    )
}

/// A named set of distortions applied together.
struct WarpStyle: Identifiable {
    let id: String
    let name: String
    let symbol: String
    let specs: [WarpSpec]
    var skin: SkinTreatment = .none

    static let none = WarpStyle(id: "none", name: "Off", symbol: "circle.slash", specs: [])

    static let bulgeEyes = WarpStyle(
        id: "eyes", name: "Eyes", symbol: "eye.fill",
        specs: [
            WarpSpec(anchor: .leftEye, kind: .magnify, radius: 0.55, weight: 0.55, jawDriven: true),
            WarpSpec(anchor: .rightEye, kind: .magnify, radius: 0.55, weight: 0.55, jawDriven: true)
        ]
    )

    static let stretchJaw = WarpStyle(
        id: "jaw", name: "Jaw", symbol: "mouth.fill",
        specs: [WarpSpec(anchor: .mouth, kind: .squash, radius: 1.1, weight: -0.9, jawDriven: true)]
    )

    static let bigHead = WarpStyle(
        id: "bighead", name: "Big head", symbol: "circle.circle.fill",
        specs: [WarpSpec(anchor: .faceCentre, kind: .magnify, radius: 2.2, weight: 0.45)]
    )

    static let swirl = WarpStyle(
        id: "swirl", name: "Swirl", symbol: "tornado",
        specs: [WarpSpec(anchor: .faceCentre, kind: .swirl, radius: 1.8, weight: 2.0, jawDriven: true)]
    )

    /// The reference lens, read off the photograph.
    ///
    /// Deliberately a caricature rather than clinical ageing: real ageing
    /// hollows the midface, but the Snapchat lens puffs the cheeks out, and
    /// that is the look being matched.
    ///
    /// Eleven regions, because the shape only reads as a whole. Puffed cheeks
    /// alone are a baby; narrowed eyes alone are a squint. Together with the
    /// sagging jowls and the wide flat mouth they are an old lady.
    ///
    /// Every radius is in eye-spans and every weight was set against the
    /// corrected screen scale — see the note on `span` in
    /// `FaceSessionCoordinator`, which was measuring 2.2x too large and made
    /// all of this read as a soft smear.
    static let grandma = WarpStyle(
        id: "grandma", name: "Grandma", symbol: "figure.dress.line.vertical.figure",
        specs: [
            // The cheeks carry the silhouette.
            WarpSpec(anchor: .leftCheek, kind: .magnify, radius: 0.85, weight: 0.75),
            WarpSpec(anchor: .rightCheek, kind: .magnify, radius: 0.85, weight: 0.75),

            // Wide and flattened, winding up as the mouth opens.
            WarpSpec(anchor: .mouth, kind: .widen, radius: 1.00, weight: 0.80, jawDriven: true),

            // Narrowed eyes under a lowered brow.
            WarpSpec(anchor: .leftEye, kind: .squash, radius: 0.45, weight: 0.35),
            WarpSpec(anchor: .rightEye, kind: .squash, radius: 0.45, weight: 0.35),
            WarpSpec(anchor: .brow, kind: .pull, radius: 0.90, weight: 0.22,
                     direction: SIMD2(0, 1)),

            // The sag. Nothing else here can express a one-way droop.
            WarpSpec(anchor: .leftJowl, kind: .pull, radius: 0.70, weight: 0.38,
                     direction: SIMD2(0, 1)),
            WarpSpec(anchor: .rightJowl, kind: .pull, radius: 0.70, weight: 0.38,
                     direction: SIMD2(0, 1)),

            // A shortened chin under a slightly heavier nose.
            WarpSpec(anchor: .chin, kind: .squash, radius: 0.60, weight: 0.30),
            WarpSpec(anchor: .noseTip, kind: .magnify, radius: 0.40, weight: 0.25),

            // A touch of overall roundness to tie it together.
            WarpSpec(anchor: .faceCentre, kind: .magnify, radius: 2.00, weight: 0.12)
        ],
        skin: .aged
    )

    static let all: [WarpStyle] = [none, grandma, bulgeEyes, stretchJaw, bigHead, swirl]
}

/// Live multipliers for the debug tuning panel.
///
/// Every weight in `WarpStyle` is a guess until it is seen on a real face, and
/// "old enough" is not a judgement that can be made away from the device. These
/// scale the baked-in values so they can be dialled in on the phone and read
/// back, rather than costing a TestFlight round each.
struct LensTuning {
    var warp: Float = 1
    var crease: Float = 1
    var ridge: Float = 1
    var desaturate: Float = 1
    var blotch: Float = 1
    var browGrey: Float = 1

    static let neutral = LensTuning()
}

// MARK: - Shared with Metal

/// Mirrors `WarpRegion` in `Shaders.metal`. 32 bytes, 8-byte aligned.
struct WarpRegion {
    var centre = SIMD2<Float>(0.5, 0.5)
    /// Only `.pull` reads this.
    var direction = SIMD2<Float>(0, 1)
    var radius: Float = 0
    var kind: Int32 = 0
    var weight: Float = 0
    var padding: Float = 0
}

/// One aged-skin line. Mirrors `WrinkleLine` in `Shaders.metal`.
///
/// Drawn rather than textured, because the alternative does not work: a face
/// texture can only alpha-blend in RealityKit, which reads as paint. Multiply
/// is what makes a crease darken real skin while keeping the subject's own
/// tone, and multiply is only available where we own the pixels — this pass.
struct WrinkleLine {
    var start = SIMD2<Float>.zero
    var end = SIMD2<Float>.zero
    var width: Float = 0
    var strength: Float = 0
}

/// Mirrors `FaceUniforms` in `Shaders.metal`. 80 bytes, 8-byte aligned.
///
/// Regions travel in their own buffer rather than inline here, because Swift
/// has no fixed-size array that maps cleanly onto a Metal array member.
///
/// The three `SIMD2` members come first so both compilers agree on the layout
/// without padding games: 8-byte aligned pairs, then everything 4-byte.
struct FaceUniforms {
    /// Centre and radius of the face, used to fade the warp out before it
    /// reaches the silhouette. Without this a cheek bulge near the edge of the
    /// face drags the background inward with it.
    var hullCentre = SIMD2<Float>(0.5, 0.45)
    var browLeft = SIMD2<Float>(0.42, 0.38)
    var browRight = SIMD2<Float>(0.58, 0.38)
    var hullRadius: Float = 0.25
    var regionCount: Int32 = 0
    /// Drawable aspect, so radial warps stay circular rather than elliptical.
    var aspect: Float = 0.5
    var tint: Float = 0
    var wrinkle: Float = 0
    var wrinkleCount: Int32 = 0
    var ridge: Float = 0
    var desaturate: Float = 0
    var sallow: Float = 0
    var blotch: Float = 0
    var browGrey: Float = 0
    var browRadius: Float = 0
    var jawShade: Float = 0
    var padding: Float = 0
}

extension FaceUniforms {
    /// How many regions the shader will read. Fixed so the buffer is a constant
    /// size and never needs reallocating on the render thread.
    static let maximumRegions = 16
    static let maximumWrinkles = 24
}

/// Everything the kernel needs for one frame, computed on ARKit's delegate
/// queue and handed over in a single locked write.
///
/// Grouped rather than passed as a dozen arguments because it is one atomic
/// update: a half-applied lens shows a warp with the wrong hull for a frame.
struct FaceFrame {
    var regions: [WarpRegion] = []
    var wrinkles: [WrinkleLine] = []
    var skin: SkinTreatment = .none
    var hullCentre = SIMD2<Float>(0.5, 0.45)
    var hullRadius: Float = 0.25
    var browLeft = SIMD2<Float>(0.42, 0.38)
    var browRight = SIMD2<Float>(0.58, 0.38)
    var browRadius: Float = 0
}
