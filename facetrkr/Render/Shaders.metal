#include <metal_stdlib>
using namespace metal;

/// Mirrors `WarpRegion` in FaceUniforms.swift.
struct WarpRegion {
    float2 centre;
    float2 direction;
    float  radius;
    int    kind;
    float  weight;
    float  padding;
};

/// Mirrors `WrinkleLine` in FaceUniforms.swift.
struct WrinkleLine {
    float2 start;
    float2 end;
    float  width;
    float  strength;
};

/// Mirrors `FaceUniforms` in FaceUniforms.swift.
struct FaceUniforms {
    float2 hullCentre;
    float2 browLeft;
    float2 browRight;
    float  hullRadius;
    int    regionCount;
    float  aspect;
    float  tint;
    float  wrinkle;
    int    wrinkleCount;
    float  ridge;
    float  desaturate;
    float  sallow;
    float  blotch;
    float  browGrey;
    float  browRadius;
    float  jawShade;
    float  padding;
};

/// Matching `WarpKind`.
constant int kWarpMagnify = 1;
constant int kWarpWiden   = 2;
constant int kWarpSquash  = 3;
constant int kWarpSwirl   = 4;
constant int kWarpPull    = 5;

/// The face is roughly this much taller than it is wide. Used to make the
/// hull an ellipse rather than a circle.
constant float kFaceAspect = 1.35;

constant float3 kLuma = float3(0.299f, 0.587f, 0.114f);

/// Distances are measured in aspect-corrected space so a radius describes a
/// circle on screen rather than an ellipse.
///
/// Anything that produces a radius for this shader has to measure in the same
/// space. `FaceSessionCoordinator` gets its eye span wrong if it does not, and
/// every radius and crease width comes out scaled by 1/aspect — a little over
/// twice too large on a phone.
inline float2 toLocal(float2 uv, float2 centre, float aspect) {
    return (uv - centre) * float2(aspect, 1.0f);
}

inline float2 fromLocal(float2 local, float2 centre, float aspect) {
    return centre + local / float2(aspect, 1.0f);
}

/// Smooth falloff to zero at the edge of the affected disc, so a warp blends
/// into the untouched frame rather than showing a seam.
inline float falloff(float distance, float radius) {
    if (radius <= 0.0f || distance >= radius) {
        return 0.0f;
    }
    float t = 1.0f - distance / radius;
    return t * t;
}

/// Pulls samples toward the centre, magnifying what is there.
inline float2 magnify(float2 uv, WarpRegion r, float aspect) {
    float2 local = toLocal(uv, r.centre, aspect);
    float amount = falloff(length(local), r.radius);
    if (amount <= 0.0f) { return uv; }
    return fromLocal(local * (1.0f - r.weight * amount), r.centre, aspect);
}

/// Widens horizontally and squashes vertically at the same time.
///
/// Sampling a narrower band makes the face read as wider; sampling a taller
/// band makes it read as shorter. Together that is the squashed grandma mouth.
inline float2 widen(float2 uv, WarpRegion r, float aspect) {
    float2 local = toLocal(uv, r.centre, aspect);
    float amount = falloff(length(local), r.radius);
    if (amount <= 0.0f) { return uv; }
    float w = r.weight * amount;
    local.x /= (1.0f + w);
    local.y *= (1.0f + w * 0.65f);
    return fromLocal(local, r.centre, aspect);
}

/// Compresses vertically only. A negative weight stretches instead.
inline float2 squash(float2 uv, WarpRegion r, float aspect) {
    float2 local = toLocal(uv, r.centre, aspect);
    float amount = falloff(length(local), r.radius);
    if (amount <= 0.0f) { return uv; }
    local.y *= (1.0f + r.weight * amount);
    return fromLocal(local, r.centre, aspect);
}

inline float2 swirl(float2 uv, WarpRegion r, float aspect) {
    float2 local = toLocal(uv, r.centre, aspect);
    float amount = falloff(length(local), r.radius);
    if (amount <= 0.0f) { return uv; }
    float angle = r.weight * amount;
    float s = sin(angle);
    float c = cos(angle);
    float2 rotated = float2(local.x * c - local.y * s, local.x * s + local.y * c);
    return fromLocal(rotated, r.centre, aspect);
}

