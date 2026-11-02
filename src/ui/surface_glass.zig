//! Native glass on macOS 26+ (`Surface.setNativeGlass`): each pane of
//! glass a frame can show natively (`glass_native.split`) is an
//! NSGlassEffectView, between a Metal layer drawn under it (what it
//! refracts) and the surface's own layer over it (what's on it). They sit
//! in the host's view above the stage (`attachBackdrop`), and none takes
//! the pointer: the surface's view gets it, and holes still pass it to the
//! stage. A pane's view is kept from frame to frame by its node's id, and
//! only what changed is set. No NSGlassEffectContainerView: it lifts its
//! panes out of the views that clip them, and blurs glass on glass into one.
const std = @import("std");
const objc = @import("../objc.zig");
const types = @import("types.zig");
const glass_native = @import("glass_native.zig");

extern "c" fn objc_getClass(name: [*:0]const u8) ?objc.Class;

/// Whether this Mac has AppKit's glass (macOS 26+).
pub fn available() bool {
    return objc_getClass("NSGlassEffectView") != null;
}

pub const NativeGlass = struct {
    gpa: std.mem.Allocator,
    split: glass_native.Split = .{},
    /// Hosts the renderer's layer under the glass.
    under_view: objc.Object,
    /// Each pane's clip view goes in it, in paint order.
    holder: objc.Object,
    views: std.AutoHashMapUnmanaged(u64, View) = .empty,
    /// The panes' ids last frame, in paint order: the views are ordered
    /// again only when it changes.
    order: std.ArrayList(u64) = .empty,
    frame: u64 = 0,
    /// The glass answers presses (`effectIsInteractive`, macOS 27).
    interactive: bool,

    const View = struct {
        /// Clips the glass to what shows of its pane; fades it.
        clip: objc.Object,
        glass: objc.Object,
        seen: u64,
        last: ?glass_native.Pane = null,
    };

    /// Puts the layer under the glass and the glass's holder under
    /// `surface_view`, in its host `host`.
    pub fn init(gpa: std.mem.Allocator, host: objc.Object, surface_view: objc.Object, under_layer: objc.Object) NativeGlass {
        const bounds = objc.msg(objc.CGRect, host, "bounds", .{});
        const under = make(passClass(), bounds);
        objc.msg(void, under, "setAutoresizingMask:", .{fill});
        objc.msg(void, under, "setLayer:", .{under_layer});
        objc.msg(void, under, "setWantsLayer:", .{objc.YES});
        objc.msg(void, under, "setHidden:", .{objc.YES});
        const holder = make(passClass(), bounds);
        objc.msg(void, holder, "setAutoresizingMask:", .{fill});
        // Under the surface's view, the glass nearer it.
        objc.msg(void, host, "addSubview:positioned:relativeTo:", .{ under, below, surface_view });
        objc.msg(void, host, "addSubview:positioned:relativeTo:", .{ holder, below, surface_view });
        return .{
            .gpa = gpa,
            .under_view = under,
            .holder = holder,
            .interactive = objc.msg(objc.BOOL, glassClass(), "instancesRespondToSelector:", .{objc.sel("setEffectIsInteractive:")}) == objc.YES,
        };
    }

    pub fn deinit(ng: *NativeGlass) void {
        var it = ng.views.valueIterator();
        while (it.next()) |v| drop(v.*);
        ng.views.deinit(ng.gpa);
        ng.order.deinit(ng.gpa);
        objc.msg(void, ng.under_view, "removeFromSuperview", .{});
        objc.release(ng.under_view);
        objc.msg(void, ng.holder, "removeFromSuperview", .{});
        objc.release(ng.holder);
        ng.split.deinit(ng.gpa);
    }

    /// Sorts the frame and brings the glass views up to it; whether any
    /// pane is native this frame (then draw `split.under` and `split.over`).
    pub fn update(ng: *NativeGlass, instances: []const @import("gpu.zig").Instance, candidates: []const glass_native.Candidate, size: types.Size) bool {
        glass_native.split(ng.gpa, instances, candidates, &ng.split) catch return false;
        ng.frame += 1;
        const cat = objc.class("CATransaction");
        objc.msg(void, cat, "begin", .{});
        // Panes move with the frame, not after it.
        objc.msg(void, cat, "setDisableActions:", .{objc.YES});
        defer objc.msg(void, cat, "commit", .{});
        const panes = ng.split.panes.items;
        var reorder = panes.len != ng.order.items.len;
        if (!reorder) for (panes, ng.order.items) |p, id| if (p.id != id) {
            reorder = true;
            break;
        };
        if (reorder) {
            ng.order.clearRetainingCapacity();
            for (panes) |p| ng.order.append(ng.gpa, p.id) catch {};
        }
        // Panes in paint order, the later over the earlier.
        for (panes) |p| {
            const gop = ng.views.getOrPut(ng.gpa, p.id) catch continue;
            if (!gop.found_existing) {
                const clip = make(passClass(), .{});
                objc.msg(void, clip, "setWantsLayer:", .{objc.YES});
                // AppKit's own clipping: a layer's masksToBounds alone doesn't cut the glass.
                objc.msg(void, clip, "setClipsToBounds:", .{objc.YES});
                const g = make(glassClass(), .{});
                objc.msg(void, clip, "addSubview:", .{g});
                objc.release(g);
                gop.value_ptr.* = .{ .clip = clip, .glass = g, .seen = 0 };
            }
            const v = gop.value_ptr;
            // Ordered as painted: each goes on top of those before it.
            if (reorder or !gop.found_existing) objc.msg(void, ng.holder, "addSubview:positioned:relativeTo:", .{ v.clip, above, @as(?objc.Object, null) });
            v.seen = ng.frame;
            ng.place(v, p, size);
        }
        // Panes that went.
        var gone: [32]u64 = undefined;
        var n: usize = 0;
        var it = ng.views.iterator();
        while (it.next()) |e| if (e.value_ptr.seen != ng.frame and n < gone.len) {
            gone[n] = e.key_ptr.*;
            n += 1;
        };
        for (gone[0..n]) |id| if (ng.views.fetchRemove(id)) |kv| drop(kv.value);
        const any = ng.split.panes.items.len > 0;
        objc.msg(void, ng.under_view, "setHidden:", .{if (any) objc.NO else objc.YES});
        return any;
    }

    fn place(ng: *NativeGlass, v: *View, p: glass_native.Pane, size: types.Size) void {
        // What shows of it: its clip, within the window.
        const x0 = @max(p.clip[0], 0);
        const y0 = @max(p.clip[1], 0);
        const x1 = @min(p.clip[2], size.w);
        const y1 = @min(p.clip[3], size.h);
        const clip: objc.CGRect = .{ .origin = .{ .x = x0, .y = y0 }, .size = .{ .width = @max(0, x1 - x0), .height = @max(0, y1 - y0) } };
        const at: objc.CGRect = .{ .origin = .{ .x = p.rect[0] - x0, .y = p.rect[1] - y0 }, .size = .{ .width = p.rect[2], .height = p.rect[3] } };
        const last = v.last;
        if (last == null or !std.mem.eql(f32, &last.?.clip, &p.clip) or !std.mem.eql(f32, &last.?.rect, &p.rect)) {
            objc.msg(void, v.clip, "setFrame:", .{clip});
            objc.msg(void, v.glass, "setFrame:", .{at});
        }
        if (last == null or last.?.radius != p.radius) objc.msg(void, v.glass, "setCornerRadius:", .{@as(f64, p.radius)});
        if (last == null or last.?.style != p.style) objc.msg(void, v.glass, "setStyle:", .{@as(objc.NSInteger, if (p.style == .clear) 1 else 0)});
        if (last == null or !std.meta.eql(last.?.tint, p.tint)) {
            const tint: ?objc.Object = if (p.tint.a > 0) objc.msg(objc.Object, objc.class("NSColor"), "colorWithSRGBRed:green:blue:alpha:", .{ @as(f64, p.tint.r), @as(f64, p.tint.g), @as(f64, p.tint.b), @as(f64, p.tint.a) }) else null;
            objc.msg(void, v.glass, "setTintColor:", .{tint});
        }
        if (last == null or last.?.opacity != p.opacity) objc.msg(void, v.clip, "setAlphaValue:", .{@as(f64, p.opacity)});
        if (ng.interactive and (last == null or last.?.interactive != p.interactive)) objc.msg(void, v.glass, "setEffectIsInteractive:", .{if (p.interactive) objc.YES else objc.NO});
        v.last = p;
    }

    fn drop(v: View) void {
        objc.msg(void, v.clip, "removeFromSuperview", .{});
        objc.release(v.clip);
    }
};

