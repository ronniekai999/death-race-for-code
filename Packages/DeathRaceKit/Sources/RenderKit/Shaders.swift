/// The renderer's Metal shaders, compiled at launch with `makeLibrary(source:options:)`.
///
/// They ship as source rather than a built `.metallib` because Xcode 26 installs its Metal
/// toolchain as a separate download, and a build without it can hang silently; the runtime
/// compiler is part of macOS. `DeathRace --print-shader-source` prints this for checking with
/// `xcrun metal`.
///
/// The structs mirror `Uniforms` in SurfaceRenderer and `GlyphInstance` and `DecorationInstance`
/// in SurfaceCore; `static_assert`s and Swift `MemoryLayout` tests keep both sides the same size.
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
            uint glow;            // alpha: how strong a bright colour's light is. RGB: XDR's tint, unused
            uint reserved;        // named rather than left as padding: without it Swift's size (44)
                                  // and its stride (48) disagree, and `setVertexBytes` sends the
                                  // stride. XDR's second word goes here.
        };
        static_assert(sizeof(Uniforms) == 48, "Uniforms must match RenderKit's layout");

        struct GlyphInstance {
            ushort2 cell;
            ushort2 atlasOrigin;
            ushort2 size;
            short2 offset;        // the bitmap's top-left relative to the cell's
            uint color;
            uint flags;           // bit 0: in the color atlas; 1-5: columns covered, less one
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

        // A faint star, maybe, in a row's empty end (FrameBuilder marks those cells with alpha
        // 0xFE): from the pixel's position alone, so there is no texture, the stars stay put
        // while text scrolls past, and a fifth of them are brighter, as on the ground.
        static float4 starry(float2 pixel, float4 background) {
            uint2 p = uint2(pixel);
            uint h = (p.x * 0x8DA6B343u) ^ (p.y * 0xD8163841u);
            h ^= h >> 16;
            h *= 0x7FEB352Du;
            h ^= h >> 15;
            h *= 0x846CA68Bu;
            h ^= h >> 16;
            if (h % 40000u != 0u) {
                return float4(background.rgb, 1.0);
            }
            float strength = (h >> 28) < 3u ? 0.55 : 0.22;
            return float4(mix(background.rgb, float3(1.0), strength), 1.0);
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
            uint packed = colors[cell.y * u.columns + cell.x];
            float4 color = unpackColor(packed);
            if ((packed >> 24) == 0xFEu) {
                color = starry(in.position.xy, color);
            }
            return dimmed(color, dim);
        }

        // Glow: a bright colour's own light, scattered from the same glyph buffer the next draw
        // uses, additively and under it. A fully covered pixel therefore keeps exactly the colour
        // it would have without this draw; an antialiased edge pixel picks the halo up through
        // its own `1 - coverage`, which is what makes it read as light rather than as an outline.

        struct GlowOut {
            float4 position [[position]];
            float2 atlasCoord;
            float3 color [[flat]];
            float strength [[flat]];
            float radius [[flat]];
            float2 atlasBoxMin [[flat]];  // this glyph's own rectangle: a tap outside it reads
            float2 atlasBoxMax [[flat]];  // nothing, not whatever was packed beside it
        };

        // Which glyphs emit, from the glyph's own colour. **The twin of `Glow.emissiveStrength`
        // in SurfaceCore**, and nothing can prove the two agree, because this one is a string:
        // the four thresholds and both formulas have to be changed together, and
        // `GlowTests`' per-theme table is what records what they do.
        //
        // Chroma decides, not brightness. On a dark ground the default foreground is the
        // brightest thing on the screen, so a brightness rule would glow every line of ordinary
        // output; saturation is what separates a colour a program chose. Brightness is only a
        // floor, and it is what keeps ANSI black out.
        static float emissive(float3 c) {
            float chroma = max(max(c.r, c.g), c.b) - min(min(c.r, c.g), c.b);
            float luma = dot(c, float3(0.299, 0.587, 0.114));
            return smoothstep(0.28, 0.44, chroma) * smoothstep(0.30, 0.45, luma);
        }

        vertex GlowOut glowVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                  constant Uniforms &u [[buffer(0)]],
                                  device const GlyphInstance *glyphs [[buffer(1)]]) {
            GlyphInstance glyph = glyphs[iid];
            float4 dim = unpackColor(u.dim);
            float3 color = unpackColor(glyph.color).rgb;
            float strength = unpackColor(u.glow).a * emissive(color);
            // A colour glyph carries its own colour and is not in the mask atlas this reads at
            // all; and a pane being faded is not the one you are working in, which is where
            // "only the focused pane glows" comes from for nothing.
            if ((glyph.flags & 1u) != 0u || dim.a > 0.0) { strength = 0.0; }

            GlowOut out;
            // Half of one least-significant bit: the light this draw adds is at most
            // `color * strength`, so below this it cannot change a single pixel of an 8-bit
            // target and the fragments would be spent for nothing. A floor on the *product*,
            // not on the rule — the Swift twin reports the rule's own answer, which for the
            // most saturated grey anyone shipped is six ten-thousandths.
            if (strength < 0.5 / 255.0) {
                // Outside the clip volume and zero area, so both triangles go and no fragment
                // runs: one test per glyph rather than per pixel, which is what keeps a screen
                // of body text costing nothing.
                out.position = float4(-2.0, -2.0, 0.0, 1.0);
                out.atlasCoord = float2(0.0);
                out.color = float3(0.0);
                out.strength = 0.0;
                out.radius = 1.0;
                out.atlasBoxMin = float2(0.0);
                out.atlasBoxMax = float2(0.0);
                return out;
            }

            // About three device pixels at 13 pt on a 2x display. From the cell rather than
            // fixed, so the halo keeps its proportion as the font size changes.
            float radius = max(2.0, round(u.cellSize.y * 0.10));
            // One past the furthest tap, so the quad's own rim is reliably zero and there is no
            // step where it ends.
            float2 grow = float2(radius + 1.0);
            float2 corner = float2(float(vid & 1u), float(vid >> 1u));
            float2 size = float2(glyph.size);
            float2 origin = u.gridOrigin + float2(glyph.cell) * u.cellSize + float2(glyph.offset);
            out.position = clipPosition(origin - grow + corner * (size + 2.0 * grow), u.viewportSize);
            // The atlas is read texel for pixel, so growing both by the same amount keeps that
            // mapping exact.
            out.atlasCoord = float2(glyph.atlasOrigin) - grow + corner * (size + 2.0 * grow);
            out.color = color;
            out.strength = strength;
            out.radius = radius;
            out.atlasBoxMin = float2(glyph.atlasOrigin);
            out.atlasBoxMax = float2(glyph.atlasOrigin) + size;
            return out;
        }

        // `access::read` returns zero outside the *texture*, and the shelf allocator pads a glyph
        // by one pixel, so a tap a few pixels out would otherwise read a neighbouring glyph and
        // the halo would carry pieces of it.
        static float glowTap(texture2d<float, access::read> mask, float2 at, float2 lo, float2 hi) {
            if (any(at < lo) || any(at >= hi)) { return 0.0; }
            return mask.read(uint2(at)).r;
        }

        fragment float4 glowFragment(GlowOut in [[stage_in]],
                                     texture2d<float, access::read> mask [[texture(0)]]) {
            // Thirteen taps on two rings. A separable blur needs an intermediate texture, which
            // is the one thing this renderer does not have anywhere; at a text radius of about
            // three pixels a ring and a true 7x7 Gaussian are indistinguishable, and 7x7 is 49
            // taps. If a profile ever demands it, the fallback is a pre-blurred atlas.
            const float diagonal = 0.70710678;
            float r = in.radius;
            float2 p = in.atlasCoord;
            float2 lo = in.atlasBoxMin;
            float2 hi = in.atlasBoxMax;
            float d = r * diagonal;
            float e = d * 0.5;
            float middle = glowTap(mask, p, lo, hi);
            float near = glowTap(mask, p + float2(e, e), lo, hi)
                + glowTap(mask, p + float2(e, -e), lo, hi)
                + glowTap(mask, p + float2(-e, e), lo, hi)
                + glowTap(mask, p + float2(-e, -e), lo, hi);
            float ring = glowTap(mask, p + float2(r, 0.0), lo, hi)
                + glowTap(mask, p + float2(-r, 0.0), lo, hi)
                + glowTap(mask, p + float2(0.0, r), lo, hi)
                + glowTap(mask, p + float2(0.0, -r), lo, hi)
                + glowTap(mask, p + float2(d, d), lo, hi)
                + glowTap(mask, p + float2(d, -d), lo, hi)
                + glowTap(mask, p + float2(-d, d), lo, hi)
                + glowTap(mask, p + float2(-d, -d), lo, hi);
            // 1 + 4x0.7 + 8x0.25 = 5.8, so the middle of a thick stroke reaches full strength.
            float coverage = (middle + near * 0.7 + ring * 0.25) / 5.8;
            // Additive, with an RGB-only write mask on the pipeline: the target's alpha is never
            // touched, whatever this returns.
            return float4(in.color * (coverage * in.strength), 0.0);
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
            float left [[flat]];  // the run's own left edge, for a pattern measured from it
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
            out.left = origin.x;
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
                case 8u: {  // rail: a bar hugging the left edge of the run, however tall it is
                    // From the run's own left edge, not from absolute x: this is the one
                    // pattern that is about where the box starts rather than about continuing
                    // across cells. Horizontal geometry is whole cells, so without this a rail
                    // would be a cell-wide block over the first character of every line.
                    alpha = (x - in.left) < t ? 1.0 : 0.0;
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