/// Slides the image along `direction`, falling off from the centre.
///
/// Sampling from behind the direction of travel is what makes content appear
/// to move along it: to drag a jowl downward we read from further up the face.
/// Weight is a fraction of the radius, so a region stays self-consistent when
/// its radius is tuned.
inline float2 pull(float2 uv, WarpRegion r, float aspect) {
    float2 local = toLocal(uv, r.centre, aspect);
    float amount = falloff(length(local), r.radius);
    if (amount <= 0.0f) { return uv; }
    local -= r.direction * (r.weight * amount * r.radius);
    return fromLocal(local, r.centre, aspect);
}

inline float2 applyRegion(float2 uv, WarpRegion r, float aspect) {
    if (r.kind == kWarpMagnify) { return magnify(uv, r, aspect); }
    if (r.kind == kWarpWiden)   { return widen(uv, r, aspect); }
    if (r.kind == kWarpSquash)  { return squash(uv, r, aspect); }
    if (r.kind == kWarpSwirl)   { return swirl(uv, r, aspect); }
    if (r.kind == kWarpPull)    { return pull(uv, r, aspect); }
    return uv;
}

/// Signed vertical position within the face, in hull radii. Negative above the
/// centre. Used to keep sagging effects on the lower half.
inline float hullLocalY(float2 uv, constant FaceUniforms &u) {
    float2 local = toLocal(uv, u.hullCentre, u.aspect);
    return (local.y / kFaceAspect) / max(u.hullRadius, 1e-4f);
}

/// 1 inside the face, falling to 0 before the silhouette.
///
/// This is what stops a cheek warp dragging the background inward with it.
/// Snap confines its warps to a face proxy mesh; this is the cheap equivalent.
inline float faceHull(float2 uv, constant FaceUniforms &u) {
    float2 local = toLocal(uv, u.hullCentre, u.aspect);
    local.y /= kFaceAspect;
    float dist = length(local);
    return 1.0f - smoothstep(u.hullRadius * 0.80f, u.hullRadius * 1.20f, dist);
}

/// Soft ellipse over one eyebrow: wide and shallow.
inline float browMask(float2 uv, float2 centre, float radius, float aspect) {
    if (radius <= 0.0f) { return 0.0f; }
    float2 local = toLocal(uv, centre, aspect);
    local.y /= 0.45f;
    return 1.0f - smoothstep(radius * 0.55f, radius, length(local));
}

inline float hash21(float2 p) {
    p = fract(p * float2(123.34f, 456.21f));
    p += dot(p, p + 45.32f);
    return fract(p.x * p.y);
}

/// Smoothed value noise. Cheap, stable frame to frame, and enough for skin.
inline float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0f - 2.0f * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0f, 0.0f));
    float c = hash21(i + float2(0.0f, 1.0f));
    float d = hash21(i + float2(1.0f, 1.0f));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

