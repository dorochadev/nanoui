//! A pane of glass in a shape (`Glass.shape`): what the SVG document fills,
//! as a signed distance field the renderers read for the pane's edge, how
//! far inside it each pixel is (its bezel and rim) and which way the edge
//! faces. Drawn once for each shape and size, and packed into the image
//! atlas as a picture is (`images.zig`), so the GPU and the CPU read the
//! same bytes (`glass.zig`'s `Field`, `glass.metal`'s `glass_field`).
//!
//! The picture is `w` × `h + 1` texels. Its first row is a header: texel 0
//! holds `w` and `h`, texel 1 the distance of the shape's deepest point.
//! Below it, texel (x, y) is the shape at the middle of that texel: bytes 0
//! and 1 the distance to its edge (in texels, × 128, + 32768; less than
//! 32768 inside), bytes 2 and 3 the direction the edge faces (x, y: × 127,
//! + 128), from the distance smoothed so it turns gradually across a narrow
//! part instead of flipping.
const std = @import("std");
const svg = @import("svg.zig");
const Point = @import("svg_geom.zig").Point;

/// The longest side a field is drawn at; a larger pane stretches it.
pub const max_side: u32 = 512;

/// The field's size for a pane `w` × `h` pixels: a texel a pixel, up to
/// `max_side`.
pub fn sizeFor(w: f32, h: f32) [2]u32 {
    const k = @min(1, @as(f32, @floatFromInt(max_side)) / @max(w, h, 1));
    return .{ @intFromFloat(@max(2, @round(w * k))), @intFromFloat(@max(1, @round(h * k))) };
}

pub fn encodeDistance(d: f32) u16 {
    return @intFromFloat(std.math.clamp(@round(d * 128) + 32768, 0, 65535));
}

fn encodeNormal(v: f32) u8 {
    return @intFromFloat(std.math.clamp(@round(v * 127) + 128, 1, 255));
}

const Segment = struct { a: Point, b: Point, shape: usize };

/// The field of the SVG document `src` fitted into `w` × `h` texels
/// (centered, keeping its proportions), as BGRA bytes, `w` × `h + 1`.
pub fn draw(gpa: std.mem.Allocator, src: []const u8, w: u32, h: u32) ![]u8 {
    if (w < 2 or h < 1 or w > 4096 or h > 4096) return error.BadSize;
    var o = try svg.outline(gpa, src, w, h);
    defer o.deinit();
    var segs: std.ArrayList(Segment) = .empty;
    defer segs.deinit(gpa);
    for (o.rings.items) |r| {
        const pts = o.of(r);
        for (pts, 0..) |a, i| {
            const b = pts[(i + 1) % pts.len];
            if (a[0] != b[0] or a[1] != b[1]) try segs.append(gpa, .{ .a = a, .b = b, .shape = r.shape });
        }
    }
    // Measured past the field's sides by as far as the smoothing reaches,
    // so it turns the same at a side as anywhere.
    const sigma = @max(1, 0.03 * @as(f32, @floatFromInt(@max(w, h))));
    const margin: u32 = @intFromFloat(@ceil(3 * sigma));
    for (segs.items) |*sg| for ([_]*Point{ &sg.a, &sg.b }) |pt| {
        pt[0] += @floatFromInt(margin);
        pt[1] += @floatFromInt(margin);
    };
    const pw = w + 2 * margin;
    const ph = h + 2 * margin;
    const n: usize = @as(usize, pw) * ph;
    const dist = try gpa.alloc(f32, n);
    defer gpa.free(dist);
    try distances(gpa, segs.items, pw, ph, dist);
    const inside = try gpa.alloc(bool, n);
    defer gpa.free(inside);
    try insides(gpa, segs.items, o.rules.items, pw, ph, inside);
    var deepest: f32 = 0;
    for (dist, inside) |*d, in| if (in) {
        deepest = @max(deepest, d.*);
        d.* = -d.*;
    };

    const smooth = try gpa.alloc(f32, n);
    defer gpa.free(smooth);
    try blur(gpa, dist, smooth, pw, ph, sigma);

    const out = try gpa.alloc(u8, @as(usize, w) * (h + 1) * 4);
    @memset(out, 0);
    std.mem.writeInt(u16, out[0..2], @intCast(w), .little);
    std.mem.writeInt(u16, out[2..4], @intCast(h), .little);
    std.mem.writeInt(u16, out[4..6], encodeDistance(deepest), .little);
    const wi: usize = w;
    const pwi: usize = pw;
    for (0..h) |y| for (0..wi) |x| {
        const at = ((y + 1) * wi + x) * 4;
        const k = (y + margin) * pwi + x + margin;
        std.mem.writeInt(u16, out[at..][0..2], encodeDistance(dist[k]), .little);
        // The smoothed distance's slope, by central differences.
        out[at + 2] = encodeNormal((smooth[k + 1] - smooth[k - 1]) / 2);
        out[at + 3] = encodeNormal((smooth[k + pwi] - smooth[k - pwi]) / 2);
    };
    return out;
}

