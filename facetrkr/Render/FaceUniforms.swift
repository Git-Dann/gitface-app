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
}

/// A point on the face a warp attaches to.
///
/// Positions come from ARKit's real eye transforms and proportions derived from
/// them, rather than fixed constants, so a warp lands in the same place on any
/// face at any distance.
enum WarpAnchor {
    case leftEye, rightEye
    case leftCheek, rightCheek
    case mouth
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
    /// Winds the weight up as the mouth opens.
    var jawDriven: Bool = false
}

/// A named set of distortions applied together.
struct WarpStyle: Identifiable {
    let id: String
    let name: String
    let symbol: String
    let specs: [WarpSpec]
    /// How strongly aged-skin lines are multiplied over the camera. Zero for
    /// everything that is not trying to look old.
    var wrinkles: Float = 0

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
    /// The cheeks push out, the mouth widens and squashes upward, and the eyes
    /// narrow. Doing all four at once is the whole point — any one of them
    /// alone reads as a glitch rather than a face.
    static let grandma = WarpStyle(
        id: "grandma", name: "Grandma", symbol: "figure.dress.line.vertical.figure",
        specs: [
            WarpSpec(anchor: .leftCheek, kind: .magnify, radius: 0.85, weight: 0.42),
            WarpSpec(anchor: .rightCheek, kind: .magnify, radius: 0.85, weight: 0.42),
            WarpSpec(anchor: .mouth, kind: .widen, radius: 1.15, weight: 0.55, jawDriven: true),
            WarpSpec(anchor: .leftEye, kind: .squash, radius: 0.5, weight: 0.30),
            WarpSpec(anchor: .rightEye, kind: .squash, radius: 0.5, weight: 0.30)
        ],
        wrinkles: 0.55
    )

    static let all: [WarpStyle] = [none, grandma, bulgeEyes, stretchJaw, bigHead, swirl]
}

// MARK: - Shared with Metal

/// Mirrors `WarpRegion` in `Shaders.metal`. 24 bytes, 8-byte aligned.
struct WarpRegion {
    var centre = SIMD2<Float>(0.5, 0.5)
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

/// Mirrors `FaceUniforms` in `Shaders.metal`.
///
/// Regions travel in their own buffer rather than inline here, because Swift
/// has no fixed-size array that maps cleanly onto a Metal array member.
struct FaceUniforms {
    /// Centre and radius of the face, used to fade the warp out before it
    /// reaches the silhouette. Without this a cheek bulge near the edge of the
    /// face drags the background inward with it.
    var hullCentre = SIMD2<Float>(0.5, 0.45)
    var hullRadius: Float = 0.25
    var regionCount: Int32 = 0
    /// Drawable aspect, so radial warps stay circular rather than elliptical.
    var aspect: Float = 0.5
    var tint: Float = 0
    var wrinkle: Float = 0
    var wrinkleCount: Int32 = 0
}

extension FaceUniforms {
    /// How many regions the shader will read. Fixed so the buffer is a constant
    /// size and never needs reallocating on the render thread.
    static let maximumRegions = 8
    static let maximumWrinkles = 20
}
