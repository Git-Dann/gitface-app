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
    /// High on the skull and low on the jaw. A pinch at one and a bulge at the
    /// other is what makes a head pear-shaped, which is the shape the reference
    /// lens actually produces.
    case crown
    case lowerFace
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
    /// every other kind, and overridden when `outward` is set.
    var direction: SIMD2<Float> = SIMD2(0, 1)
    /// Drags away from the face centre instead of along `direction`.
    ///
    /// The jowls pull sideways, and which side is which depends on the mirroring
    /// of the preview and on which way the anchor's X axis points. Deriving the
    /// direction from the projected positions settles it at runtime rather than
    /// baking in a guess that is right on one device and inverted on another.
    var outward: Bool = false
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

    /// Deliberately faint.
    ///
    /// The reference photograph has no aged-skin treatment at all: no wrinkle
    /// overlay, no desaturation, no age spots. Its whole "old" read comes from
    /// the grey hair, the rollers, the glasses and the face shape. Rendered
    /// offline at the strength this used to ship at, the face goes grey and
    /// muddy and looks grimy rather than old.
    ///
    /// So this is a hint rather than a treatment, and the debug slider scales
    /// it if more is wanted.
    static let aged = SkinTreatment(
        creases: 0.16,
        ridge: 0.14,
        desaturate: 0.05,
        sallow: 0.05,
        blotch: 0.07,
        browGrey: 0.45,
        jawShade: 0.08
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

    /// The reference lens.
    ///
    /// Described by Dan off the photograph, and it is three things rather than
    /// the pile of regions this used to be: the top of the head is pinched, the
    /// bottom half is bloated, and the mouth is slightly widened. Together they
    /// make the head pear-shaped, which is what leaves room for the rollers.
    ///
    /// Everything before this was too strong and the wrong shape. The cheeks
    /// were `magnify`, which drags the outline inward rather than out; then a
    /// single `widen` across the whole face, which bloats the top as much as
    /// the bottom and so cannot make a pear. A negative `widen` high on the
    /// skull is the pinch, a positive one low is the bulge.
    static let grandma = WarpStyle(
        id: "grandma", name: "Grandma", symbol: "figure.dress.line.vertical.figure",
        specs: [
            // Pinch. A negative weight samples wider than it draws, so the
            // skull reads narrower.
            WarpSpec(anchor: .crown, kind: .widen, radius: 1.50, weight: -0.28),

            // Bloat, over the jaw and cheeks.
            WarpSpec(anchor: .lowerFace, kind: .widen, radius: 1.60, weight: 0.34),

            // Slightly extended, and winding up as the mouth opens.
            WarpSpec(anchor: .mouth, kind: .widen, radius: 0.80, weight: 0.22,
                     jawDriven: true)
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
