//! Native glass (macOS 26+'s NSGlassEffectView), sorted out of a frame:
//! a native pane refracts what's in the window behind it, so what a pane
//! shows through must be drawn in a layer under it and what's on it (its
//! label, a menu over it) in a layer over it. `split` sorts a frame's
//! instances, in paint order, into those two layers and the panes between
//! them, by the painter's rule: what's painted after a pane and overlaps it
//! (or comes near it: `near`) goes over it, the rest under. A pane that something already over a pane
//! overlaps (glass on what's on glass) can't go between the two, and is
//! drawn by the shader in the upper layer instead.
const std = @import("std");
const gpu = @import("gpu.zig");
const types = @import("types.zig");

/// A glass pane paint found that may be native: its instance in the frame
/// and what the instance doesn't say.
pub const Candidate = struct {
    /// Its index in the frame's instances.
    at: u32,
    /// The node's id, for keeping its view from frame to frame.
    id: u64,
    style: types.Glass.Kind,
    /// Its tint as asked for (the instance's is mixed for the shader).
    tint: types.Color,
    /// It's a control: the glass answers presses (macOS 27).
    interactive: bool,
};

/// A pane to show as a native view, in points, as laid out this frame.
pub const Pane = struct {
    id: u64,
    rect: [4]f32,
    /// What shows of it: the clip it was painted in (x0, y0, x1, y1).
    clip: [4]f32,
    radius: f32,
    style: types.Glass.Kind,
    tint: types.Color,
    opacity: f32,
    interactive: bool,
};

pub const Split = struct {
    under: std.ArrayList(gpu.Instance) = .empty,
    over: std.ArrayList(gpu.Instance) = .empty,
    panes: std.ArrayList(Pane) = .empty,
    /// What's in `over`, as bounds, for the painter's rule.
    over_rects: std.ArrayList([4]f32) = .empty,

    pub fn deinit(s: *Split, gpa: std.mem.Allocator) void {
        s.under.deinit(gpa);
        s.over.deinit(gpa);
        s.panes.deinit(gpa);
        s.over_rects.deinit(gpa);
    }

    fn clear(s: *Split) void {
        s.under.clearRetainingCapacity();
        s.over.clearRetainingCapacity();
        s.panes.clearRetainingCapacity();
        s.over_rects.clearRetainingCapacity();
    }
};

/// Sorts `frame` (paint's instances) into `out`, given the panes paint
/// marked as `candidates` (in paint order). Holes are cut in both layers.
pub fn split(gpa: std.mem.Allocator, frame: []const gpu.Instance, candidates: []const Candidate, out: *Split) !void {
    out.clear();
    try out.under.ensureTotalCapacity(gpa, frame.len);
    var next: usize = 0;
    // An opacity group (one level: paint doesn't nest them) opens in a layer
    // when something in it lands there, and closes in each it opened in.
    var group_begin: ?gpu.Instance = null;
    var group_in: [2]bool = .{ false, false };
    for (frame, 0..) |inst, i| {
        const candidate: ?Candidate = if (next < candidates.len and candidates[next].at == i) blk: {
            next += 1;
            break :blk candidates[next - 1];
        } else null;
        if (inst.kind == gpu.Kind.layer_begin) {
            group_begin = inst;
            group_in = .{ false, false };
            continue;
        }
        if (inst.kind == gpu.Kind.layer_end) {
            if (group_in[0]) try out.under.append(gpa, inst);
            if (group_in[1]) try out.over.append(gpa, inst);
            group_begin = null;
            continue;
        }
        if (inst.kind == gpu.Kind.hole) {
            try out.under.append(gpa, inst);
            try out.over.append(gpa, inst);
            continue;
        }
        const bounds = visible(inst);
        if (empty(bounds)) continue;
        if (candidate) |c| if (group_begin == null and native(inst) and !overlapsAny(bounds, out.over_rects.items)) {
            try out.panes.append(gpa, .{
                .id = c.id,
                .rect = inst.rect,
                .clip = inst.clip,
                .radius = @min(@abs(inst.radius), @min(inst.rect[2], inst.rect[3]) / 2),
                .style = c.style,
                .tint = c.tint,
                .opacity = inst.uv[2],
                .interactive = c.interactive,
            });
            continue;
        };
        const over = overlapsPane(grow(bounds, near), out.panes.items) or overlapsAny(bounds, out.over_rects.items);
        const layer: usize = @intFromBool(over);
        if (group_begin) |g| if (!group_in[layer]) {
            group_in[layer] = true;
            try (if (over) &out.over else &out.under).append(gpa, g);
        };
        if (over) {
            try out.over.append(gpa, inst);
            try out.over_rects.append(gpa, bounds);
        } else out.under.appendAssumeCapacity(inst);
    }
}

