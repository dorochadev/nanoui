// Panes of Liquid Glass (glass.zig), after shader.metal: the backdrop's
// kernels, which average the frame's pixels around a pane and blur them,
// and the pane's fragment function. glass.zig computes the same on the CPU.

// A pane's backdrop (glass.zig's Backdrop): the frame's pixels of area
// (x0, y0, x1, y1), averaged over squares of down pixels into size texels,
// blurred by sigma texels out to radius each way.
struct GlassBackdrop {
    int4 area;
    int2 size;
    int down;
    int radius;
    float sigma;
};

kernel void glass_down(texture2d<float, access::read> frame [[texture(0)]],
                       texture2d<float, access::write> dst [[texture(1)]],
                       constant GlassBackdrop &b [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= b.size.x || int(gid.y) >= b.size.y) return;
    int x0 = b.area.x + int(gid.x) * b.down;
    int y0 = b.area.y + int(gid.y) * b.down;
    int x1 = min(x0 + b.down, b.area.z);
    int y1 = min(y0 + b.down, b.area.w);
    float3 sum = float3(0.0);
    for (int y = y0; y < y1; y++)
        for (int x = x0; x < x1; x++) sum += frame.read(uint2(x, y)).rgb;
    dst.write(float4(sum / float((x1 - x0) * (y1 - y0)), 1.0), gid);
}

