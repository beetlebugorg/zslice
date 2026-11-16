//! A pool of arenas for temporary memory.
//!
//! A polygon boolean or offset needs a few megabytes of work memory, and a
//! slice makes thousands of them. With a new arena for each call, each call
//! gets new pages from the operating system, and each new page costs a page
//! fault. The pool keeps the arenas and their memory between calls:
//!
//! 1. `get` takes a free arena from the pool. The memory of the arena is
//!    from the calls before, so its pages are already mapped.
//! 2. `Scratch.release` empties the arena (it keeps up to 16 MB of its
//!    memory) and puts it back.
//! 3. `trim` frees the memory of all arenas that are in the pool. The engine
//!    calls it at the end of a slice, so the memory goes back to the
//!    operating system when no slice runs.
//!
//! Each thread takes its own arena, so the arenas need no lock. A call that
//! needs work memory inside another call (an offset calls a union) takes a
//! second arena. If all slots are busy, `get` makes a new arena that
//! `release` frees.
//!
//! Reference (see REFERENCES.md): arena allocators kept in a pool.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Slot = struct {
    busy: std.atomic.Value(bool) = .init(false),
    arena: ArenaAllocator = .init(std.heap.page_allocator),
};

/// An arena keeps at most this much memory between calls. Most calls need
/// less. A call on a very large outline needs more, and gives the rest
/// back, so that each thread does not keep the memory of its largest call.
const retain_limit = 16 << 20;

/// More slots than threads times the depth of nested calls.
const slot_count = 128;
var slots: [slot_count]Slot = @splat(.{});

pub const Scratch = struct {
    slot: ?*Slot,
    own: ArenaAllocator,

    pub fn allocator(self: *Scratch) Allocator {
        return if (self.slot) |s| s.arena.allocator() else self.own.allocator();
    }

    /// Empties the arena and gives it back to the pool. Memory from the
    /// arena is not valid after this call.
    pub fn release(self: *Scratch) void {
        if (self.slot) |s| {
            _ = s.arena.reset(.{ .retain_with_limit = retain_limit });
            s.busy.store(false, .release);
        } else {
            self.own.deinit();
        }
        self.* = undefined;
    }
};

/// Takes a free arena from the pool. `fallback` is the backing allocator of
/// a new arena when all slots are busy.
pub fn get(fallback: Allocator) Scratch {
    for (&slots) |*s| {
        if (s.busy.load(.monotonic)) continue;
        if (s.busy.cmpxchgStrong(false, true, .acquire, .monotonic) == null) {
            return .{ .slot = s, .own = undefined };
        }
    }
    return .{ .slot = null, .own = .init(fallback) };
}

/// Frees the memory of the arenas that are in the pool. Arenas that a
/// thread uses now keep their memory.
pub fn trim() void {
    for (&slots) |*s| {
        if (s.busy.cmpxchgStrong(false, true, .acquire, .monotonic) != null) continue;
        _ = s.arena.reset(.free_all);
        s.busy.store(false, .release);
    }
}

test "an arena goes back to the pool and keeps its memory" {
    var a = get(std.testing.allocator);
    const slot = a.slot.?;
    _ = try a.allocator().alloc(u8, 100_000);
    a.release();
    try std.testing.expect(slot.arena.queryCapacity() >= 100_000);
    // The next get takes the same slot (the first free slot).
    var b = get(std.testing.allocator);
    try std.testing.expectEqual(slot, b.slot.?);
    // A second get at the same time takes another slot.
    var c = get(std.testing.allocator);
    try std.testing.expect(c.slot.? != slot);
    c.release();
    b.release();
    trim();
    try std.testing.expectEqual(@as(usize, 0), slot.arena.queryCapacity());
}
