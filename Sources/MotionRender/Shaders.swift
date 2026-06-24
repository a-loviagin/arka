#if os(macOS)
import Foundation

/// Metal shader source, compiled at runtime via `device.makeLibrary(source:)`. Kept as a Swift
/// string (rather than a `.metal` resource) so it works regardless of SwiftPM metallib packaging.
///
/// Two pipelines share an ordered draw walk so z-order is always respected:
///  - shape_*  : analytic SDF rect/rounded-rect/ellipse, scale-aware AA via `fwidth` (no MSAA).
///  - glyph_*  : textured quads sampling an R8 coverage atlas (glyphs now, images next), tinted.
///
/// `base` lets one big instance buffer back many contiguous draws (instance_id is 0-based per draw).
/// The Swift `InstanceUniform` / `GlyphInstance` layouts must match these structs exactly.
enum ShaderSource {
    static let metal = """
    #include <metal_stdlib>
    using namespace metal;

    // Render targets are sRGB-format, so the GPU sRGB-encodes on store and decodes on sample —
    // i.e. all blending/blur/compositing happens in LINEAR space (render-engine.md §4). Colors enter
    // the shaders sRGB-encoded (ColorValue is stored sRGB), so linearize them before output; texture
    // samples are already linear (sRGB textures auto-decode). Alpha is linear in both spaces.
    static inline float3 srgbToLinear(float3 c) {
        return select(c / 12.92, pow((c + 0.055) / 1.055, 3.0), c > 0.04045);
    }

    // Gradient fill (Tier 2): endpoints in layer-local points; linear projects along the axis,
    // radial uses distance / radius. Sampled from a baked sRGB LUT. `hasGradient` gates it so flat
    // draws never sample (a dummy 1×1 LUT is still bound to satisfy the binding).
    struct GradientParams { float2 start; float2 end; uint kind; uint hasGradient; };
    static inline float gradientT(float2 local, constant GradientParams &g) {
        float2 d = g.end - g.start;
        if (g.kind == 1u) { return clamp(length(local - g.start) / max(length(d), 1e-4), 0.0, 1.0); }
        return clamp(dot(local - g.start, d) / max(dot(d, d), 1e-4), 0.0, 1.0);
    }

    // ---- SDF shapes -------------------------------------------------------------------------
    struct InstanceUniform {
        float3x3 clipFromLocal;
        float4 fill;
        float4 stroke;
        float2 size;
        float cornerRadius;
        float strokeWidth;
        uint kind;        // 0 = rect/rounded-rect, 1 = ellipse
        float opacity;
    };

    struct ShapeOut {
        float4 position [[position]];
        float2 local;
        uint instance;
    };

    vertex ShapeOut shape_vertex(uint vid [[vertex_id]],
                                 uint iid [[instance_id]],
                                 constant InstanceUniform *instances [[buffer(0)]],
                                 constant uint &base [[buffer(1)]]) {
        uint idx = iid + base;
        constant InstanceUniform &inst = instances[idx];
        float pad = inst.strokeWidth + 2.0;
        float2 corners[4] = {
            float2(-pad, -pad),
            float2(inst.size.x + pad, -pad),
            float2(-pad, inst.size.y + pad),
            float2(inst.size.x + pad, inst.size.y + pad)
        };
        float2 local = corners[vid];
        float3 clip = inst.clipFromLocal * float3(local, 1.0);
        ShapeOut out;
        out.position = float4(clip.xy, 0.0, 1.0);
        out.local = local;
        out.instance = idx;
        return out;
    }

    static inline float sdRoundBox(float2 p, float2 b, float r) {
        float2 q = abs(p) - b + r;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }
    static inline float sdEllipse(float2 p, float2 ab) {
        float2 n = p / max(ab, float2(1e-3));
        float k = length(n);
        return (k - 1.0) * min(ab.x, ab.y);
    }

    fragment float4 shape_fragment(ShapeOut in [[stage_in]],
                                   constant InstanceUniform *instances [[buffer(0)]],
                                   constant GradientParams &grad [[buffer(1)]],
                                   texture2d<float> lut [[texture(0)]],
                                   sampler samp [[sampler(0)]]) {
        constant InstanceUniform &inst = instances[in.instance];
        float2 halfSize = inst.size * 0.5;
        float2 p = in.local - halfSize;
        float d;
        if (inst.kind == 1u) {
            d = sdEllipse(p, halfSize);
        } else {
            float r = clamp(inst.cornerRadius, 0.0, min(halfSize.x, halfSize.y));
            d = sdRoundBox(p, halfSize, r);
        }
        float aa = max(fwidth(d), 1e-5);
        float fillCov = 1.0 - smoothstep(-aa, aa, d);
        float strokeCov = 0.0;
        if (inst.strokeWidth > 0.0) {
            float hw = inst.strokeWidth * 0.5;
            strokeCov = 1.0 - smoothstep(hw - aa, hw + aa, abs(d));
        }
        float4 fill = inst.fill;
        if (grad.hasGradient == 1u) { fill = lut.sample(samp, float2(gradientT(in.local, grad), 0.5)); }
        float4 stroke = inst.stroke;
        float3 rgb = srgbToLinear(fill.rgb);
        float a = fill.a * fillCov;
        float sa = stroke.a * strokeCov;
        rgb = mix(rgb, srgbToLinear(stroke.rgb), sa);
        a = max(a, sa);
        a *= inst.opacity;
        return float4(rgb * a, a); // linear, pre-multiplied (sRGB-encoded on store)
    }

    // ---- Vector paths (tessellated fill) ---------------------------------------------------
    // A flat triangle list in layer-local space, one uniform per path (transform + fill + opacity).
    struct PathUniform {
        float3x3 clipFromLocal;
        float4 fill;       // straight rgba
        float opacity;
    };

    struct PathOut { float4 position [[position]]; float2 local; };

    vertex PathOut path_vertex(uint vid [[vertex_id]],
                               constant float2 *verts [[buffer(0)]],
                               constant PathUniform &u [[buffer(1)]]) {
        float3 clip = u.clipFromLocal * float3(verts[vid], 1.0);
        PathOut o;
        o.position = float4(clip.xy, 0.0, 1.0);
        o.local = verts[vid];
        return o;
    }

    fragment float4 path_fragment(PathOut in [[stage_in]],
                                  constant PathUniform &u [[buffer(0)]],
                                  constant GradientParams &grad [[buffer(1)]],
                                  texture2d<float> lut [[texture(0)]],
                                  sampler samp [[sampler(0)]]) {
        float4 fill = u.fill;
        if (grad.hasGradient == 1u) { fill = lut.sample(samp, float2(gradientT(in.local, grad), 0.5)); }
        float a = fill.a * u.opacity;
        return float4(srgbToLinear(fill.rgb) * a, a); // linear, pre-multiplied
    }

    // ---- Textured quads (glyphs / images) --------------------------------------------------
    struct GlyphInstance {
        float3x3 clipFromLocal;
        float2 localOrigin;
        float2 localSize;
        float2 uvOrigin;
        float2 uvSize;
        float4 tint;
        float opacity;
    };

    struct GlyphOut {
        float4 position [[position]];
        float2 uv;
        uint instance;
    };

    vertex GlyphOut glyph_vertex(uint vid [[vertex_id]],
                                 uint iid [[instance_id]],
                                 constant GlyphInstance *instances [[buffer(0)]],
                                 constant uint &base [[buffer(1)]]) {
        uint idx = iid + base;
        constant GlyphInstance &inst = instances[idx];
        float2 corner = float2(float(vid & 1u), float((vid >> 1) & 1u));
        float2 local = inst.localOrigin + inst.localSize * corner;
        float2 uv = inst.uvOrigin + inst.uvSize * corner;
        float3 clip = inst.clipFromLocal * float3(local, 1.0);
        GlyphOut out;
        out.position = float4(clip.xy, 0.0, 1.0);
        out.uv = uv;
        out.instance = idx;
        return out;
    }

    fragment float4 glyph_fragment(GlyphOut in [[stage_in]],
                                   constant GlyphInstance *instances [[buffer(0)]],
                                   texture2d<float> atlas [[texture(0)]],
                                   sampler samp [[sampler(0)]]) {
        constant GlyphInstance &inst = instances[in.instance];
        float coverage = atlas.sample(samp, in.uv).r;
        float a = coverage * inst.tint.a * inst.opacity;
        return float4(srgbToLinear(inst.tint.rgb) * a, a); // linear, pre-multiplied
    }

    // Image quads: sample a pre-multiplied RGBA texture, scale by chain opacity. Shares the
    // textured-quad vertex (glyph_vertex); uv spans the full image.
    fragment float4 image_fragment(GlyphOut in [[stage_in]],
                                   constant GlyphInstance *instances [[buffer(0)]],
                                   texture2d<float> tex [[texture(0)]],
                                   sampler samp [[sampler(0)]]) {
        constant GlyphInstance &inst = instances[in.instance];
        float4 t = tex.sample(samp, in.uv);
        return t * inst.opacity; // texture is pre-multiplied; scaling preserves that
    }

    // ---- Effects (intermediate passes) -----------------------------------------------------
    struct FSOut { float4 position [[position]]; float2 uv; };

    struct BlurParams { float2 texelStep; float sigma; int taps; };
    struct CompositeParams { float2 offsetNDC; float4 tint; float opacity; uint mode; };

    // Fullscreen triangle-strip quad. uv flips y so texel (0,0) = top-left (matches how content is
    // rendered into the intermediate).
    vertex FSOut fullscreen_vertex(uint vid [[vertex_id]]) {
        float2 c = float2(float(vid & 1u), float((vid >> 1) & 1u));
        FSOut o;
        o.position = float4(c * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(c.x, 1.0 - c.y);
        return o;
    }

    // Separable Gaussian (blur in pre-multiplied space → no dark halos). Run once per axis.
    fragment float4 blur_fragment(FSOut in [[stage_in]],
                                  texture2d<float> tex [[texture(0)]],
                                  sampler samp [[sampler(0)]],
                                  constant BlurParams &p [[buffer(0)]]) {
        float4 sum = float4(0.0);
        float wsum = 0.0;
        for (int i = -p.taps; i <= p.taps; i++) {
            float w = exp(-float(i * i) / (2.0 * p.sigma * p.sigma));
            sum += tex.sample(samp, in.uv + float(i) * p.texelStep) * w;
            wsum += w;
        }
        return sum / max(wsum, 1e-5);
    }

    // Composite an intermediate into the target. mode 0 = normal (image over), mode 1 = shadow
    // (recolor by the source alpha with the shadow tint). Offset is applied in NDC.
    vertex FSOut composite_vertex(uint vid [[vertex_id]],
                                  constant CompositeParams &p [[buffer(0)]]) {
        float2 c = float2(float(vid & 1u), float((vid >> 1) & 1u));
        FSOut o;
        o.position = float4(c * 2.0 - 1.0 + p.offsetNDC, 0.0, 1.0);
        o.uv = float2(c.x, 1.0 - c.y);
        return o;
    }

    fragment float4 composite_fragment(FSOut in [[stage_in]],
                                       texture2d<float> tex [[texture(0)]],
                                       sampler samp [[sampler(0)]],
                                       constant CompositeParams &p [[buffer(0)]]) {
        float4 c = tex.sample(samp, in.uv); // linear, pre-multiplied (sRGB texture auto-decodes)
        if (p.mode == 1u) {
            float a = c.a * p.opacity;
            return float4(srgbToLinear(p.tint.rgb) * a, a); // shadow tint, linearized
        }
        return c * p.opacity;
    }

    // Color adjustment (Tier 3): operate on the layer's premultiplied-linear result. Unpremultiply,
    // apply brightness/contrast/saturation/hue, re-premultiply. SVG-style hue-rotation matrix.
    struct ColorAdjustParams { float brightness; float contrast; float saturation; float hue; };

    static inline float3 hueRotate(float3 c, float deg) {
        float a = deg * 3.14159265 / 180.0;
        float C = cos(a), S = sin(a);
        float3 r0 = float3(0.213, 0.715, 0.072) + C * float3(0.787, -0.715, -0.072) + S * float3(-0.213, -0.715, 0.928);
        float3 r1 = float3(0.213, 0.715, 0.072) + C * float3(-0.213, 0.285, -0.072) + S * float3(0.143, 0.140, -0.283);
        float3 r2 = float3(0.213, 0.715, 0.072) + C * float3(-0.213, -0.715, 0.928) + S * float3(-0.787, 0.715, 0.072);
        return float3(dot(c, r0), dot(c, r1), dot(c, r2));
    }

    fragment float4 coloradjust_fragment(FSOut in [[stage_in]],
                                         texture2d<float> tex [[texture(0)]],
                                         sampler samp [[sampler(0)]],
                                         constant ColorAdjustParams &p [[buffer(0)]]) {
        float4 c = tex.sample(samp, in.uv);
        if (c.a <= 0.0001) { return c; }
        float3 rgb = c.rgb / c.a;                       // unpremultiply
        rgb += p.brightness;
        rgb = (rgb - 0.5) * p.contrast + 0.5;
        float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
        rgb = mix(float3(luma), rgb, p.saturation);
        if (abs(p.hue) > 0.0001) { rgb = hueRotate(rgb, p.hue); }
        rgb = clamp(rgb, 0.0, 1.0);
        return float4(rgb * c.a, c.a);                  // re-premultiply
    }

    // Track matte (Tier 3): mask `content` by `matte` — alpha or luminance, optionally inverted.
    // Both are premultiplied-linear, target-aligned. kind: 0 alpha, 1 alphaInv, 2 luma, 3 lumaInv.
    fragment float4 matte_fragment(FSOut in [[stage_in]],
                                   texture2d<float> content [[texture(0)]],
                                   texture2d<float> matte [[texture(1)]],
                                   sampler samp [[sampler(0)]],
                                   constant uint &kind [[buffer(0)]]) {
        float4 c = content.sample(samp, in.uv);
        float4 m = matte.sample(samp, in.uv);
        float factor = (kind == 0u || kind == 1u) ? m.a : dot(m.rgb, float3(0.2126, 0.7152, 0.0722));
        if (kind == 1u || kind == 3u) { factor = 1.0 - factor; }
        return c * factor; // premultiplied: scales rgb and a together
    }

    // Background blur: show the blurred backdrop only where the layer covers (mask = layer alpha),
    // composited "over" the sharp backdrop. The layer's own content is then drawn on top separately.
    fragment float4 backdrop_fragment(FSOut in [[stage_in]],
                                      texture2d<float> blurred [[texture(0)]],
                                      texture2d<float> mask [[texture(1)]],
                                      sampler samp [[sampler(0)]]) {
        float4 b = blurred.sample(samp, in.uv); // premultiplied blurred backdrop
        float m = mask.sample(samp, in.uv).a;   // layer coverage
        return b * m;
    }
    """
}
#endif
