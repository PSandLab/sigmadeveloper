// Core Image kernels for foveon pipeline

//   distortion : source = centre + (dest-centre)·(1 + k1·r² + k2·r⁴ + k3·r⁶)
//   lateral CA : red/blue compose ·ScaleFactor·(1+…) onto green (models are differential)
//    vignetting : illumination = 1 + a1·r² + a2·r⁴ + a3·r⁶ ; gain = 1/illumination

// 3 channel smaples land within 1px so per-channel sample is basiclly free

#include <CoreImage/CoreImage.h>

// 1 + c.x·r² + c.y·r⁴ + c.z·r⁶ horner
static inline float radial(float3 c, float r2) {
    return 1.0f + r2 * (c.x + r2 * (c.y + r2 * c.z));
}

extern "C" float4 lensCorrect(
    coreimage::sampler src,
    float2 center,        // optical centre (pixels, destination space)
    float rNorm2,         // r² = |dest − center|² · rNorm2   (no sqrt needed)
    float3 kG,            // green distortion (k1,k2,k3)
    float caRScale, float3 kR,   // red lateral-CA: ScaleFactor + radial params
    float caBScale, float3 kB,   // blue lateral-CA
    float3 vig,           // aperture-resolved vignette α (a1,a2,a3); zero → none
    coreimage::destination dest)
{
    float2 d = dest.coord() - center;
    float r2 = (d.x * d.x + d.y * d.y) * rNorm2;

    // green carries geometric distortion, adobe r/bg r differential 
    float sG = radial(kG, r2);
    float sR = sG * caRScale * radial(kR, r2);
    float sB = sG * caBScale * radial(kB, r2);
    float cr = src.sample(src.transform(center + d * sR)).r;
    float cg = src.sample(src.transform(center + d * sG)).g;
    float cb = src.sample(src.transform(center + d * sB)).b;

    float gain = 1.0f / coreimage::max(radial(vig, r2), 0.25f);
    return float4(float3(cr, cg, cb) * gain, 1.0f);
}

// HDR highlight extension perceptual luma
extern "C" float4 gainExtend(
    coreimage::sample_t graded,   // graded SDR look, linear [0,1]
    float stops,                  // highlight headroom in stops (log2 gain at white)
    float lo, float hi)           // perceptual-luma ramp bounds
{
    float luma = coreimage::dot(graded.rgb, float3(0.2126f, 0.7152f, 0.0722f));
    float perceptual = coreimage::sqrt(coreimage::clamp(luma, 0.0f, 1.0f));
    float gain = coreimage::exp2(stops * coreimage::smoothstep(lo, hi, perceptual));
    return float4(graded.rgb * gain, graded.a);
}
