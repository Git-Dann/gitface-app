#include <metal_stdlib>
using namespace metal;

/// Composites the finished frame to screen, and optionally to a copy the
/// recorder can downscale from.
///
/// `target` is always written, including when nothing is applied. Skipping the
/// write leaves the drawable undefined and the screen goes black.
///
/// `work` is bound only while recording. It is the same size as `target` so a
/// single grid covers both. Recording taps this rather than `target` because a
/// drawable is not guaranteed to be readable, and because M4's warp effects
/// need somewhere to land that both the screen and the encoder can see.
kernel void composite(texture2d<half, access::read>  source [[texture(0)]],
                      texture2d<half, access::write> target [[texture(1)]],
                      texture2d<half, access::write> work   [[texture(2)]],
                      constant float &tint                  [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= target.get_width() || gid.y >= target.get_height()) {
        return;
    }

    half4 color = source.read(gid);

    // M1 spike: killing green and blue makes everything this kernel touches
    // read as red, which is how we tell whether `source` includes the camera
    // passthrough or only the rendered 3D content.
    color.g = mix(color.g, half(0.0), half(tint));
    color.b = mix(color.b, half(0.0), half(tint));

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
