/// Metal source for the render graph, compiled at run time (no Xcode needed).
///
/// Each layer is a textured quad. The fragment shader turns the decoded
/// picture into RGB, converts it to the project's colour space when the two
/// differ, applies opacity and returns premultiplied alpha, so layers stack
/// with plain "over" blending.
let renderShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VertexIn { float2 position; float2 uv; };
struct VertexOut { float4 position [[position]]; float2 uv; };

struct LayerParams {
    float3x3 yuvToRGB;   // columns: Y, Cb, Cr contributions
    float4 range;        // yOffset, yScale, cOffset, cScale
    float opacity;
    int mode;            // 0 same space, 1 SDR to HLG, 2 HLG to SDR
    int alpha;           // 1 when the source carries alpha
    int pad;
};

vertex VertexOut layerVertex(uint vid [[vertex_id]], constant VertexIn *v [[buffer(0)]]) {
    VertexOut o;
    o.position = float4(v[vid].position, 0.0, 1.0);
    o.uv = v[vid].uv;
    return o;
}

// HLG (ITU-R BT.2100)
constant float hlgA = 0.17883277, hlgB = 0.28466892, hlgC = 0.55991073;
float hlgOETF(float e) { return e <= 1.0/12.0 ? sqrt(3.0 * e) : hlgA * log(12.0 * e - hlgB) + hlgC; }
float hlgInverse(float s) { return s <= 0.5 ? s * s / 3.0 : (exp((s - hlgC) / hlgA) + hlgB) / 12.0; }

// SDR and HLG meet as BT.2408 says: SDR diffuse white is 203 cd/m² on the
// 1000 cd/m² reference display (0.203), and the HLG system gamma (1.2 there)
// is undone on the way in and applied on the way out, on luminance only, so
// a picture shown on an HLG display looks as it did in SDR: same brightness,
// contrast and colour, not darker and harsher.
constant float sdrWhite = 0.203;
constant float hlgGamma = 1.2;
constant float3 lum2020 = float3(0.2627, 0.6780, 0.0593);

constant float3x3 rec709To2020 = float3x3(float3(0.6274, 0.0691, 0.0164),
                                          float3(0.3293, 0.9195, 0.0880),
                                          float3(0.0433, 0.0114, 0.8956));
constant float3x3 rec2020To709 = float3x3(float3(1.6605, -0.1246, -0.0182),
                                          float3(-0.5876, 1.1329, -0.1006),
                                          float3(-0.0728, -0.0083, 1.1187));

float3 convertSpace(float3 rgb, int mode) {
    if (mode == 1) {
        float3 d = rec709To2020 * pow(max(rgb, 0.0), 2.4) * sdrWhite;   // BT.1886 display light
        float yd = max(dot(d, lum2020), 1e-6);
        float3 e = max(d * pow(yd, 1.0 / hlgGamma - 1.0), 0.0);       // inverse OOTF: scene light
        return float3(hlgOETF(e.r), hlgOETF(e.g), hlgOETF(e.b));
    }
    if (mode == 2) {
        float3 e = float3(hlgInverse(rgb.r), hlgInverse(rgb.g), hlgInverse(rgb.b));
        float ys = max(dot(e, lum2020), 1e-6);
        float3 lin = e * pow(ys, hlgGamma - 1.0) / sdrWhite;           // OOTF: display light
        lin = max(rec2020To709 * lin, 0.0);
        // Soft shoulder above 80% so highlights roll off instead of clipping.
        float3 over = max(lin - 0.8, 0.0);
        lin = min(lin, 0.8) + over / (1.0 + over * 5.0);
        return pow(min(lin, 1.0), 1.0 / 2.4);
    }
    return rgb;
}

// An HLG picture as an HLG display shows it, in SDR, for preview on displays
// without HDR. A frame holding HLG material rolls its highlights off as in an
// SDR project; one of only SDR material stops at white, so it looks as stored.
// The exact inverse of rec709To2020: at four digits a pure primary comes back
// with the other channels several levels up.
constant float3x3 rec709From2020 = float3x3(float3(1.6605112, -0.1245614, -0.0181677),
                                            float3(-0.5877106, 1.1329605, -0.1005606),
                                            float3(-0.0728006, -0.0083991, 1.1187283));