/// How dark, and how bright, this pixel should go from the aged-skin lines.
///
/// `x` is the shadow in the fold, `y` is the highlight on its lit lip.
///
/// A crease drawn only as a dark line reads as pen on skin. A real fold has a
/// shadowed valley and a ridge beside it catching the light, and it is the
/// pairing that makes the eye accept it as geometry. Light is treated as
/// coming from above, which is where it is in nearly every selfie.
///
/// Each line is a capsule: distance to the segment, softened, taking the
/// strongest rather than summing so crossing creases do not turn into a blob.
inline float2 wrinkleShade(float2 uv,
                           constant WrinkleLine *lines,
                           int count,
                           float aspect) {
    float valley = 0.0f;
    float ridge = 0.0f;

    for (int i = 0; i < count; ++i) {
        float width = lines[i].width;
        if (width <= 0.0f) { continue; }

        float2 toStart = (uv - lines[i].start) * float2(aspect, 1.0f);
        float2 segment = (lines[i].end - lines[i].start) * float2(aspect, 1.0f);
        float lengthSquared = dot(segment, segment);
        // A zero-length line would make the normalize below NaN, and a NaN
        // here poisons the whole pixel rather than dropping one crease.
        if (lengthSquared < 1e-10f) { continue; }

        float t = clamp(dot(toStart, segment) / lengthSquared, 0.0f, 1.0f);
        float2 offset = toStart - segment * t;
        float distance = length(offset);

        // Fades at both ends so a crease tapers rather than stopping dead.
        float taper = smoothstep(0.0f, 0.22f, t) * smoothstep(0.0f, 0.22f, 1.0f - t);
        float strength = taper * lines[i].strength;

        if (distance < width) {
            float f = 1.0f - distance / width;
            valley = max(valley, f * f * strength);
        }

        // Screen y grows downward, so a negative component along the segment
        // normal is the upper side of the line.
        float2 normalDirection = normalize(float2(-segment.y, segment.x));
        if (dot(offset, normalDirection) >= 0.0f) { continue; }

        float ridgeCentre = width * 1.15f;
        float ridgeWidth = width * 0.85f;
        float ridgeDistance = abs(distance - ridgeCentre);
        if (ridgeDistance < ridgeWidth) {
            float f = 1.0f - ridgeDistance / ridgeWidth;
            ridge = max(ridge, f * f * strength);
        }
    }

    return float2(valley, ridge);
}

/// Everything that makes skin look old apart from the creases themselves.
///
/// Lines alone do not age a face. Skin that has aged is greyer, yellower,
/// flatter in contrast and unevenly pigmented, and an airbrushed complexion
/// reads young however much is drawn on it. All of it is confined to the face
/// hull so none of it lands on the background.
inline half3 ageSkin(half3 rgb, float2 uv, float hull, constant FaceUniforms &u) {
    float luma = dot(float3(rgb), kLuma);

    float grey = u.desaturate * hull;
    if (grey > 0.0f) {
        rgb = mix(rgb, half3(half(luma)), half(grey));
        // Older skin is flatter: lift the blacks and pull the whites in.
        rgb = mix(rgb, rgb * 0.88h + 0.10h, half(grey));
    }

    float warm = u.sallow * hull;
    if (warm > 0.0f) {
        rgb = rgb * half3(half(1.0f + warm * 0.07f),
                          half(1.0f + warm * 0.03f),
                          half(1.0f - warm * 0.08f));
    }

    if (u.blotch > 0.0f && hull > 0.0f) {
        float mottle = valueNoise(uv * 34.0f) * 0.65f + valueNoise(uv * 91.0f) * 0.35f;
        rgb *= half(1.0f - (mottle - 0.5f) * u.blotch * hull * 0.55f);
    }

    if (u.jawShade > 0.0f && hull > 0.0f) {
        // A soft band around the lower edge of the hull: the shadow under a
        // jaw that has lost its line.
        float2 local = toLocal(uv, u.hullCentre, u.aspect);
        local.y /= kFaceAspect;
        float d = length(local) / max(u.hullRadius, 1e-4f);
        float band = smoothstep(0.55f, 0.95f, d) * (1.0f - smoothstep(0.95f, 1.20f, d));
        float below = smoothstep(-0.10f, 0.45f, hullLocalY(uv, u));
        rgb *= half(1.0f - band * below * u.jawShade * 0.45f);
    }

    return rgb;
}

/// Greys the eyebrows, keyed on how dark the pixel already is.
///
/// Keying on darkness is what keeps this off the skin around the brow: only
/// the hair is dark enough to be affected, so no mask precision is needed.
inline half3 greyBrows(half3 rgb, float2 uv, constant FaceUniforms &u) {
    if (u.browGrey <= 0.0f || u.browRadius <= 0.0f) { return rgb; }

    float mask = max(browMask(uv, u.browLeft, u.browRadius, u.aspect),
                     browMask(uv, u.browRight, u.browRadius, u.aspect));
    if (mask <= 0.0f) { return rgb; }

    float luma = dot(float3(rgb), kLuma);
    float hairness = 1.0f - smoothstep(0.16f, 0.42f, luma);
    float amount = mask * hairness * u.browGrey;
    if (amount <= 0.0f) { return rgb; }

    return mix(rgb, half3(half(mix(luma, 0.66f, 0.80f))), half(amount));
}