/// Width and height follow the host's.
const fill: objc.NSUInteger = 2 | 16;

/// NSWindowAbove and NSWindowBelow.
const above: objc.NSInteger = 1;
const below: objc.NSInteger = -1;

fn make(cls: objc.Class, frame: objc.CGRect) objc.Object {
    return objc.msg(objc.Object, objc.msg(objc.Object, cls, "alloc", .{}), "initWithFrame:", .{frame});
}

/// A flipped view the pointer goes through.
fn passClass() objc.Class {
    return objc.defineClass(.{
        .name = "NanoUIGlassPassView",
        .superclass = "NSView",
        .methods = &.{
            .{ .name = "isFlipped", .imp = &yes, .types = "c@:" },
            .{ .name = "hitTest:", .imp = &passes, .types = "@@:{CGPoint=dd}" },
        },
    });
}

fn glassClass() objc.Class {
    return objc.defineClass(.{
        .name = "NanoUIGlassView",
        .superclass = "NSGlassEffectView",
        .methods = &.{.{ .name = "hitTest:", .imp = &passes, .types = "@@:{CGPoint=dd}" }},
    });
}

fn yes(_: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    return objc.YES;
}

fn passes(_: objc.Object, _: objc.SEL, _: objc.CGPoint) callconv(.c) ?objc.Object {
    return null;
}