float3 sdrView(float3 rgb, bool rollOff) {
    if (rollOff) return convertSpace(rgb, 2);
    float3 e = float3(hlgInverse(rgb.r), hlgInverse(rgb.g), hlgInverse(rgb.b));
    float3 lin = rec709From2020 * (e * pow(max(dot(e, lum2020), 1e-6), hlgGamma - 1.0) / sdrWhite);
    return pow(saturate(lin), 1.0 / 2.4);
}

// MARK: colour look (Adjust, White Balance, HSL, Style)

struct LookParams {
    float4 a0;        // exposure, brightness, contrast, saturation (each -1..1)
    float4 a1;        // highlights, shadows, whites, blacks
    float4 a2;        // vibrance, clarity, temperature, tint
    float4 s0;        // sharpen, noise reduction, fade, vignette (each 0..1)
    float4 s1;        // grain, enabled, frame seed, unused
    float4 texel;     // one source pixel in texture units (x, y), clarity radius in pixels (z)
    float4 bands[8];  // hue, saturation, luminance per HSL band (-1..1)
    float4 pick[4];   // picked colour: hue 0..1, saturation, value, reach (0..1 of the hue circle)
    float4 pickAdj[4];// hue, saturation, luminance (-1..1), active
};

constant float bandHue[8] = {0.0, 30.0/360.0, 60.0/360.0, 120.0/360.0, 180.0/360.0, 240.0/360.0, 270.0/360.0, 300.0/360.0};

float lum(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

float3 rgb2hsv(float3 c) {
    float4 K = float4(0.0, -1.0/3.0, 2.0/3.0, -1.0);
    float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
    float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y);
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + 1e-6)), d / (q.x + 1e-6), q.x);
}

float3 hsv2rgb(float3 c) {
    float3 p = abs(fract(c.xxx + float3(1.0, 2.0/3.0, 1.0/3.0)) * 6.0 - 3.0);
    return c.z * mix(float3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);
}

float hueDist(float a, float b) { float d = abs(a - b); return min(d, 1.0 - d); }

/// Weight of band `i` at hue `h`: 1 at its centre, falling linearly to 0 at
/// the centres of the bands on either side, so the weights of all bands add
/// up to 1 and a band's own colour is touched by that band alone.
float bandWeight(float h, int i) {
    float c = bandHue[i];
    float d = fract(h - c + 0.5) - 0.5;                       // signed offset, -0.5..0.5
    float span = d >= 0.0 ? fract(bandHue[(i + 1) % 8] - c + 1.0) : fract(c - bandHue[(i + 7) % 8] + 1.0);
    return max(0.0, 1.0 - abs(d) / span);
}

float hash(float2 p) { return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453); }

float max3(float3 c) { return max(c.r, max(c.g, c.b)); }

/// Gives a colour the luma `y2` (it has `y`), keeping its hue and how
/// colourful it is: the channels are scaled together. Next to black, where
/// scaling would only multiply noise, the change is added as grey instead.
/// A colour pushed past white moves toward grey of the same luma until it
/// fits, so no channel clips on its own and the hue never turns.
float3 withLuma(float3 rgb, float y, float y2) {
    float3 scaled = rgb * (y2 / max(y, 1e-4));
    float3 o = max(mix(rgb + (y2 - y), scaled, smoothstep(0.0, 0.04, y)), 0.0);
    float m = max3(o);
    if (m > 1.0) o = y2 >= 1.0 ? float3(1.0) : mix(o, float3(y2), (m - 1.0) / (m - y2));
    return o;
}

/// The tone controls as one curve on luma, each a monotone step on a range
/// of its own, applied one after another: tones never swap places, however
/// the sliders are combined.
float toneCurve(float y, constant LookParams &k) {
    float hi = k.a1.x, sh = k.a1.y, wh = k.a1.z, bl = k.a1.w;
    float t = (y - 0.4) / 0.6;                                     // highlights: 40 % to white, white stays
    if (t > 0.0 && t < 1.0) y += hi * 0.5 * t * t * (1.0 - t);
    t = y / 0.5;                                                   // shadows: black to 50 %, black stays
    if (t > 0.0 && t < 1.0) y += sh * 0.45 * t * (1.0 - t) * (1.0 - t);
    t = clamp((y - 0.55) / 0.45, 0.0, 1.0);                        // whites: moves the white point
    y += wh * 0.1 * t * t;
    t = clamp(y / 0.3, 0.0, 1.0);                                  // blacks: moves the black point
    y = max(0.0, y + bl * 0.14 * (1.0 - t) * (1.0 - t));
    if (k.a0.y != 0.0) {                                           // brightness: mid tones, ends stay
        float c = clamp(y, 0.0, 1.0);
        y += pow(c, exp2(-k.a0.y * 0.5)) - c;
    }
    if (k.a0.z != 0.0) {                                           // contrast: an S-curve about 50 %
        float c = clamp(y, 0.0, 1.0), p = exp2(k.a0.z * 0.6);
        float s = c < 0.5 ? 0.5 * pow(2.0 * c, p) : 1.0 - 0.5 * pow(2.0 - 2.0 * c, p);
        y += s - c;
    }
    return y;
}