fn segDist2(p: Point, s: Segment) f32 {
    const ex = s.b[0] - s.a[0];
    const ey = s.b[1] - s.a[1];
    const px = p[0] - s.a[0];
    const py = p[1] - s.a[1];
    const t = std.math.clamp((px * ex + py * ey) / (ex * ex + ey * ey), 0, 1);
    const dx = px - ex * t;
    const dy = py - ey * t;
    return dx * dx + dy * dy;
}

/// The distance from each texel's middle to the nearest segment. Texels
/// are taken in cells: only segments that could be nearest to some texel
/// of a cell (within the cell's nearest plus its diagonal) are measured.
fn distances(gpa: std.mem.Allocator, segs: []const Segment, w: u32, h: u32, out: []f32) !void {
    if (segs.len == 0) {
        @memset(out, std.math.inf(f32));
        return;
    }
    const cell = 8;
    const reach: f32 = cell * std.math.sqrt2;
    const near = try gpa.alloc(f32, segs.len);
    defer gpa.free(near);
    var picked: std.ArrayList(usize) = .empty;
    defer picked.deinit(gpa);
    var cy: usize = 0;
    while (cy < h) : (cy += cell) {
        var cx: usize = 0;
        while (cx < w) : (cx += cell) {
            const mid: Point = .{ @as(f32, @floatFromInt(cx)) + cell / 2, @as(f32, @floatFromInt(cy)) + cell / 2 };
            var best = std.math.inf(f32);
            for (segs, near) |s, *d| {
                d.* = @sqrt(segDist2(mid, s));
                best = @min(best, d.*);
            }
            picked.clearRetainingCapacity();
            for (near, 0..) |d, k| if (d <= best + reach) try picked.append(gpa, k);
            for (cy..@min(cy + cell, h)) |y| for (cx..@min(cx + cell, w)) |x| {
                const p: Point = .{ @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5 };
                var d2 = std.math.inf(f32);
                for (picked.items) |k| d2 = @min(d2, segDist2(p, segs[k]));
                out[y * w + x] = @sqrt(d2);
            };
        }
    }
}

const Crossing = struct { x: f32, dir: i8 };

/// Whether each texel's middle is filled: along each row of middles, each
/// shape's crossings walked with its fill rule; filled by any shape.
fn insides(gpa: std.mem.Allocator, segs: []const Segment, rules: []const @import("svg_raster.zig").Rule, w: u32, h: u32, out: []bool) !void {
    @memset(out, false);
    var xs: std.ArrayList(Crossing) = .empty;
    defer xs.deinit(gpa);
    for (rules, 0..) |rule, shape| for (0..h) |y| {
        const sy = @as(f32, @floatFromInt(y)) + 0.5;
        xs.clearRetainingCapacity();
        for (segs) |s| {
            if (s.shape != shape) continue;
            const up = s.a[1] < s.b[1];
            const y0 = if (up) s.a[1] else s.b[1];
            const y1 = if (up) s.b[1] else s.a[1];
            if (!(sy >= y0 and sy < y1)) continue;
            const t = (sy - s.a[1]) / (s.b[1] - s.a[1]);
            try xs.append(gpa, .{ .x = s.a[0] + (s.b[0] - s.a[0]) * t, .dir = if (up) 1 else -1 });
        }
        std.mem.sort(Crossing, xs.items, {}, struct {
            fn lt(_: void, a: Crossing, b: Crossing) bool {
                return a.x < b.x;
            }
        }.lt);
        var wind: i32 = 0;
        var k: usize = 0;
        for (0..w) |x| {
            const sx = @as(f32, @floatFromInt(x)) + 0.5;
            while (k < xs.items.len and xs.items[k].x <= sx) : (k += 1) wind += xs.items[k].dir;
            const in = switch (rule) {
                .nonzero => wind != 0,
                .evenodd => @mod(wind, 2) != 0,
            };
            if (in) out[y * w + x] = true;
        }
    };
}