/// Composites the finished frame to screen, applying the warp, and optionally
/// to a copy the recorder downscales from.
///
/// `target` is always written, including when nothing is applied. Skipping the
/// write leaves the drawable undefined and the screen goes black.
kernel void composite(texture2d<half, access::sample> source   [[texture(0)]],
                      texture2d<half, access::write>  target   [[texture(1)]],
                      texture2d<half, access::write>  work     [[texture(2)]],
                      constant FaceUniforms &uniforms          [[buffer(0)]],
                      constant WarpRegion *regions             [[buffer(1)]],
                      constant WrinkleLine *wrinkles           [[buffer(2)]],
                      uint2 gid [[thread_position_in_grid]])
{
    const uint width = target.get_width();
    const uint height = target.get_height();
    if (gid.x >= width || gid.y >= height) {
        return;
    }

    constexpr sampler frameSampler(filter::linear,
                                   address::clamp_to_edge,
                                   coord::normalized);

    float2 uv = (float2(gid) + 0.5f) / float2(width, height);

    // Every region displaces the coordinate in turn, then the whole
    // displacement is faded out at the edge of the face. Masking the result
    // rather than each region keeps overlapping warps consistent.
    float2 warped = uv;
    for (int i = 0; i < uniforms.regionCount; ++i) {
        warped = applyRegion(warped, regions[i], uniforms.aspect);
    }
    float hull = faceHull(uv, uniforms);
    uv = mix(uv, warped, hull);

    half4 color = source.sample(frameSampler, uv);

    // Everything below is sampled at the warped coordinate and masked by the
    // hull, so the skin treatment travels with the distortion rather than
    // sliding across it, and none of it lands off the face.
    if (hull > 0.0f) {
        // Creases multiply the camera rather than painting over it, so they
        // darken the real skin and keep its tone and lighting.
        if (uniforms.wrinkle > 0.0f && uniforms.wrinkleCount > 0) {
            float2 crease = wrinkleShade(uv, wrinkles, uniforms.wrinkleCount, uniforms.aspect);
            color.rgb *= half3(half(1.0f - crease.x * uniforms.wrinkle * hull));
            color.rgb += half3(half(crease.y * uniforms.ridge * hull * 0.22f));
        }

        color.rgb = ageSkin(color.rgb, uv, hull, uniforms);
        color.rgb = greyBrows(color.rgb, uv, uniforms);
        color.rgb = clamp(color.rgb, half3(0.0h), half3(1.0h));
    }

    // M1 spike: killing green and blue makes everything this kernel touches
    // read as red, which is how we tell whether `source` carries the camera
    // passthrough or only the rendered 3D content.
    color.g = mix(color.g, half(0.0), half(uniforms.tint));
    color.b = mix(color.b, half(0.0), half(uniforms.tint));

    target.write(color, gid);

    if (!is_null_texture(work)) {
        work.write(color, gid);
    }
}

/// Scales the full-resolution frame down to the encode size.
///
/// The drawable is around 1206x2622 on a recent Pro, which is both an awkward
/// shape and more pixels than is worth encoding. Linear sampling here is
/// cheaper and cleaner than asking the encoder to rescale.
kernel void downscaleToRecord(texture2d<half, access::sample> source [[texture(0)]],
                              texture2d<half, access::write>  target [[texture(1)]],
                              uint2 gid [[thread_position_in_grid]])
{
    const uint width = target.get_width();
    const uint height = target.get_height();
    if (gid.x >= width || gid.y >= height) {
        return;
    }

    constexpr sampler linearSampler(filter::linear,
                                    address::clamp_to_edge,
                                    coord::normalized);

    float2 uv = (float2(gid) + 0.5f) / float2(width, height);
    half4 color = source.sample(linearSampler, uv);

    // The encoder wants opaque pixels; a stray alpha shows up as a washed-out
    // recording on some players.
    color.a = 1.0h;
    target.write(color, gid);
}