/// `l0`, `blurSmall` and `blurBig` are the source luma at the pixel and
/// averaged around it, for sharpen, noise reduction and clarity.
float3 applyLook(float3 rgb, float2 uv, float l0, float blurSmall, float blurBig, constant LookParams &k) {
    float fineDetail = l0 - blurSmall, broadDetail = l0 - blurBig;
    rgb -= k.s0.y * 0.9 * fineDetail;                       // noise reduction
    rgb += k.s0.x * 1.3 * fineDetail;                       // sharpen
    if (k.a2.y != 0.0) {                                    // clarity: broad local contrast, mostly mid tones
        rgb = max(rgb, 0.0);
        float y = lum(rgb);
        float w = 1.0 - smoothstep(0.25, 0.5, abs(y - 0.5));
        rgb = withLuma(rgb, y, max(0.0, y + k.a2.y * 0.9 * broadDetail * w));
    }

    if (k.a0.x != 0.0) {                                    // exposure: a gain in light, ±1.5 stops
        float g = exp2(k.a0.x * 1.5);
        float3 lin = pow(max(rgb, 0.0), 2.2) * g;
        float m = max3(lin);
        if (g > 1.0) {
            // A shoulder instead of a hard clip, the same for all three
            // channels, so bright colours roll toward white with their hue.
            float knee = 1.0 - 0.25 * saturate(g - 1.0);
            if (m > knee) {
                float m2 = knee + (1.0 - knee) * (1.0 - exp(-(m - knee) / max(1.0 - knee, 1e-3)));
                // Toward white in the picture's own encoding, so the hue holds.
                rgb = mix(pow(lin * (m2 / m), 1.0 / 2.2), float3(pow(m2, 1.0 / 2.2)), 0.5 * saturate((m - knee) / 2.0));
            } else {
                rgb = pow(lin, 1.0 / 2.2);
            }
        } else {
            rgb = pow(lin, 1.0 / 2.2);
        }
    }
    // White balance: warmer is more red and less blue, tint trades green for magenta.
    rgb *= float3(1.0 + 0.16 * k.a2.z, 1.0, 1.0 - 0.16 * k.a2.z);
    rgb *= float3(1.0 + 0.06 * k.a2.w, 1.0 - 0.12 * k.a2.w, 1.0 + 0.06 * k.a2.w);

    // Each stage runs only when its sliders are set, so a look at 0 gives
    // back the source exactly, even values a little outside 0-1 from video.
    if (any(k.a1 != 0.0) || k.a0.y != 0.0 || k.a0.z != 0.0) {
        rgb = max(rgb, 0.0);
        float y0 = lum(rgb);
        rgb = withLuma(rgb, y0, toneCurve(y0, k));
    }

    if (k.a0.w != 0.0 || k.a2.x != 0.0) {
        float L = lum(rgb);
        float3 hsv0 = rgb2hsv(max(rgb, 0.0));
        // Saturation and vibrance scale colour away from grey. Vibrance works
        // mostly on weak colours. A boost stops at the edge of the colour range,
        // so no channel clips and brightness stays.
        float s0 = clamp(hsv0.y, 0.0, 1.0);
        float vib = k.a2.x > 0.0 ? 1.0 + 1.2 * k.a2.x * (1.0 - s0) : 1.0 + k.a2.x * (1.0 - 0.5 * s0);
        float f = (1.0 + k.a0.w) * vib;
        float3 chroma = rgb - L;
        if (f > 1.0) {
            float room = 1e6;
            for (int c = 0; c < 3; c++) {
                if (chroma[c] < -1e-5) room = min(room, max(L, 0.0) / -chroma[c]);
                if (chroma[c] > 1e-5) room = min(room, max(1.0 - L, 0.0) / chroma[c]);
            }
            f = min(f, max(room, 1.0));
        }
        rgb = L + chroma * f;
    }

    // HSL: each band and each picked colour shifts hue, scales saturation and value.
    float3 hsv = rgb2hsv(max(rgb, 0.0));
    float colourful = smoothstep(0.04, 0.2, hsv.y);
    float dh = 0.0, ds = 0.0, dv = 0.0;
    for (int i = 0; i < 8; i++) {
        float w = bandWeight(hsv.x, i) * colourful;
        dh += w * k.bands[i].x; ds += w * k.bands[i].y; dv += w * k.bands[i].z;
    }
    for (int i = 0; i < 4; i++) {
        if (k.pickAdj[i].w < 0.5) continue;
        float w = max(0.0, 1.0 - hueDist(hsv.x, k.pick[i].x) / max(k.pick[i].w, 0.01));
        w *= max(0.0, 1.0 - abs(hsv.y - k.pick[i].y) / 0.6) * colourful;
        dh += w * k.pickAdj[i].x; ds += w * k.pickAdj[i].y; dv += w * k.pickAdj[i].z;
    }
    if (dh != 0.0 || ds != 0.0 || dv != 0.0) {
        hsv.x = fract(hsv.x + dh * (30.0 / 360.0) + 1.0);
        hsv.y = clamp(hsv.y * (1.0 + ds), 0.0, 1.0);
        hsv.z = max(0.0, hsv.z * (1.0 + dv * 0.5));
        rgb = hsv2rgb(hsv);
    }

    rgb = rgb * (1.0 - 0.2 * k.s0.z) + 0.1 * k.s0.z;        // fade
    float d = distance(uv, float2(0.5)) * 1.41421;
    rgb *= 1.0 - k.s0.w * 0.8 * smoothstep(0.35, 1.0, d);   // vignette
    if (k.s1.x != 0.0) rgb += k.s1.x * 0.08 * (hash(uv / k.texel.xy + k.s1.z) - 0.5);   // grain
    return rgb;
}

