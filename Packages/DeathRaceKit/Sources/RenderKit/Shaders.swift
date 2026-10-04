/// The renderer's Metal shaders, compiled at launch with `makeLibrary(source:options:)`.
///
/// They ship as source rather than a built `.metallib` because Xcode 26 installs its Metal
/// toolchain as a separate download, and a build without it can hang silently; the runtime
/// compiler is part of macOS. `DeathRace --print-shader-source` prints this for checking with
/// `xcrun metal`.
///
/// The structs mirror `Uniforms` here and `GlyphInstance` and `DecorationInstance` in
/// SurfaceCore; `static_assert`s and Swift `MemoryLayout` tests keep both sides the same size.
/// Colors arrive as sRGB bytes, red lowest, and are written to a `.bgra8Unorm` target in sRGB
/// as they are.
public enum Shaders {
    public static let source = #"""
        #include <metal_stdlib>
        using namespace metal;

        struct Uniforms {
            float2 viewportSize;  // pixels
            float2 gridOrigin;    // pixels, the top-left of the first cell
            float2 cellSize;      // pixels
            uint columns;
            uint rows;
            uint clearColor;      // packed sRGB, red lowest
            uint dim;             // packed sRGB: what an inactive pane fades toward, alpha how far
        };
        static_assert(sizeof(Uniforms) == 40, "Uniforms must match RenderKit's layout");

        struct GlyphInstance {
            ushort2 cell;
            ushort2 atlasOrigin;
            ushort2 size;
            short2 offset;        // the bitmap's top-left relative to the cell's
            uint color;
            uint flags;           // bit 0: in the color atlas
        };
        static_assert(sizeof(GlyphInstance) == 24, "GlyphInstance must match SurfaceCore's layout");

        struct DecorationInstance {
            ushort cellX;
            ushort cellY;
            ushort cellCount;
            uchar kind;
            uchar thickness;
            short top;            // the box, in pixels from the cell's top
            short height;
            uint color;
        };
        static_assert(sizeof(DecorationInstance) == 16, "DecorationInstance must match SurfaceCore's layout");

        static float4 unpackColor(uint packed) {
            return unpack_unorm4x8_to_float(packed);
        }

        // An inactive pane fades toward the ground. Each layer is faded before it is
        // blended, which composes to the same as fading the finished frame.
        static float4 dimmed(float4 color, float4 dim) {
            return float4(mix(color.rgb, dim.rgb, dim.a), color.a);
        }

        static float4 clipPosition(float2 pixel, float2 viewport) {
            float2 ndc = pixel / viewport * 2.0 - 1.0;
            return float4(ndc.x, -ndc.y, 0.0, 1.0);
        }

        // Backgrounds: one triangle covers the target, and each pixel looks up its cell's color.
        // Outside the grid (the padding) is the clear color.

        struct BackgroundOut {
            float4 position [[position]];
        };

        vertex BackgroundOut backgroundVertex(uint vid [[vertex_id]]) {
            const float2 corners[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
            BackgroundOut out;
            out.position = float4(corners[vid], 0.0, 1.0);
            return out;
        }

        fragment float4 backgroundFragment(BackgroundOut in [[stage_in]],
                                           constant Uniforms &u [[buffer(0)]],
                                           device const uint *colors [[buffer(1)]]) {
            float4 dim = unpackColor(u.dim);
            float2 local = in.position.xy - u.gridOrigin;
            if (local.x < 0.0 || local.y < 0.0) {
                return dimmed(unpackColor(u.clearColor), dim);
            }
            uint2 cell = uint2(local / u.cellSize);
            if (cell.x >= u.columns || cell.y >= u.rows) {
                return dimmed(unpackColor(u.clearColor), dim);
            }
            return dimmed(unpackColor(colors[cell.y * u.columns + cell.x]), dim);
        }

        // Glyphs: one quad per instance, read texel for texel from an atlas: coverage tinted
        // with the text color, or a color glyph as it is. Output is premultiplied.

        struct GlyphOut {
            float4 position [[position]];
            float2 atlasCoord;
            float4 color;
            float4 dim [[flat]];
            uint flags [[flat]];
        };

        vertex GlyphOut glyphVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                    constant Uniforms &u [[buffer(0)]],
                                    device const GlyphInstance *glyphs [[buffer(1)]]) {
            GlyphInstance glyph = glyphs[iid];
            float2 corner = float2(float(vid & 1u), float(vid >> 1u));
            float2 size = float2(glyph.size);
            float2 pixel = u.gridOrigin + float2(glyph.cell) * u.cellSize + float2(glyph.offset) + corner * size;
            GlyphOut out;
            out.position = clipPosition(pixel, u.viewportSize);
            out.atlasCoord = float2(glyph.atlasOrigin) + corner * size;
            out.dim = unpackColor(u.dim);
            out.color = dimmed(unpackColor(glyph.color), out.dim);
            out.flags = glyph.flags;
            return out;
        }

