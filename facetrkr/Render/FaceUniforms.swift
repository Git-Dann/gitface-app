import simd

/// Distortion effects. Raw values are read by `Shaders.metal`, so the order
/// here and the switch there must stay in step.
enum FaceEffect: Int32, CaseIterable, Identifiable {
    case none = 0
    case bulgeEyes = 1
    case stretchJaw = 2
    case bigHead = 3
    case swirl = 4

    var id: Int32 { rawValue }

    var name: String {
        switch self {
        case .none:       "Off"
        case .bulgeEyes:  "Eyes"
        case .stretchJaw: "Jaw"
        case .bigHead:    "Big head"
        case .swirl:      "Swirl"
        }
    }

    var symbol: String {
        switch self {
        case .none:       "circle.slash"
        case .bulgeEyes:  "eye.fill"
        case .stretchJaw: "mouth.fill"
        case .bigHead:    "circle.circle.fill"
        case .swirl:      "tornado"
        }
    }

    /// How hard the effect pushes at full intensity. Tuned per effect because
    /// a swirl angle and a radial magnification are not the same units.
    var maximumStrength: Float {
        switch self {
        case .none:       0
        case .bulgeEyes:  0.55
        case .stretchJaw: 1.20
        case .bigHead:    0.45
        case .swirl:      2.20
        }
    }
}

/// Shared with the `FaceUniforms` struct in `Shaders.metal`.
///
/// Field order and types must match exactly. `SIMD2<Float>` is 8-byte aligned
/// on both sides, so the four pairs pack first and the scalars follow.
struct FaceUniforms {
    var leftEye = SIMD2<Float>(0.35, 0.35)
    var rightEye = SIMD2<Float>(0.65, 0.35)
    var mouth = SIMD2<Float>(0.50, 0.62)
    var centre = SIMD2<Float>(0.50, 0.45)
    var radius: Float = 0.22
    var effect: Int32 = FaceEffect.none.rawValue
    var strength: Float = 0
    var tint: Float = 0
    /// Drawable aspect, so radial effects stay circular rather than elliptical.
    var aspect: Float = 0.5
    var padding: Float = 0
}