kernel void glass_blur(texture2d<float, access::read> src [[texture(0)]],
                       texture2d<float, access::write> dst [[texture(1)]],
                       constant GlassBackdrop &b [[buffer(0)]],
                       constant int2 &dir [[buffer(1)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= b.size.x || int(gid.y) >= b.size.y) return;
    float3 sum = float3(0.0);
    float wsum = 0.0;
    for (int k = -b.radius; k <= b.radius; k++) {
        int2 p = clamp(int2(gid) + dir * k, int2(0), b.size - 1);
        float w = exp(-float(k * k) / (2.0 * b.sigma * b.sigma));
        sum += src.read(uint2(p)).rgb * w;
        wsum += w;
    }
    dst.write(float4(sum / wsum, 1.0), gid);
}

// Where the pane's backdrop lies: its area's corner in the frame's pixels,
// its size in texels, the averaging, and the frame's pixels a point.
struct GlassPane {
    float2 origin;
    float2 size;
    float down;
    float scale;
};

static float3 glass_texel(texture2d<float> t, int2 p, int2 size) {
    return t.read(uint2(clamp(p, int2(0), size - 1))).rgb;
}

// The backdrop at pixel q of the frame, bilinear from its texels.
static float3 glass_sample(texture2d<float> t, GlassPane pane, float2 q) {
    float2 u = (q - pane.origin) / pane.down - 0.5;
    float2 f = floor(u);
    float2 w = u - f;
    int2 p = int2(f);
    int2 size = int2(pane.size);
    float3 top = glass_texel(t, p, size) * (1.0 - w.x) + glass_texel(t, p + int2(1, 0), size) * w.x;
    float3 bot = glass_texel(t, p + int2(0, 1), size) * (1.0 - w.x) + glass_texel(t, p + int2(1, 1), size) * w.x;
    return top * (1.0 - w.y) + bot * w.y;
}

static float glass_lens(float t, float bezel) {
    if (bezel <= 0.0 || t >= bezel) return 0.0;
    float u = 1.0 - max(t, 0.0) / bezel;
    float v = 1.0 - u * u * u * u;
    float a = sqrt(v * sqrt(v));
    float b = u * u * u;
    float n = sqrt(a * a + b * b);
    float s = b / n, c = a / n;
    float st = s / 1.5;
    float ct = sqrt(1.0 - st * st);
    return (s * ct - c * st) / (c * ct + s * st) / 1.1180340;
}

static float2 glass_normal(float2 q, float2 h, float radius) {
    float r = min(radius * 1.5, min(h.x, h.y));
    float2 a = abs(q) - (h - r);
    if (a.x > 0.0 || a.y > 0.0) {
        float2 m = max(a, float2(0.0));
        return sign(q) * m / sqrt(m.x * m.x + m.y * m.y);
    }
    return a.x > a.y ? float2(sign(q.x), 0.0) : float2(0.0, sign(q.y));
}

static float3 glass_tone(float3 c, float4 tone) {
    float l = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
    float t = tone.x + (tone.y - tone.x) * (1.0 - pow(max(1.0 - l, 0.0), tone.z));
    float k = (tone.y - tone.x) * tone.w;
    return clamp(t + (c - l) * k, 0.0, 1.0);
}

// A shaped pane's field in the image atlas (glass_field.zig), its texel p
// clamped to its w x h texels below the header row at o: the distance to
// the edge (texels) and the way it faces. BGRA8: b is byte 0, g byte 1.
static float3 glass_field_texel(texture2d<float> t, uint2 o, int2 p, int2 size) {
    float4 c = round(t.read(o + uint2(clamp(p, int2(0), size - 1)) + uint2(0, 1)) * 255.0);
    return float3((c.b + c.g * 256.0 - 32768.0) / 128.0, (c.r - 128.0) / 127.0, (c.a - 128.0) / 127.0);
}

// The shape at q, pixels from the corner of a pane size pixels, from its
// field at `at` (1 + x + y * 2048) in the image atlas, bilinear: the
// distance to its edge (pixels, less than 0 inside), the way the edge
// faces, and how deep its deepest point is (pixels).
static float4 glass_field(texture2d<float> t, float at, float2 q, float2 size) {
    uint k = uint(at) - 1u;
    uint2 o = uint2(k & 2047u, k >> 11);
    float4 h0 = round(t.read(o) * 255.0);
    float4 h1 = round(t.read(o + uint2(1, 0)) * 255.0);
    int2 n = int2(int(h0.b + h0.g * 256.0), int(h0.r + h0.a * 256.0));
    float2 nf = float2(n);
    float px = 0.5 * (size.x / nf.x + size.y / nf.y);
    float2 u = q / size * nf - 0.5;
    float2 f = floor(u);
    float2 w = u - f;
    int2 p = int2(f);
    float3 a = glass_field_texel(t, o, p, n);
    float3 b = glass_field_texel(t, o, p + int2(1, 0), n);
    float3 c = glass_field_texel(t, o, p + int2(0, 1), n);
    float3 d = glass_field_texel(t, o, p + int2(1, 1), n);
    float3 top = a * (1.0 - w.x) + b * w.x;
    float3 bot = c * (1.0 - w.x) + d * w.x;
    float3 v = top * (1.0 - w.y) + bot * w.y;
    return float4(v.x * px, v.y, v.z, (h1.b + h1.g * 256.0 - 32768.0) / 128.0 * px);
}

fragment float4 fs_glass(VOut in [[stage_in]],
                         constant Instance *instances [[buffer(0)]],
                         constant GlassPane &pane [[buffer(1)]],
                         texture2d<float> images [[texture(1)]],
                         texture2d<float> backdrop [[texture(2)]]) {
    Instance i = instances[in.inst];
    float clip_cover = clip_coverage(in, i);
    // The pane's edge, antialiased as a quad's.
    float2 hp = i.rect.zw * 0.5;
    float d = rounded_box(in.local - hp, hp, min(i.radius, min(hp.x, hp.y)));
    float aa = max(fwidth(d), 0.0001) * 0.5;
    float edge = 1.0 - smoothstep(-aa, aa, d);

    // The optics, in the frame's pixels.
    float s = pane.scale;
    float2 p = in.world * s;
    float2 h = hp * s;
    float2 q = p - i.rect.xy * s - h;
    float bezel = i.uv.x * s;
    float refraction = i.uv.y * s;
    float rim_width = i.uv.w * s;
    float t;
    float2 n = float2(0.0);
    if (i.pulse.w > 0.0) {
        // In a shape: its edge, depth and facing from its field instead.
        float4 f = glass_field(images, i.pulse.w, p - i.rect.xy * s, i.rect.zw * s);
        float fa = max(abs(f.y) + abs(f.z), 0.0001) * 0.5;
        edge = 1.0 - smoothstep(-fa, fa, f.x);
        t = max(-f.x, 0.0);
        n = f.yz;
        if (f.w < bezel) {
            refraction *= f.w / bezel;
            bezel = f.w;
        }
    } else {
        float rr = min(i.radius * s, min(h.x, h.y));
        t = max(-rounded_box(q, h, rr), 0.0);
        if (t < bezel || t < 3.0 * rim_width) n = glass_normal(q, h, rr);
    }
    float coverage = edge * clip_cover * i.uv.z;
    float2 at = p;
    if (t < bezel) at -= n * (refraction * glass_lens(t, bezel));
    float3 c = glass_tone(glass_sample(backdrop, pane, at), i.border_color);
    c += (i.color.rgb - c) * i.color.a;
    if (t < 3.0 * rim_width) {
        float r = t / rim_width;
        float a = 0.35 * exp(-r * r);
        // Light from above and below: the more the edge faces it, the lighter.
        c += (abs(n.y) - c) * a;
    }
    return float4(c, 1.0) * coverage;
}