float4 finish(float3 rgbIn, float a, constant LayerParams &p) {
    float3 rgb = convertSpace(rgbIn, p.mode);
    float alpha = (p.alpha == 1 ? a : 1.0) * p.opacity;
    return float4(rgb * alpha, alpha);
}

float3 yuv(float3 ycc, constant LayerParams &p) {
    float y = (ycc.x - p.range.x) * p.range.y;
    float2 c = (ycc.yz - p.range.z) * p.range.w;
    return p.yuvToRGB * float3(y, c.x, c.y);
}

// Neighbourhood luma: 4 neighbours one pixel away; for clarity two rings of
// 8 samples, at the clarity radius (texel.z, in pixels) and half of it,
// turned against each other, only when clarity is set.
#define NEIGHBOURS(LUMA) \
    float2 t = look.texel.xy; \
    float small = 0.25 * (LUMA(in.uv + float2(t.x, 0)) + LUMA(in.uv - float2(t.x, 0)) + LUMA(in.uv + float2(0, t.y)) + LUMA(in.uv - float2(0, t.y))); \
    float big = 0.0; \
    if (look.a2.y != 0.0) { \
        for (int i = 0; i < 8; i++) { \
            float a1 = float(i) * 0.785398, a2 = a1 + 0.392699; \
            big += 0.6 * LUMA(in.uv + float2(cos(a1), sin(a1)) * t * look.texel.z); \
            big += 0.4 * LUMA(in.uv + float2(cos(a2), sin(a2)) * t * look.texel.z * 0.5); \
        } \
        big *= 0.125; \
    }

// 4:2:0 two-plane, 8 or 10 bit (420v, 420f, x420, xf20)
fragment float4 biplanarFragment(VertexOut in [[stage_in]],
                                 texture2d<float> lumaTex [[texture(0)]],
                                 texture2d<float> chromaTex [[texture(1)]],
                                 sampler s [[sampler(0)]],
                                 constant LayerParams &p [[buffer(0)]],
                                 constant LookParams &look [[buffer(1)]]) {
    float3 rgb = yuv(float3(lumaTex.sample(s, in.uv).r, chromaTex.sample(s, in.uv).rg), p);
    if (look.s1.y > 0.5) {
        #define BLUMA(uv) ((lumaTex.sample(s, uv).r - p.range.x) * p.range.y)
        NEIGHBOURS(BLUMA)
        rgb = applyLook(rgb, in.uv, BLUMA(in.uv), small, big, look);
    }
    return finish(rgb, 1.0, p);
}