/// A Gaussian of standard deviation `sigma` texels, along rows then
/// columns, its edges clamped.
fn blur(gpa: std.mem.Allocator, src: []const f32, dst: []f32, w: u32, h: u32, sigma: f32) !void {
    const radius: usize = @intFromFloat(@ceil(3 * sigma));
    const kernel = try gpa.alloc(f32, 2 * radius + 1);
    defer gpa.free(kernel);
    var sum: f32 = 0;
    for (kernel, 0..) |*k, i| {
        const x = @as(f32, @floatFromInt(i)) - @as(f32, @floatFromInt(radius));
        k.* = @exp(-(x * x) / (2 * sigma * sigma));
        sum += k.*;
    }
    for (kernel) |*k| k.* /= sum;
    const tmp = try gpa.alloc(f32, src.len);
    defer gpa.free(tmp);
    const wi: usize = w;
    const hi: usize = h;
    const r: isize = @intCast(radius);
    for (0..hi) |y| for (0..wi) |x| {
        var acc: f32 = 0;
        for (kernel, 0..) |k, i| {
            const sx: usize = @intCast(std.math.clamp(@as(isize, @intCast(x)) + @as(isize, @intCast(i)) - r, 0, @as(isize, @intCast(wi)) - 1));
            acc += src[y * wi + sx] * k;
        }
        tmp[y * wi + x] = acc;
    };
    for (0..hi) |y| for (0..wi) |x| {
        var acc: f32 = 0;
        for (kernel, 0..) |k, i| {
            const sy: usize = @intCast(std.math.clamp(@as(isize, @intCast(y)) + @as(isize, @intCast(i)) - r, 0, @as(isize, @intCast(hi)) - 1));
            acc += tmp[sy * wi + x] * k;
        }
        dst[y * wi + x] = acc;
    };
}

fn texel(px: []const u8, w: u32, x: usize, y: usize) struct { d: f32, n: [2]f32 } {
    const at = ((y + 1) * w + x) * 4;
    const d = @as(f32, @floatFromInt(std.mem.readInt(u16, px[at..][0..2], .little))) - 32768;
    return .{ .d = d / 128, .n = .{ (@as(f32, @floatFromInt(px[at + 2])) - 128) / 127, (@as(f32, @floatFromInt(px[at + 3])) - 128) / 127 } };
}

test "a ring's field: negative in the band, the hole and the outside positive, edges facing out of the glass" {
    const gpa = std.testing.allocator;
    // A ring by two circles wound the same way under evenodd.
    const ring =
        \\<svg viewBox="0 0 100 100"><path fill-rule="evenodd" d="M50 2a48 48 0 1 0 0.01 0zM50 26a24 24 0 1 0 0.01 0z"/></svg>
    ;
    const px = try draw(gpa, ring, 100, 100);
    defer gpa.free(px);
    try std.testing.expectEqual(@as(u16, 100), std.mem.readInt(u16, px[0..2], .little));
    try std.testing.expectEqual(@as(u16, 100), std.mem.readInt(u16, px[2..4], .little));
    // The band is 24 wide: its middle is 12 from either edge.
    const deepest = @as(f32, @floatFromInt(std.mem.readInt(u16, px[4..6], .little))) / 128 - 256;
    try std.testing.expectApproxEqAbs(@as(f32, 12), deepest, 0.6);
    // By the hole's middle (texel 50's is half a texel off), 24 from its
    // edge; the band's middle; a corner.
    try std.testing.expectApproxEqAbs(@as(f32, 24 - std.math.sqrt1_2), texel(px, 100, 50, 50).d, 0.2);
    try std.testing.expect(texel(px, 100, 50, 13).d < -10);
    try std.testing.expect(texel(px, 100, 1, 1).d > 10);
    // At the top of the outer edge the edge faces up; at the top of the
    // hole's edge, down, into the hole.
    try std.testing.expect(texel(px, 100, 50, 3).n[1] < -0.9);
    try std.testing.expect(texel(px, 100, 50, 25).n[1] > 0.9);
    try std.testing.expect(@abs(texel(px, 100, 50, 3).n[0]) < 0.1);
}
