#include <metal_stdlib>
using namespace metal;

/// M1 spike kernel. Copies the composited frame through, optionally killing the
/// green and blue channels so everything it touches reads as red.
///
/// It always writes to `target` — including when tint is 0 — because skipping
/// the write blanks the screen.
kernel void spikeTint(texture2d<half, access::read>  source [[texture(0)]],
                      texture2d<half, access::write> target [[texture(1)]],
                      constant float &tint                  [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= target.get_width() || gid.y >= target.get_height()) {
        return;
    }

    half4 color = source.read(gid);
    color.g = mix(color.g, half(0.0), half(tint));
    color.b = mix(color.b, half(0.0), half(tint));
    target.write(color, gid);
}