// 4:4:4:4 16-bit, ordered A Y Cb Cr (y416): ProRes 4444 and HEVC with alpha
fragment float4 ayuvFragment(VertexOut in [[stage_in]],
                             texture2d<float> tex [[texture(0)]],
                             sampler s [[sampler(0)]],
                             constant LayerParams &p [[buffer(0)]],
                             constant LookParams &look [[buffer(1)]]) {
    float4 v = tex.sample(s, in.uv);
    float3 rgb = yuv(v.gba, p);
    if (look.s1.y > 0.5) {
        #define ALUMA(uv) ((tex.sample(s, uv).g - p.range.x) * p.range.y)
        NEIGHBOURS(ALUMA)
        rgb = applyLook(rgb, in.uv, ALUMA(in.uv), small, big, look);
    }
    return finish(rgb, v.r, p);
}

// A layer that already went through its effects: premultiplied RGBA in the
// output space, placed with the layer's quad.
fragment float4 compositeFragment(VertexOut in [[stage_in]],
                                  texture2d<float> tex [[texture(0)]],
                                  sampler s [[sampler(0)]],
                                  constant float &opacity [[buffer(0)]]) {
    return tex.sample(s, in.uv) * opacity;
}

// The whole HLG frame, finished, turned into its SDR preview.
fragment float4 sdrViewFragment(VertexOut in [[stage_in]],
                                texture2d<float> tex [[texture(0)]],
                                sampler s [[sampler(0)]],
                                constant float &rollOff [[buffer(0)]]) {
    return float4(sdrView(tex.sample(s, in.uv).rgb, rollOff > 0.5), 1.0);
}

// Already RGB (BGRA 8-bit)
fragment float4 rgbFragment(VertexOut in [[stage_in]],
                            texture2d<float> tex [[texture(0)]],
                            sampler s [[sampler(0)]],
                            constant LayerParams &p [[buffer(0)]],
                            constant LookParams &look [[buffer(1)]]) {
    float4 v = tex.sample(s, in.uv);
    float3 rgb = v.rgb;
    if (look.s1.y > 0.5) {
        #define RLUMA(uv) lum(tex.sample(s, uv).rgb)
        NEIGHBOURS(RLUMA)
        rgb = applyLook(rgb, in.uv, RLUMA(in.uv), small, big, look);
    }
    return finish(rgb, v.a, p);
}

// MARK: person matte and depth layers (phase 8)

// Normal cumulative distribution: a step edge blurred by a Gaussian of
// sigma 1 is phi(distance), so cutting and softening need no filtering.
float phi(float x) { x = clamp(x, -6.0, 6.0); return 0.5 * (1.0 + tanh(0.7978845608 * (x + 0.044715 * x * x * x))); }

struct MatteParams {
    float4 range;    // yOffset, yScale (from the stored codes to 0..1), output pixels per matte pixel, unused
};

// A stored matte (tight on top, wide below, distance codes) placed like its
// clip, as distances in output pixels: r tight, g wide.
fragment float4 matteFragment(VertexOut in [[stage_in]],
                              texture2d<float> luma [[texture(0)]],
                              sampler s [[sampler(0)]],
                              constant MatteParams &m [[buffer(0)]]) {
    float halfRow = 0.5 / float(luma.get_height());
    float2 top = float2(in.uv.x, clamp(in.uv.y * 0.5, 0.0, 0.5 - halfRow));
    float2 bottom = float2(in.uv.x, clamp(0.5 + in.uv.y * 0.5, 0.5 + halfRow, 1.0));
    float t = (luma.sample(s, top).r - m.range.x) * m.range.y * 255.0;
    float w = (luma.sample(s, bottom).r - m.range.x) * m.range.y * 255.0;
    return float4((t - 128.0) * 0.25 * m.range.z, (w - 128.0) * 0.25 * m.range.z, 0.0, 1.0);
}

