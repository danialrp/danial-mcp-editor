EFFECT(fadeOut) {
    float p = params[0] > 0.5 ? fxEase(ctx.progress) : ctx.progress;
    return src.sample(smp, in.uv) * (1.0 - p);
}
