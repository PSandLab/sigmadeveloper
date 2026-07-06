// Profiled wavelet denoise on scene-linear RGB
//
// Edge-avoiding à-trous (undecimated B3-spline) wavelet decomposition with
// per-pixel variance stabilisation from a Poisson-Gaussian sensor model
//   sigma²(x) = a + b·x        (per channel, EV gain folded in by the host)
// and soft shrinkage of the detail coefficients per scale — the same family of
// algorithm as vkdt's denoise module and darktable's wavelet profile denoise,
// written from the literature (Starck's à-trous tables, Fisz normalisation).
//
// The SD14 sensor has no analog gain: ISO is a metadata push over a fixed
// base sensitivity, so one base profile plus the exactly-known digital gain
// describes every shot
//
// Detail coefficients split into a mean (luma) part and a colour-residual
// (chroma) part so Foveon's dominant chroma noise can be shrunk harder than
// luma without smearing edges — the edge-stopping weight looks at all three
// channels in noise-sigma units

#include <metal_stdlib>
using namespace metal;

struct DenoiseParams {
    float4 sig_a;    // per-channel gaussian variance, post-EV working units
    float4 sig_b;    // per-channel poissonian slope,   post-EV working units
    float  t_luma;   // luma shrink threshold, × local sigma (level norm folded in)
    float  t_chroma; // chroma-residual shrink threshold, × local sigma
    float  edge;     // edge-stop softness in sigma units
    int    spacing;  // à-trous tap spacing = 2^level
    int    first;    // 1 on level 0: ignore removedIn (fresh private texture)
};

// 1D B3-spline kernel; 2D tap weight = h[i]·h[j]
constant float b3[5] = { 1.0/16, 4.0/16, 6.0/16, 4.0/16, 1.0/16 };

/// make a level-0 texel safe for the pyramid arithmetic, 2^14 cap, prevent overflow
static inline float3 sanitize(float3 v) {
    const uint3 bits = as_type<uint3>(v);
    const bool3 nonfinite = (bits & 0x7f800000) == 0x7f800000; // inf or NaN exponent
    const bool3 nan = nonfinite && ((bits & 0x007fffff) != 0);
    const float3 capped = select(copysign(float3(16384.0), v), float3(0.0), nan);
    return select(clamp(v, -16384.0, 16384.0), capped, nonfinite);
}

// Non-negative garrote: kills |d| ≤ t like soft shrinkage but asymptotes to
// identity for strong coefficients, so real detail is not biased down by t.
static inline float3 shrink(float3 d, float3 t) {
    return d * max(1.0 - (t * t) / max(d * d, 1e-20), 0.0);
}

static inline float shrink1(float d, float t) {
    return d * max(1.0f - (t * t) / max(d * d, 1e-20f), 0.0f);
}

static inline float3 noiseSigma(float3 x, constant DenoiseParams& p) {
    return sqrt(max(p.sig_a.rgb + p.sig_b.rgb * max(x, 0.0), 1e-12));
}