struct DepthParams {
    float4 edge;     // edge colour (SDR RGB), strength 0..1
    float4 a;        // edge radius (output px), softness, cut inset, cut softness
    float4 b;        // profile full to, profile zero at (fractions of the height), output width, height
    float4 c;        // output is HLG (1), cut by the wide matte (1) or the tight one (0), opacity, unused
    float4 shadow;   // shadow colour (SDR RGB), opacity (0 off)
    float4 shadowAt; // shadow offset in layer texture units (x, y)
};

// A depth composition from its two passes, each already drawn alone and
// through the clip's effects (premultiplied, output space): the shadow the
// elements cast on the wall and the back pass, both cut by the person's
// tight matte; the lit outline in the band between the tight matte and the
// grown wide one; then the front pass.
fragment float4 depthFragment(VertexOut in [[stage_in]],
                              texture2d<float> back [[texture(0)]],
                              texture2d<float> matte [[texture(1)]],
                              texture2d<float> front [[texture(2)]],
                              texture2d<float> shadow [[texture(3)]],
                              sampler s [[sampler(0)]],
                              constant DepthParams &d [[buffer(1)]]) {
    int mode = d.c.x > 0.5 ? 1 : 0;
    float4 pb = back.sample(s, in.uv);
    float4 pf = front.sample(s, in.uv);
    float2 st = in.position.xy / d.b.zw;
    float2 m = matte.sample(s, st).rg;
    float cut = phi(((d.c.y > 0.5 ? m.y : m.x) - d.a.z) / max(d.a.w, 0.001));
    float3 C = float3(0.0);
    float A = 0.0;
    if (d.shadow.w > 0.0) {
        float2 su = in.uv - d.shadowAt.xy;
        float sa = (su.x < 0.0 || su.y < 0.0 || su.x > 1.0 || su.y > 1.0) ? 0.0 : shadow.sample(s, su).r;
        A = sa * d.shadow.w * (1.0 - cut);
        C = convertSpace(d.shadow.rgb, mode) * A;
    }
    float ab = pb.a * (1.0 - cut);
    C = pb.rgb * (1.0 - cut) + C * (1.0 - ab);
    A = ab + A * (1.0 - ab);
    if (d.edge.w > 0.0) {
        float prof = st.y < d.b.x ? 1.0 : max(0.0, (d.b.y - st.y) / max(d.b.y - d.b.x, 0.001));
        float soft = max(d.a.y, 0.001);
        float e = phi((m.y + d.a.x) / soft) * (1.0 - phi(m.x / soft)) * prof * d.edge.w;
        C = convertSpace(d.edge.rgb, mode) * e + C * (1.0 - e);
        A = e + A * (1.0 - e);
    }
    C = pf.rgb + C * (1.0 - pf.a);
    A = pf.a + A * (1.0 - pf.a);
    return float4(C, A) * d.c.z;
}

// The alpha of the passes that cast a shadow, at a quarter of the size:
// p = use back, use front, one layer texel (x, y). Four bilinear samples
// average the 4x4 layer pixels under each texel.
fragment float4 shadowAlphaFragment(VertexOut in [[stage_in]],
                                    texture2d<float> back [[texture(0)]],
                                    texture2d<float> front [[texture(1)]],
                                    sampler s [[sampler(0)]],
                                    constant float4 &p [[buffer(0)]]) {
    float ab = 0.0, af = 0.0;
    for (int k = 0; k < 4; k++) {
        float2 o = float2(k % 2 == 0 ? -1.0 : 1.0, k < 2 ? -1.0 : 1.0) * p.zw;
        ab += back.sample(s, in.uv + o).a;
        af += front.sample(s, in.uv + o).a;
    }
    float a = 1.0 - (1.0 - 0.25 * ab * p.x) * (1.0 - 0.25 * af * p.y);
    return float4(a);
}

// One direction of a Gaussian blur: p = step (x, y in texture units), sigma in texels.
fragment float4 shadowBlurFragment(VertexOut in [[stage_in]],
                                   texture2d<float> tex [[texture(0)]],
                                   sampler s [[sampler(0)]],
                                   constant float4 &p [[buffer(0)]]) {
    float sigma = max(p.z, 0.3);
    float stride = max(1.0, sigma / 3.0);
    float sum = 0.0, total = 0.0;
    for (int k = -9; k <= 9; k++) {
        float x = float(k) * stride;
        float w = exp(-0.5 * x * x / (sigma * sigma));
        sum += tex.sample(s, in.uv + p.xy * x).r * w;
        total += w;
    }
    return float4(sum / total);
}
"""