/// How near a pane what's painted after it goes over it, though it doesn't
/// touch it. A pane's view reaches the screen a frame or two before the
/// frame it was placed in (the layers are drawn ahead), so a pane that
/// moves is a little ahead of what's drawn: a label it's about to reach
/// would be under it for that while. Over a pane is always right for what
/// is painted after it; it only costs a later pane over it being native.
const near: f32 = 32;

fn grow(r: [4]f32, by: f32) [4]f32 {
    return .{ r[0] - by, r[1] - by, r[2] + by, r[3] + by };
}

/// A pane that's flat and upright: one turned, spun or rotated stays the
/// shader's.
fn native(inst: gpu.Instance) bool {
    return inst.xf[0] == 0 and inst.xf[1] == 0 and inst.turn[0] == 0 and inst.pulse[3] <= 0;
}

/// What shows of an instance: its rect within its clip (x0, y0, x1, y1).
fn visible(inst: gpu.Instance) [4]f32 {
    return .{
        @max(inst.rect[0], inst.clip[0]),
        @max(inst.rect[1], inst.clip[1]),
        @min(inst.rect[0] + inst.rect[2], inst.clip[2]),
        @min(inst.rect[1] + inst.rect[3], inst.clip[3]),
    };
}

fn empty(r: [4]f32) bool {
    return r[2] <= r[0] or r[3] <= r[1];
}

fn overlaps(a: [4]f32, b: [4]f32) bool {
    return a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3];
}

fn overlapsAny(r: [4]f32, rects: []const [4]f32) bool {
    for (rects) |o| if (overlaps(r, o)) return true;
    return false;
}

fn overlapsPane(r: [4]f32, panes: []const Pane) bool {
    for (panes) |p| if (overlaps(r, visible(.{ .rect = p.rect, .color = .{ 0, 0, 0, 0 }, .clip = p.clip }))) return true;
    return false;
}

const testing = std.testing;

fn quad(x: f32, y: f32, w: f32, h: f32) gpu.Instance {
    return .{ .rect = .{ x, y, w, h }, .color = .{ 1, 1, 1, 1 } };
}

fn pane(x: f32, y: f32, w: f32, h: f32) gpu.Instance {
    var p = quad(x, y, w, h);
    p.kind = gpu.Kind.glass;
    p.radius = 100;
    p.uv = .{ 0, 0, 1, 0 };
    return p;
}

fn cand(at: u32, id: u64) Candidate {
    return .{ .at = at, .id = id, .style = .regular, .tint = .transparent, .interactive = true };
}

test "what's under a pane stays under; its label and a menu over it go over" {
    const frame = [_]gpu.Instance{
        quad(0, 0, 400, 300), // the window's background
        quad(10, 10, 100, 20), // a row the pane doesn't cover
        pane(200, 100, 80, 30), // a button's glass
        quad(210, 105, 60, 20), // its label
        quad(10, 200, 100, 20), // a row below, clear of the pane
        quad(150, 80, 200, 100), // a menu, painted last, over the button
    };
    var s: Split = .{};
    defer s.deinit(testing.allocator);
    try split(testing.allocator, &frame, &.{cand(2, 7)}, &s);
    try testing.expectEqual(@as(usize, 1), s.panes.items.len);
    try testing.expectEqual(@as(u64, 7), s.panes.items[0].id);
    // A capsule's radius is half its height.
    try testing.expectEqual(@as(f32, 15), s.panes.items[0].radius);
    try testing.expectEqual(@as(usize, 3), s.under.items.len);
    try testing.expectEqual(@as(usize, 2), s.over.items.len);
    try testing.expectEqual(@as(f32, 210), s.over.items[0].rect[0]);
    try testing.expectEqual(@as(f32, 150), s.over.items[1].rect[0]);
}