/// One decomposition + shrinkage level. `cur` is the running coarse image
/// (level 0: the padded input); `removed` accumulates detail − shrink(detail)
/// so the host can finish with out = input − removed.
kernel void denoiseAtrous(
    texture2d<float, access::read>  cur        [[texture(0)]],
    texture2d<float, access::read>  removedIn  [[texture(1)]],
    texture2d<float, access::write> coarseOut  [[texture(2)]],
    texture2d<float, access::write> removedOut [[texture(3)]],
    constant DenoiseParams& p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    // dispatchThreads grid == texture size; w/h only bound the à-trous taps.
    const uint w = cur.get_width(), h = cur.get_height();

    float4 c0 = cur.read(gid);
    // A single non-finite input texel would otherwise spread through every
    // à-trous level into a large blank block; ±inf keeps its (clamped) energy.
    if (p.first) c0.rgb = sanitize(c0.rgb);
    const float3 original = c0.rgb;

    // Hot/dead pixel suppression on the first level: an impulse reads as "an
    // edge in every direction", so the edge-stop would otherwise protect it
    // through the whole pyramid. Clamp the centre against its four direct
    // neighbours (one-sided outliers only; real detail spans ≥ 2 px). The
    // clamp delta joins `removed` so the final input − removed drops it too.
    if (p.first) {
        // Neighbours must be sanitized too: one inf tap makes `med` inf−inf =
        // NaN, and even mix(x, NaN, 0) is NaN — the seed of the bleached tiles.
        const int2 g = int2(gid);
        const float3 n0 = sanitize(cur.read(uint2(clamp(g + int2( 1, 0), int2(0), int2(w - 1, h - 1)))).rgb);
        const float3 n1 = sanitize(cur.read(uint2(clamp(g + int2(-1, 0), int2(0), int2(w - 1, h - 1)))).rgb);
        const float3 n2 = sanitize(cur.read(uint2(clamp(g + int2(0,  1), int2(0), int2(w - 1, h - 1)))).rgb);
        const float3 n3 = sanitize(cur.read(uint2(clamp(g + int2(0, -1), int2(0), int2(w - 1, h - 1)))).rgb);
        const float3 lo = min(min(n0, n1), min(n2, n3));
        const float3 hi = max(max(n0, n1), max(n2, n3));
        const float3 med = (n0 + n1 + n2 + n3) - lo - hi;   // middle-two mean × 2
        const float3 slack = 2.0 * noiseSigma(c0.rgb, p);
        const float3 impulse = step(hi + slack, c0.rgb) + step(c0.rgb, lo - slack);
        c0.rgb = mix(c0.rgb, med * 0.5, min(impulse, 1.0));
    }

    const float3 sig0 = noiseSigma(c0.rgb, p);
    const float3 invE = 1.0 / (p.edge * sig0);

    float3 sum = 0.0;
    float wsum = 0.0;
    for (int j = -2; j <= 2; j++) {
        for (int i = -2; i <= 2; i++) {
            const int2 q = clamp(int2(gid) + p.spacing * int2(i, j),
                                 int2(0), int2(w - 1, h - 1));
            float3 v = cur.read(uint2(q)).rgb;
            // Later levels read our own (already-sane) coarse output.
            if (p.first) v = sanitize(v);
            // Edge stop: joint 3-channel difference in sigma units.
            const float3 d = (v - c0.rgb) * invE;
            const float wt = b3[i + 2] * b3[j + 2] * exp(-0.5 * dot(d, d));
            sum += wt * v;
            wsum += wt;
        }
    }
    // fall back to the clamped centre
    const float3 coarse = wsum > 0.0f ? sum / wsum : c0.rgb;
    const float3 detail = c0.rgb - coarse;

    // Fisz-style stabilisation: threshold in units of the local noise sigma
    // evaluated on the (cleaner) coarse signal.
    const float3 sig = noiseSigma(coarse, p);
    const float  dm  = (detail.r + detail.g + detail.b) * (1.0 / 3.0);
    const float3 dc  = detail - dm;
    const float  sm  = length(sig) * (1.0 / 3.0);   // sigma of the channel mean

    const float3 kept = shrink1(dm, p.t_luma * sm) + shrink(dc, p.t_chroma * sig);

    const float3 prior = p.first ? (original - c0.rgb) : removedIn.read(gid).rgb;
    coarseOut.write(float4(coarse, c0.a), gid);
    removedOut.write(float4(prior + (detail - kept), 0.0), gid);
}

/// out = input − removed, dropping the symmetric ROI padding. `pad` is the
/// texel offset of the output region inside the padded input textures.
kernel void denoiseAssemble(
    texture2d<float, access::read>  original [[texture(0)]],
    texture2d<float, access::read>  removed  [[texture(1)]],
    texture2d<float, access::write> dst      [[texture(2)]],
    constant int2& pad [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    const uint2 src = gid + uint2(pad);
    const float4 c = original.read(src);
    // Sanitize the source here too: `removed` is finite by construction, but an
    // inf original texel would otherwise flow on into the finishing graph.
    dst.write(float4(sanitize(c.rgb) - removed.read(src).rgb, c.a), gid);
}
