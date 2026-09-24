#include <metal_stdlib>
using namespace metal;

/// Mirrors `WarpRegion` in FaceUniforms.swift.
struct WarpRegion {
    float2 centre;
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
    float  hullRadius;
    int    regionCount;
    float  aspect;
    float  tint;
    float  wrinkle;
    int    wrinkleCount;
};

/// Matching `WarpKind`.
constant int kWarpMagnify = 1;
constant int kWarpWiden   = 2;
constant int kWarpSquash  = 3;
constant int kWarpSwirl   = 4;

/// The face is roughly this much taller than it is wide. Used to make the
/// hull an ellipse rather than a circle.
constant float kFaceAspect = 1.35;

/// Distances are measured in aspect-corrected space so a radius describes a
/// circle on screen rather than an ellipse.
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

inline float2 applyRegion(float2 uv, WarpRegion r, float aspect) {
    if (r.kind == kWarpMagnify) { return magnify(uv, r, aspect); }
    if (r.kind == kWarpWiden)   { return widen(uv, r, aspect); }
    if (r.kind == kWarpSquash)  { return squash(uv, r, aspect); }
    if (r.kind == kWarpSwirl)   { return swirl(uv, r, aspect); }
    return uv;
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

/// How dark this pixel should go from the aged-skin lines.
///
/// Each line is a capsule: distance to the segment, softened, taking the
/// strongest rather than summing so crossing creases do not turn into a blob.
inline float wrinkleShade(float2 uv,
                          constant WrinkleLine *lines,
                          int count,
                          float aspect) {
    float shade = 0.0f;
    for (int i = 0; i < count; ++i) {
        float2 toStart = (uv - lines[i].start) * float2(aspect, 1.0f);
        float2 segment = (lines[i].end - lines[i].start) * float2(aspect, 1.0f);
        float lengthSquared = max(dot(segment, segment), 1e-8f);
        float t = clamp(dot(toStart, segment) / lengthSquared, 0.0f, 1.0f);
        float distance = length(toStart - segment * t);

        float width = lines[i].width;
        if (width > 0.0f && distance < width) {
            float falloff = 1.0f - distance / width;
            // Fades at both ends so a crease tapers rather than stopping dead.
            float taper = smoothstep(0.0f, 0.22f, t) * smoothstep(0.0f, 0.22f, 1.0f - t);
            shade = max(shade, falloff * falloff * taper * lines[i].strength);
        }
    }
    return shade;
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

    // Creases multiply the camera rather than painting over it, so they darken
    // the real skin and keep its tone and lighting. Sampled at the warped
    // coordinate so the lines travel with the distortion rather than sliding
    // across it, and masked by the hull so none of it lands off the face.
    if (uniforms.wrinkle > 0.0f && uniforms.wrinkleCount > 0) {
        float shade = wrinkleShade(uv, wrinkles, uniforms.wrinkleCount, uniforms.aspect);
        color.rgb *= half3(1.0f - shade * uniforms.wrinkle * hull);
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
