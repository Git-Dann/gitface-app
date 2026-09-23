#include <metal_stdlib>
using namespace metal;

/// Mirrors `FaceUniforms` in FaceUniforms.swift. Field order and types must
/// stay in step with the Swift side.
struct FaceUniforms {
    float2 leftEye;
    float2 rightEye;
    float2 mouth;
    float2 centre;
    float  radius;
    int    effect;
    float  strength;
    float  tint;
    float  aspect;
    float  padding;
};

/// Effect identifiers, matching `FaceEffect`'s raw values.
constant int kEffectNone       = 0;
constant int kEffectBulgeEyes  = 1;
constant int kEffectStretchJaw = 2;
constant int kEffectBigHead    = 3;
constant int kEffectSwirl      = 4;

/// Distance is measured in aspect-corrected space so the falloff region is a
/// circle on screen rather than an ellipse.
inline float2 toLocal(float2 uv, float2 centre, float aspect) {
    return (uv - centre) * float2(aspect, 1.0f);
}

inline float2 fromLocal(float2 local, float2 centre, float aspect) {
    return centre + local / float2(aspect, 1.0f);
}

/// Smooth falloff to zero at the edge of the affected disc, so the effect
/// blends into the untouched frame instead of showing a hard seam.
inline float falloff(float distance, float radius) {
    if (distance >= radius) {
        return 0.0f;
    }
    float t = 1.0f - distance / radius;
    return t * t;
}

/// Pulls samples towards the centre, which magnifies what is there.
inline float2 magnify(float2 uv, float2 centre, float radius, float strength, float aspect) {
    float2 local = toLocal(uv, centre, aspect);
    float distance = length(local);
    float amount = falloff(distance, radius);
    if (amount <= 0.0f) {
        return uv;
    }
    return fromLocal(local * (1.0f - strength * amount), centre, aspect);
}

/// Compresses vertically, which reads as the jaw being pulled long.
inline float2 stretchVertically(float2 uv, float2 centre, float radius, float strength, float aspect) {
    float2 local = toLocal(uv, centre, aspect);
    float amount = falloff(length(local), radius);
    if (amount <= 0.0f) {
        return uv;
    }
    local.y /= (1.0f + strength * amount);
    return fromLocal(local, centre, aspect);
}

inline float2 swirl(float2 uv, float2 centre, float radius, float strength, float aspect) {
    float2 local = toLocal(uv, centre, aspect);
    float amount = falloff(length(local), radius);
    if (amount <= 0.0f) {
        return uv;
    }
    float angle = strength * amount;
    float s = sin(angle);
    float c = cos(angle);
    float2 rotated = float2(local.x * c - local.y * s, local.x * s + local.y * c);
    return fromLocal(rotated, centre, aspect);
}

inline float2 applyEffect(float2 uv, constant FaceUniforms &u) {
    if (u.effect == kEffectNone || u.strength <= 0.0f) {
        return uv;
    }

    if (u.effect == kEffectBulgeEyes) {
        // Each eye gets its own smaller disc, applied in sequence so the two
        // regions can overlap at the bridge of the nose without fighting.
        float eyeRadius = u.radius * 0.45f;
        uv = magnify(uv, u.leftEye,  eyeRadius, u.strength, u.aspect);
        uv = magnify(uv, u.rightEye, eyeRadius, u.strength, u.aspect);
        return uv;
    }

    if (u.effect == kEffectStretchJaw) {
        return stretchVertically(uv, u.mouth, u.radius * 0.8f, u.strength, u.aspect);
    }

    if (u.effect == kEffectBigHead) {
        return magnify(uv, u.centre, u.radius * 1.6f, u.strength, u.aspect);
    }

    if (u.effect == kEffectSwirl) {
        return swirl(uv, u.centre, u.radius * 1.2f, u.strength, u.aspect);
    }

    return uv;
}

/// Composites the finished frame to screen, applying any distortion, and
/// optionally to a copy the recorder downscales from.
///
/// `target` is always written, including when nothing is applied. Skipping the
/// write leaves the drawable undefined and the screen goes black.
///
/// `work` is bound only while recording, and is the same size as `target` so a
/// single grid covers both. Recording taps this rather than `target` because a
/// drawable is not guaranteed to be readable, and because the warped result
/// has to reach the encoder exactly as it reached the screen.
kernel void composite(texture2d<half, access::sample> source [[texture(0)]],
                      texture2d<half, access::write>  target [[texture(1)]],
                      texture2d<half, access::write>  work   [[texture(2)]],
                      constant FaceUniforms &uniforms        [[buffer(0)]],
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
    half4 color = source.sample(frameSampler, applyEffect(uv, uniforms));

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
