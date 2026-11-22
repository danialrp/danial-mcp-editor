float blurInProgress(constant FXContext &ctx, constant float *params) {
    return params[2] > 0.5 ? fxEase(ctx.progress) : ctx.progress;
}

EFFECT(blurInH) {
    float r = params[0] * ctx.scale * (1.0 - blurInProgress(ctx, params));
    return fxGaussian(src, smp, in.uv, ctx.texel, float2(1, 0), r);
}

EFFECT(blurInV) {
    float p = blurInProgress(ctx, params);
    float4 c = fxGaussian(src, smp, in.uv, ctx.texel, float2(0, 1), params[0] * ctx.scale * (1.0 - p));
    return params[1] > 0.5 ? c * p : c;
}
