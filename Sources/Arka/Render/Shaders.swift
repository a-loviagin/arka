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
                                   constant InstanceUniform *instances [[buffer(0)]]) {
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
        float4 stroke = inst.stroke;
        float3 rgb = fill.rgb;
        float a = fill.a * fillCov;
        float sa = stroke.a * strokeCov;
        rgb = mix(rgb, stroke.rgb, sa);
        a = max(a, sa);
        a *= inst.opacity;
        return float4(rgb * a, a);
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
        return float4(inst.tint.rgb * a, a); // pre-multiplied
    }
    """
}
#endif
