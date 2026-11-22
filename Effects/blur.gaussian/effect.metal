// Separable Gaussian: across, then down.
EFFECT(blurH) { return fxGaussian(src, smp, in.uv, ctx.texel, float2(1, 0), params[0] * ctx.scale); }
EFFECT(blurV) { return fxGaussian(src, smp, in.uv, ctx.texel, float2(0, 1), params[0] * ctx.scale); }