test "glass on what's on glass is the shader's, over" {
    const frame = [_]gpu.Instance{
        quad(0, 0, 400, 300),
        pane(50, 50, 200, 100), // a panel
        quad(60, 60, 180, 20), // a row on it
        pane(70, 62, 40, 16), // a pill on that row
    };
    var s: Split = .{};
    defer s.deinit(testing.allocator);
    try split(testing.allocator, &frame, &.{ cand(1, 1), cand(3, 2) }, &s);
    try testing.expectEqual(@as(usize, 1), s.panes.items.len);
    try testing.expectEqual(@as(u64, 1), s.panes.items[0].id);
    try testing.expectEqual(@as(usize, 2), s.over.items.len);
    try testing.expectEqual(gpu.Kind.glass, s.over.items[1].kind);
}

test "holes are cut in both layers, and a group opens only where its content lands" {
    var begin = quad(0, 0, 400, 300);
    begin.kind = gpu.Kind.layer_begin;
    var end = begin;
    end.kind = gpu.Kind.layer_end;
    var hole = quad(100, 0, 300, 300);
    hole.kind = gpu.Kind.hole;
    const frame = [_]gpu.Instance{
        hole,
        pane(10, 10, 60, 30),
        begin,
        quad(12, 12, 20, 10), // on the pane: over
        quad(200, 200, 20, 10), // clear of it: under
        end,
    };
    var s: Split = .{};
    defer s.deinit(testing.allocator);
    try split(testing.allocator, &frame, &.{cand(1, 3)}, &s);
    try testing.expectEqual(gpu.Kind.hole, s.under.items[0].kind);
    try testing.expectEqual(gpu.Kind.hole, s.over.items[0].kind);
    try testing.expectEqual(gpu.Kind.layer_begin, s.over.items[1].kind);
    try testing.expectEqual(gpu.Kind.layer_end, s.over.items[3].kind);
    try testing.expectEqual(gpu.Kind.layer_begin, s.under.items[1].kind);
    try testing.expectEqual(gpu.Kind.layer_end, s.under.items[3].kind);
}

test "a pane outside its clip, or turned, isn't native" {
    var turned = pane(10, 10, 60, 30);
    turned.xf = .{ 0.3, 0, 40, 25 };
    var clipped = pane(10, 100, 60, 30);
    clipped.clip = .{ 0, 0, 400, 50 };
    const frame = [_]gpu.Instance{ quad(0, 0, 400, 300), turned, clipped };
    var s: Split = .{};
    defer s.deinit(testing.allocator);
    try split(testing.allocator, &frame, &.{ cand(1, 1), cand(2, 2) }, &s);
    try testing.expectEqual(@as(usize, 0), s.panes.items.len);
    try testing.expectEqual(@as(usize, 2), s.under.items.len);
}

test "what's painted near a pane goes over it: a moving pane runs a frame ahead" {
    const frame = [_]gpu.Instance{
        quad(0, 0, 400, 300),
        pane(10, 100, 200, 30), // the tab pill, sliding up
        quad(20, 70, 100, 14), // the label of the row it's about to reach, 16 points above it
        quad(20, 250, 100, 14), // a row far below
    };
    var s: Split = .{};
    defer s.deinit(testing.allocator);
    try split(testing.allocator, &frame, &.{cand(1, 1)}, &s);
    try testing.expectEqual(@as(usize, 1), s.over.items.len);
    try testing.expectEqual(@as(f32, 70), s.over.items[0].rect[1]);
    try testing.expectEqual(@as(usize, 2), s.under.items.len);
}
