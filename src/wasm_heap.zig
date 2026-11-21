//! The allocator of the wasm module with threads.
//!
//! The wasm allocator of the Zig standard library has no support for
//! threads. This allocator has the same design, with locks:
//!
//! 1. A small block has a size that is a power of two, up to 32 KiB. Each
//!    size has a list of free blocks. A new block comes from a 64 KiB page
//!    of its size class.
//! 2. A large block is a power of two of 64 KiB pages. Each size has a list
//!    of free blocks. A new block comes from `memory.grow`.
//! 3. Each list has its own lock (a spin lock: the work under the lock is a
//!    few instructions).
//!
//! The hot paths of a slice use the arenas of scratch.zig, so the locks
//! have little load.
//!
//! One rule of the host needs care. Each thread has its own instance of
//! the module, and V8 keeps the size of the memory in each instance. When
//! one thread grows the memory, the other instances get the new size only
//! at their next interrupt check. Before that, a `memory.fill` or
//! `memory.copy` of such an instance into the new pages traps ("memory
//! access out of bounds"), the thread ends, and the slice waits for it
//! with no end. A `memory.grow` of 0 pages makes the instance read the
//! size. So a thread does that before it uses memory past the size that
//! it has seen (`see`), and before each task of the pool (`sync`).
//!
//! Reference (see docs/references/): the WasmAllocator of the Zig standard
//! library (MIT).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const math = std.math;

const page_size = 64 * 1024;
const min_class = math.log2(math.ceilPowerOfTwoAssert(usize, 1 + @sizeOf(usize)));
const small_count = math.log2(page_size) - min_class;
const big_count = math.log2(math.maxInt(usize) / page_size);

const Lock = struct {
    held: std.atomic.Value(bool) = .init(false),

    fn lock(l: *Lock) void {
        while (l.held.swap(true, .acquire)) {
            while (l.held.load(.monotonic)) std.atomic.spinLoopHint();
        }
    }

    fn unlock(l: *Lock) void {
        l.held.store(false, .release);
    }
};

const Small = struct {
    lock: Lock = .{},
    /// The next new block of the current page, or 0 at a page end.
    next: usize = 0,
    free: usize = 0,
};

const Big = struct {
    lock: Lock = .{},
    free: usize = 0,
};

var smalls: [small_count]Small = @splat(.{});
var bigs: [big_count]Big = @splat(.{});

pub const allocator: Allocator = .{ .ptr = undefined, .vtable = &vtable };

const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

fn bigPages(len: usize) usize {
    return (len + (page_size + @sizeOf(usize) - 1)) / page_size;
}

/// The end of the memory that the instance of this thread has seen.
threadlocal var seen_end: usize = 0;

/// Makes the instance of this thread read the size of the memory (see the
/// file header).
pub fn sync() void {
    _ = @wasmMemoryGrow(0, 0);
    seen_end = @wasmMemorySize(0) * page_size;
}

/// Call before the first use of the bytes from `addr` to `addr + len`.
inline fn see(addr: usize, len: usize) void {
    if (addr + len > seen_end) sync();
}

fn alloc(_: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
    const actual = @max(len +| @sizeOf(usize), alignment.toByteUnits());
    const slot = math.ceilPowerOfTwo(usize, actual) catch return null;
    const class = math.log2(slot) - min_class;
    if (class >= small_count) return @ptrFromInt(allocBig(bigPages(actual)));
    const s = &smalls[class];
    s.lock.lock();
    if (s.free != 0) {
        const addr = s.free;
        see(addr, slot);
        const node: *usize = @ptrFromInt(addr + (slot - @sizeOf(usize)));
        s.free = node.*;
        s.lock.unlock();
        return @ptrFromInt(addr);
    }
    if (s.next % page_size != 0) {
        const addr = s.next;
        s.next = addr + slot;
        s.lock.unlock();
        see(addr, slot);
        return @ptrFromInt(addr);
    }
    s.lock.unlock();
    // A new page. Another thread can take a page at the same time: then
    // the rest of the older page stays unused.
    const addr = allocBig(1);
    if (addr == 0) return null;
    s.lock.lock();
    if (s.next % page_size != 0) {
        // Give the rest of the older page to the free list.
        var a = s.next;
        while (a % page_size != 0) : (a += slot) {
            const node: *usize = @ptrFromInt(a + (slot - @sizeOf(usize)));
            node.* = s.free;
            s.free = a;
        }
    }
    s.next = addr + slot;
    s.lock.unlock();
    return @ptrFromInt(addr);
}

fn resize(_: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, _: usize) bool {
    const a = alignment.toByteUnits();
    const old_actual = @max(buf.len + @sizeOf(usize), a);
    const new_actual = @max(new_len +| @sizeOf(usize), a);
    const old_slot = math.ceilPowerOfTwoAssert(usize, old_actual);
    if (math.log2(old_slot) - min_class < small_count) {
        const new_slot = math.ceilPowerOfTwo(usize, new_actual) catch return false;
        return old_slot == new_slot;
    }
    const old_pages = math.ceilPowerOfTwoAssert(usize, bigPages(old_actual));
    const new_pages = math.ceilPowerOfTwo(usize, bigPages(new_actual)) catch return false;
    return old_pages == new_pages;
}

fn remap(ctx: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
    return if (resize(ctx, buf, alignment, new_len, ra)) buf.ptr else null;
}

fn free(_: *anyopaque, buf: []u8, alignment: Alignment, _: usize) void {
    const actual = @max(buf.len + @sizeOf(usize), alignment.toByteUnits());
    const slot = math.ceilPowerOfTwoAssert(usize, actual);
    const class = math.log2(slot) - min_class;
    const addr = @intFromPtr(buf.ptr);
    if (class < small_count) {
        const s = &smalls[class];
        const node: *usize = @ptrFromInt(addr + (slot - @sizeOf(usize)));
        s.lock.lock();
        node.* = s.free;
        s.free = addr;
        s.lock.unlock();
        return;
    }
    const pages = math.ceilPowerOfTwoAssert(usize, bigPages(actual));
    const b = &bigs[math.log2(pages)];
    const node: *usize = @ptrFromInt(addr + (pages * page_size - @sizeOf(usize)));
    b.lock.lock();
    node.* = b.free;
    b.free = addr;
    b.lock.unlock();
}

fn allocBig(n: usize) usize {
    const pages = math.ceilPowerOfTwoAssert(usize, n);
    const b = &bigs[math.log2(pages)];
    b.lock.lock();
    if (b.free != 0) {
        const addr = b.free;
        see(addr, pages * page_size);
        const node: *usize = @ptrFromInt(addr + (pages * page_size - @sizeOf(usize)));
        b.free = node.*;
        b.lock.unlock();
        return addr;
    }
    b.lock.unlock();
    // memory.grow is atomic on a shared memory.
    const index = @wasmMemoryGrow(0, pages);
    if (index == -1) return 0;
    seen_end = @wasmMemorySize(0) * page_size;
    return @as(usize, @intCast(index)) * page_size;
}