        fragment float4 glyphFragment(GlyphOut in [[stage_in]],
                                      texture2d<float, access::read> mask [[texture(0)]],
                                      texture2d<float, access::read> color [[texture(1)]]) {
            uint2 texel = uint2(in.atlasCoord);
            if ((in.flags & 1u) != 0u) {
                // Premultiplied: fade the color, then multiply by coverage again.
                float4 texelColor = color.read(texel);
                return float4(texelColor.rgb * (1.0 - in.dim.a) + in.dim.rgb * (in.dim.a * texelColor.a),
                              texelColor.a);
            }
            float coverage = mask.read(texel).r;
            return float4(in.color.rgb * coverage, coverage);
        }

        // Decorations: a quad over a run of cells, the pattern drawn from absolute pixel x, so
        // dots, dashes and waves continue from one cell to the next.

        struct DecorationOut {
            float4 position [[position]];
            float2 local;         // x: absolute pixels; y: pixels down from the box's top
            float4 color;
            uint kind [[flat]];
            float thickness [[flat]];
            float height [[flat]];
        };

        vertex DecorationOut decorationVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                              constant Uniforms &u [[buffer(0)]],
                                              device const DecorationInstance *items [[buffer(1)]]) {
            DecorationInstance item = items[iid];
            float2 corner = float2(float(vid & 1u), float(vid >> 1u));
            float2 origin = u.gridOrigin + float2(float(item.cellX), float(item.cellY)) * u.cellSize
                + float2(0.0, float(item.top));
            float2 size = float2(float(item.cellCount) * u.cellSize.x, float(item.height));
            float2 pixel = origin + corner * size;
            DecorationOut out;
            out.position = clipPosition(pixel, u.viewportSize);
            out.local = float2(pixel.x, corner.y * size.y);
            out.color = dimmed(unpackColor(item.color), unpackColor(u.dim));
            out.kind = uint(item.kind);
            out.thickness = max(float(item.thickness), 1.0);
            out.height = float(item.height);
            return out;
        }

        fragment float4 decorationFragment(DecorationOut in [[stage_in]]) {
            float t = in.thickness;
            float x = in.local.x;
            float y = in.local.y;
            float alpha = 1.0;
            switch (in.kind) {
                case 2u: {  // double: two lines, at the top and the bottom of a box three tall
                    alpha = (y < t || y >= in.height - t) ? 1.0 : 0.0;
                    break;
                }
                case 3u: {  // curly: a sine wave filling the box
                    float amplitude = max((in.height - t) * 0.5, 0.5);
                    float wavelength = max(t * 8.0, 6.0);
                    float centre = in.height * 0.5 + amplitude * sin(x / wavelength * 2.0 * M_PI_F);
                    alpha = clamp(t * 0.5 + 0.5 - abs(y - centre), 0.0, 1.0);
                    break;
                }
                case 4u: {  // dotted
                    alpha = fmod(floor(x / t), 2.0) < 1.0 ? 1.0 : 0.0;
                    break;
                }
                case 5u: {  // dashed
                    alpha = fmod(x, t * 6.0) < t * 4.0 ? 1.0 : 0.0;
                    break;
                }
                default:
                    break;
            }
            if (alpha <= 0.0) {
                discard_fragment();
            }
            return float4(in.color.rgb * alpha, alpha);
        }
        """#
}
