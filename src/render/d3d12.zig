//! The Direct3D 12 backend of the renderer.
//!
//! It draws the same frame as vk.zig: the toolpath beads, the bed grid, the
//! bed model, the signs, the decals, and the mesh of the Paint tool. The
//! scene logic is in view.zig. This file only talks to the GPU.
//!
//! Choices, and why:
//!
//! - No link-time dependency on Direct3D. c_d3d12.zig loads d3d12.dll,
//!   dxgi.dll, and d3dcompiler_47.dll at run time. A program that never opens
//!   a view does not load them.
//! - A composition swapchain. The shell attaches it to a XAML SwapChainPanel
//!   with ISwapChainPanelNative::SetSwapChain (see zs_view_swapchain).
//! - HLSL compiled at run time (shaders/d3d12). Each file is the form of the
//!   GLSL shader of the same name.
//! - The view makes its matrices for a clip space with y down (Vulkan). The
//!   vertex shaders negate y, so a triangle has the same winding on the
//!   screen as in Vulkan.
//! - Root constants for the push data of a draw (28 values). One more root
//!   constant has the first instance of a draw, because SV_InstanceID starts
//!   at 0 for each draw, and the highlight compares the instance index.
//! - Upload-heap buffers, mapped for their whole life: the CPU writes them
//!   directly, as the host-visible buffers of the Vulkan backend.
//! - One frame in flight. The view draws on demand.
//! - WARP (the software rasterizer of Windows) when no GPU takes a device,
//!   or when ZSLICE_WARP is set.
//! - A print view offscreen draws its finished layers each frame. The Vulkan
//!   backend caches them for the small CPU of a printer screen.
//!
//! The structure follows the Direct3D 12 backend of charttable (same author,
//! MIT license, see docs/references/libraries.md).

const std = @import("std");
const d3d = @import("c_d3d12.zig");
const frame_mod = @import("frame.zig");
const BedVertex = @import("../bed.zig").Vertex;
const BedImage = @import("../bed.zig").Image;

pub const Error = error{
    /// The machine has no Direct3D 12 runtime.
    NoD3D12,
    D3D12Failed,
    OutOfMemory,
    /// The GPU is still on the frame before: the shell draws again a moment
    /// later.
    FrameBusy,
};

/// A composition swapchain for the shell to attach (`panel`), or an image
/// that the renderer owns (`offscreen`): the host reads each frame with
/// `read`.
pub const Surface = union(enum) {
    panel,
    /// `bgra`: the image has the bytes in B, G, R, A order; else R, G, B, A.
    offscreen: struct { bgra: bool = false },
};

pub const Instance = frame_mod.Instance;
pub const max_extras = frame_mod.max_extras;
pub const Push = frame_mod.Push;
pub const Draw = frame_mod.Draw;
pub const PlateFrame = frame_mod.PlateFrame;

const hlsl = struct {
    const box_vs = @embedFile("shaders/d3d12/box.vs.hlsl");
    const box_ps = @embedFile("shaders/d3d12/box.ps.hlsl");
    const grid_vs = @embedFile("shaders/d3d12/grid.vs.hlsl");
    const grid_ps = @embedFile("shaders/d3d12/grid.ps.hlsl");
    const bed_vs = @embedFile("shaders/d3d12/bed.vs.hlsl");
    const bed_ps = @embedFile("shaders/d3d12/bed.ps.hlsl");
    const sign_ps = @embedFile("shaders/d3d12/sign.ps.hlsl");
    const decal_ps = @embedFile("shaders/d3d12/decal.ps.hlsl");
    const paint_vs = @embedFile("shaders/d3d12/paint.vs.hlsl");
    const paint_ps = @embedFile("shaders/d3d12/paint.ps.hlsl");
};

const depth_format = d3d.DXGI_FORMAT_D32_FLOAT;
const push_values = @sizeOf(Push) / 4;

/// The root parameters.
const root_push = 0;
const root_first_instance = 1;
const root_texture = 2;

/// The swapchain buffers, and the heap of render target views: the
/// swapchain buffers, then the multisampled image, then the offscreen image.
const sc_buffers = 3;
const rtv_msaa = sc_buffers;
const rtv_target = sc_buffers + 1;
const rtv_count = sc_buffers + 2;

/// The shader-visible descriptors: the texture of the bed, and the image of
/// the signs.
const srv_bed = 0;
const srv_sign = 1;
const srv_count = 2;

const max_plate_slots = 64;
const max_mesh_verts = 256;
const max_mesh_index = 1024;

const Buffer = struct {
    res: ?*d3d.ID3D12Resource = null,
    map: ?[*]u8 = null,
    gpu: u64 = 0,
    size: usize = 0,
};

/// The bead buffer of another plate of the row (see Frame.plates), by its
/// slot: uploaded again when the generation of the plate changes.
const PlateSlot = struct {
    buf: Buffer = .{},
    gen: u32 = 0,
    used: bool = false,
};

extern "kernel32" fn GetEnvironmentVariableA(name: [*:0]const u8, buf: ?[*]u8, size: u32) callconv(.winapi) u32;
extern "kernel32" fn GetStdHandle(id: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn WriteFile(file: ?*anyopaque, data: [*]const u8, size: u32, written: ?*u32, overlapped: ?*anyopaque) callconv(.winapi) c_int;

/// STD_ERROR_HANDLE.
const std_error: u32 = @bitCast(@as(i32, -12));

/// Writes one line to stderr. std.log does not compile for ARM64 Windows in
/// Zig 0.16: it reaches the stack trace code of std.debug, which has a
/// pointer cast with the wrong alignment there.
fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "d3d12: " ++ fmt ++ "\n", args) catch return;
    _ = WriteFile(GetStdHandle(std_error), line.ptr, @intCast(line.len), null, null);
}

fn check(hr: d3d.HRESULT, comptime what: []const u8) Error!void {
    if (d3d.ok(hr)) return;
    log(what ++ " failed (0x{x:0>8})", .{@as(u32, @bitCast(hr))});
    return error.D3D12Failed;
}

fn element(index: u32, format: u32, slot: u32, offset: usize, instanced: bool) d3d.D3D12_INPUT_ELEMENT_DESC {
    return .{
        .SemanticName = "TEXCOORD",
        .SemanticIndex = index,
        .Format = format,
        .InputSlot = slot,
        .AlignedByteOffset = @intCast(offset),
        .InputSlotClass = if (instanced) d3d.D3D12_INPUT_CLASSIFICATION_PER_INSTANCE_DATA else d3d.D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA,
        .InstanceDataStepRate = if (instanced) 1 else 0,
    };
}

const box_elements = [_]d3d.D3D12_INPUT_ELEMENT_DESC{
    element(0, d3d.DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 0, false),
    element(2, d3d.DXGI_FORMAT_R32G32B32A32_FLOAT, 1, @offsetOf(Instance, "ax"), true),
    element(3, d3d.DXGI_FORMAT_R32G32B32_FLOAT, 1, @offsetOf(Instance, "z"), true),
    element(4, d3d.DXGI_FORMAT_R8G8B8A8_UNORM, 1, @offsetOf(Instance, "rgba"), true),
};
const grid_elements = [_]d3d.D3D12_INPUT_ELEMENT_DESC{
    element(0, d3d.DXGI_FORMAT_R32G32B32_FLOAT, 0, 0, false),
};
const bed_elements = [_]d3d.D3D12_INPUT_ELEMENT_DESC{
    element(0, d3d.DXGI_FORMAT_R32G32B32_FLOAT, 0, @offsetOf(BedVertex, "pos"), false),
    element(1, d3d.DXGI_FORMAT_R32G32B32_FLOAT, 0, @offsetOf(BedVertex, "normal"), false),
    element(2, d3d.DXGI_FORMAT_R32G32_FLOAT, 0, @offsetOf(BedVertex, "uv"), false),
};
/// The uv of a paint vertex holds two integers.
const paint_elements = [_]d3d.D3D12_INPUT_ELEMENT_DESC{
    bed_elements[0],
    bed_elements[1],
    element(2, d3d.DXGI_FORMAT_R32G32_UINT, 0, @offsetOf(BedVertex, "uv"), false),
};

/// The state of one pipeline.
const PipelineDesc = struct {
    elements: []const d3d.D3D12_INPUT_ELEMENT_DESC,
    lines: bool = false,
    blend: bool = false,
    depth_write: bool = true,
    cull: bool = false,
    bias: i32 = 0,
    bias_slope: f32 = 0,
};

fn transition(cmd: *d3d.ID3D12GraphicsCommandList, res: *d3d.ID3D12Resource, before: u32, after: u32) void {
    const bars = [_]d3d.D3D12_RESOURCE_BARRIER{.{ .u = .{ .Transition = .{
        .pResource = res,
        .Subresource = d3d.D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
        .StateBefore = before,
        .StateAfter = after,
    } } }};
    cmd.ResourceBarrier(1, &bars);
}

fn vertexView(b: *const Buffer, stride: u32) d3d.D3D12_VERTEX_BUFFER_VIEW {
    return .{
        .BufferLocation = b.gpu,
        .SizeInBytes = @intCast(@min(b.size, std.math.maxInt(u32))),
        .StrideInBytes = stride,
    };
}

pub const Renderer = struct {
    api: d3d.Api,
    factory: *d3d.IDXGIFactory4,
    device: *d3d.ID3D12Device,
    queue: *d3d.ID3D12CommandQueue,
    format: u32,
    samples: u32 = 1,

    rtv_heap: ?*d3d.ID3D12DescriptorHeap = null,
    rtv_size: u32 = 0,
    dsv_heap: ?*d3d.ID3D12DescriptorHeap = null,
    srv_heap: ?*d3d.ID3D12DescriptorHeap = null,
    srv_size: u32 = 0,
    root: ?*d3d.ID3D12RootSignature = null,

    box_pipeline: ?*d3d.ID3D12PipelineState = null,
    /// The beads out of a focus: blended, with no depth write.
    ghost_pipeline: ?*d3d.ID3D12PipelineState = null,
    grid_pipeline: ?*d3d.ID3D12PipelineState = null,
    /// The bed model: blended, with a depth bias, so the grid lines at
    /// z = 0 stay in front of the flat bed.
    bed_pipeline: ?*d3d.ID3D12PipelineState = null,
    sign_pipeline: ?*d3d.ID3D12PipelineState = null,
    decal_pipeline: ?*d3d.ID3D12PipelineState = null,
    paint_pipeline: ?*d3d.ID3D12PipelineState = null,

    cmd_alloc: ?*d3d.ID3D12CommandAllocator = null,
    cmd: ?*d3d.ID3D12GraphicsCommandList = null,
    fence: ?*d3d.ID3D12Fence = null,
    fence_event: ?d3d.HANDLE = null,
    fence_value: u64 = 0,
    /// The fence value after the last frame sent to the GPU.
    frame_value: u64 = 0,

    swapchain: ?*d3d.IDXGISwapChain3 = null,
    /// Signaled when the swapchain can take one more frame. With it, a
    /// present does not block the UI thread.
    latency: ?d3d.HANDLE = null,
    /// The wait on `latency` succeeded, and no present used it yet.
    latency_held: bool = false,
    back: [sc_buffers]?*d3d.ID3D12Resource = @splat(null),
    back_count: u32 = 0,
    depth: ?*d3d.ID3D12Resource = null,
    msaa: ?*d3d.ID3D12Resource = null,
    width: u32 = 0,
    height: u32 = 0,
    want_width: u32,
    want_height: u32,
    stale: bool = true,

    /// The offscreen target (Surface.offscreen): the color image, and a
    /// host buffer that each frame copies into.
    offscreen: bool = false,
    target: ?*d3d.ID3D12Resource = null,
    readback: Buffer = .{},
    readback_pitch: u32 = 0,
    /// A frame was drawn and its copy is not yet read.
    drawn: bool = false,

    box_mesh: Buffer = .{},
    box_index: Buffer = .{},
    box_index_count: u32 = 0,
    /// A copy of the bead meshes: the full mesh, then the levels of detail
    /// (see setLodMesh). Level k is indices lod_first[k - 1] ..
    /// + lod_count[k - 1].
    mesh_verts: [max_mesh_verts][4]f32 = undefined,
    mesh_vert_count: usize = 0,
    mesh_index: [max_mesh_index]u16 = undefined,
    mesh_index_count: usize = 0,
    lod_first: [2]u32 = .{ 0, 0 },
    lod_count: [2]u32 = .{ 0, 0 },

    instance_count: u32 = 0,
    instances: Buffer = .{},
    /// The instance buffer of the next scene (see `beginInstances`): a
    /// thread copies the beads into it while the frames draw the old scene.
    /// `next_until` is the last frame that can read it, and `retired` a
    /// buffer that frames can still read until frame `retired_until`.
    next_instances: Buffer = .{},
    next_until: u64 = 0,
    retired: Buffer = .{},
    retired_until: u64 = 0,
    upload: ?*Upload = null,
    /// The frames sent to the GPU, and the frames that the GPU is done with.
    frames_sent: u64 = 0,
    frames_done: u64 = 0,

    grid: Buffer = .{},
    plate_slots: [max_plate_slots]PlateSlot = @as([max_plate_slots]PlateSlot, @splat(.{})),
    plate_grid: Buffer = .{},
    plate_grid_gen: u32 = 0,

    bed: Buffer = .{},
    bed_count: u32 = 0,
    bed_tex: ?*d3d.ID3D12Resource = null,
    sign_tex: ?*d3d.ID3D12Resource = null,
    sign_buf: Buffer = .{},
    /// The buffer of the decals: the fill of generation `decal_gen`
    /// (decal_fill vertices), then the outlines of the frame.
    decal_buf: Buffer = .{},
    decal_gen: u32 = 0,
    decal_fill: usize = 0,
    /// The mesh of the Paint tool, of generation `paint_gen`.
    paint_buf: Buffer = .{},
    paint_gen: u32 = 0,
    paint_len: usize = 0,

    pub const Frame = frame_mod.Frame;

    pub fn init(surface: Surface, width: u32, height: u32) Error!*Renderer {
        const api = d3d.Api.load() catch return error.NoD3D12;
        var factory_raw: ?*anyopaque = null;
        try check(api.CreateDXGIFactory2(0, &d3d.IID_IDXGIFactory4, &factory_raw), "CreateDXGIFactory2");
        const factory: *d3d.IDXGIFactory4 = @ptrCast(@alignCast(factory_raw.?));
        errdefer _ = factory.Release();
        const device = try pickDevice(api, factory);
        errdefer _ = device.Release();
        var queue_desc = d3d.D3D12_COMMAND_QUEUE_DESC{};
        var queue: ?*d3d.ID3D12CommandQueue = null;
        try check(device.CreateCommandQueue(&queue_desc, &queue), "CreateCommandQueue");
        errdefer _ = queue.?.Release();

        const r = std.heap.c_allocator.create(Renderer) catch return error.OutOfMemory;
        r.* = .{
            .api = api,
            .factory = factory,
            .device = device,
            .queue = queue.?,
            .format = switch (surface) {
                .panel => d3d.DXGI_FORMAT_R8G8B8A8_UNORM,
                .offscreen => |o| if (o.bgra) d3d.DXGI_FORMAT_B8G8R8A8_UNORM else d3d.DXGI_FORMAT_R8G8B8A8_UNORM,
            },
            .want_width = @max(width, 1),
            .want_height = @max(height, 1),
            .offscreen = surface == .offscreen,
        };
        r.setup() catch |e| {
            r.release();
            std.heap.c_allocator.destroy(r);
            return e;
        };
        return r;
    }

    /// The hardware adapter with the most video memory, else WARP.
    fn pickDevice(api: d3d.Api, factory: *d3d.IDXGIFactory4) Error!*d3d.ID3D12Device {
        var best: ?*d3d.ID3D12Device = null;
        var best_memory: usize = 0;
        var best_name: [128]u16 = @splat(0);
        if (GetEnvironmentVariableA("ZSLICE_WARP", null, 0) == 0) {
            var i: u32 = 0;
            while (i < 16) : (i += 1) {
                var adapter: ?*d3d.IDXGIAdapter1 = null;
                if (!d3d.ok(factory.EnumAdapters1(i, &adapter)) or adapter == null) break;
                defer _ = adapter.?.Release();
                var desc: d3d.DXGI_ADAPTER_DESC1 = undefined;
                if (!d3d.ok(adapter.?.GetDesc1(&desc))) continue;
                if (desc.Flags & d3d.DXGI_ADAPTER_FLAG_SOFTWARE != 0) continue;
                var raw: ?*anyopaque = null;
                if (!d3d.ok(api.D3D12CreateDevice(adapter.?, d3d.D3D_FEATURE_LEVEL_11_0, &d3d.IID_ID3D12Device, &raw))) continue;
                const device: *d3d.ID3D12Device = @ptrCast(@alignCast(raw.?));
                if (best == null or desc.DedicatedVideoMemory > best_memory) {
                    if (best) |b| _ = b.Release();
                    best = device;
                    best_memory = desc.DedicatedVideoMemory;
                    best_name = desc.Description;
                } else _ = device.Release();
            }
        }
        if (best) |b| {
            log("GPU: {f}", .{std.unicode.fmtUtf16Le(std.mem.sliceTo(&best_name, 0))});
            return b;
        }
        log("GPU: WARP", .{});
        var warp: ?*anyopaque = null;
        try check(factory.v.EnumWarpAdapter(factory, &d3d.IID_IDXGIAdapter, &warp), "EnumWarpAdapter");
        defer _ = @as(*d3d.IUnknown, @ptrCast(@alignCast(warp.?))).Release();
        var raw: ?*anyopaque = null;
        try check(api.D3D12CreateDevice(warp.?, d3d.D3D_FEATURE_LEVEL_11_0, &d3d.IID_ID3D12Device, &raw), "D3D12CreateDevice on WARP");
        return @ptrCast(@alignCast(raw.?));
    }

    /// The parts that do not depend on the size of the drawing.
    fn setup(r: *Renderer) Error!void {
        const device = r.device;
        // 4x multisampling if the device has it for the color format.
        var quality = d3d.D3D12_FEATURE_DATA_MULTISAMPLE_QUALITY_LEVELS{ .Format = r.format, .SampleCount = 4 };
        if (d3d.ok(device.CheckFeatureSupport(d3d.D3D12_FEATURE_MULTISAMPLE_QUALITY_LEVELS, &quality, @sizeOf(@TypeOf(quality)))) and quality.NumQualityLevels > 0) r.samples = 4;

        r.rtv_heap = try makeHeap(device, d3d.D3D12_DESCRIPTOR_HEAP_TYPE_RTV, rtv_count, false);
        r.rtv_size = device.GetDescriptorHandleIncrementSize(d3d.D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
        r.dsv_heap = try makeHeap(device, d3d.D3D12_DESCRIPTOR_HEAP_TYPE_DSV, 1, false);
        r.srv_heap = try makeHeap(device, d3d.D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, srv_count, true);
        r.srv_size = device.GetDescriptorHandleIncrementSize(d3d.D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);

        try check(device.CreateCommandAllocator(d3d.D3D12_COMMAND_LIST_TYPE_DIRECT, &r.cmd_alloc), "CreateCommandAllocator");
        try check(device.CreateCommandList(0, d3d.D3D12_COMMAND_LIST_TYPE_DIRECT, r.cmd_alloc.?, null, &r.cmd), "CreateCommandList");
        // A command list starts open: the first Reset needs it closed.
        try check(r.cmd.?.Close(), "Close");
        try check(device.CreateFence(0, &r.fence), "CreateFence");
        r.fence_event = d3d.CreateEventA(null, d3d.FALSE, d3d.FALSE, null) orelse return error.D3D12Failed;

        try r.makeRootSignature();
        try r.makePipelines();
        if (!r.offscreen) try r.makeSwapchain();
    }

    fn makeHeap(device: *d3d.ID3D12Device, kind: u32, n: u32, shader_visible: bool) Error!*d3d.ID3D12DescriptorHeap {
        var desc = d3d.D3D12_DESCRIPTOR_HEAP_DESC{
            .Type = kind,
            .NumDescriptors = n,
            .Flags = if (shader_visible) d3d.D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE else d3d.D3D12_DESCRIPTOR_HEAP_FLAG_NONE,
        };
        var out: ?*d3d.ID3D12DescriptorHeap = null;
        try check(device.CreateDescriptorHeap(&desc, &out), "CreateDescriptorHeap");
        return out.?;
    }

    /// Releases each object that exists. The GPU is idle.
    fn release(r: *Renderer) void {
        r.releaseTargets();
        if (r.latency) |h| _ = d3d.CloseHandle(h);
        if (r.swapchain) |s| _ = s.Release();
        if (r.target) |t| _ = t.Release();
        r.freeBuffer(&r.readback);
        for ([_]*Buffer{ &r.box_mesh, &r.box_index, &r.instances, &r.next_instances, &r.retired, &r.grid, &r.bed, &r.plate_grid, &r.sign_buf, &r.decal_buf, &r.paint_buf }) |b| r.freeBuffer(b);
        for (&r.plate_slots) |*sl| r.freeBuffer(&sl.buf);
        if (r.bed_tex) |t| _ = t.Release();
        if (r.sign_tex) |t| _ = t.Release();
        for ([_]?*d3d.ID3D12PipelineState{ r.box_pipeline, r.ghost_pipeline, r.grid_pipeline, r.bed_pipeline, r.sign_pipeline, r.decal_pipeline, r.paint_pipeline }) |p| {
            if (p) |x| _ = x.Release();
        }
        if (r.root) |x| _ = x.Release();
        if (r.cmd) |x| _ = x.Release();
        if (r.cmd_alloc) |x| _ = x.Release();
        if (r.fence) |x| _ = x.Release();
        if (r.fence_event) |x| _ = d3d.CloseHandle(x);
        for ([_]?*d3d.ID3D12DescriptorHeap{ r.rtv_heap, r.dsv_heap, r.srv_heap }) |h| {
            if (h) |x| _ = x.Release();
        }
        _ = r.queue.Release();
        _ = r.device.Release();
        _ = r.factory.Release();
    }

    pub fn deinit(r: *Renderer) void {
        r.cancelInstances();
        r.waitIdle();
        r.release();
        std.heap.c_allocator.destroy(r);
    }

    /// The size of the drawing in pixels. The targets are made again before
    /// the next frame.
    pub fn resize(r: *Renderer, width: u32, height: u32) void {
        if (width == r.want_width and height == r.want_height) return;
        r.want_width = @max(width, 1);
        r.want_height = @max(height, 1);
        r.stale = true;
    }

    /// The swapchain for the shell to attach to its panel. Null for an
    /// offscreen renderer. The renderer keeps its reference.
    pub fn swapchainPtr(r: *const Renderer) ?*anyopaque {
        return @ptrCast(r.swapchain);
    }

    // ---- the fence ----

    /// True when the GPU is done with the last frame, within `ms`.
    fn waitFrame(r: *Renderer, ms: u32) bool {
        const fence = r.fence.?;
        if (fence.GetCompletedValue() >= r.frame_value) return true;
        if (!d3d.ok(fence.SetEventOnCompletion(r.frame_value, r.fence_event.?))) return false;
        _ = d3d.WaitForSingleObject(r.fence_event.?, ms);
        return fence.GetCompletedValue() >= r.frame_value;
    }

    /// Waits until the GPU has done all the work sent to it.
    fn waitIdle(r: *Renderer) void {
        const fence = r.fence orelse return;
        r.fence_value += 1;
        if (!d3d.ok(r.queue.Signal(fence, r.fence_value))) return;
        r.frame_value = r.fence_value;
        while (fence.GetCompletedValue() < r.frame_value) {
            if (!d3d.ok(fence.SetEventOnCompletion(r.frame_value, r.fence_event.?))) return;
            _ = d3d.WaitForSingleObject(r.fence_event.?, d3d.INFINITE);
        }
        r.frames_done = r.frames_sent;
    }

    fn beginList(r: *Renderer) Error!*d3d.ID3D12GraphicsCommandList {
        try check(r.cmd_alloc.?.Reset(), "reset the command allocator");
        try check(r.cmd.?.Reset(r.cmd_alloc.?, null), "reset the command list");
        return r.cmd.?;
    }

    fn execute(r: *Renderer, cmd: *d3d.ID3D12GraphicsCommandList) Error!void {
        try check(cmd.Close(), "close the command list");
        const lists = [_]*d3d.ID3D12GraphicsCommandList{cmd};
        r.queue.ExecuteCommandLists(1, &lists);
    }

    fn signalFrame(r: *Renderer) Error!void {
        r.fence_value += 1;
        try check(r.queue.Signal(r.fence.?, r.fence_value), "signal the fence");
        r.frame_value = r.fence_value;
        r.frames_sent += 1;
    }

    // ---- pipelines ----

    fn makeRootSignature(r: *Renderer) Error!void {
        const range = [_]d3d.D3D12_DESCRIPTOR_RANGE{.{
            .RangeType = d3d.D3D12_DESCRIPTOR_RANGE_TYPE_SRV,
            .NumDescriptors = 1,
            .BaseShaderRegister = 0,
        }};
        const params = [_]d3d.D3D12_ROOT_PARAMETER{
            .{
                .ParameterType = d3d.D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS,
                .u = .{ .Constants = .{ .ShaderRegister = 0, .RegisterSpace = 0, .Num32BitValues = push_values } },
                .ShaderVisibility = d3d.D3D12_SHADER_VISIBILITY_ALL,
            },
            .{
                .ParameterType = d3d.D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS,
                .u = .{ .Constants = .{ .ShaderRegister = 1, .RegisterSpace = 0, .Num32BitValues = 1 } },
                .ShaderVisibility = d3d.D3D12_SHADER_VISIBILITY_VERTEX,
            },
            .{
                .ParameterType = d3d.D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE,
                .u = .{ .DescriptorTable = .{ .NumDescriptorRanges = 1, .pDescriptorRanges = &range } },
                .ShaderVisibility = d3d.D3D12_SHADER_VISIBILITY_PIXEL,
            },
        };
        const samplers = [_]d3d.D3D12_STATIC_SAMPLER_DESC{.{
            .Filter = d3d.D3D12_FILTER_MIN_MAG_LINEAR_MIP_POINT,
            .AddressU = d3d.D3D12_TEXTURE_ADDRESS_MODE_CLAMP,
            .AddressV = d3d.D3D12_TEXTURE_ADDRESS_MODE_CLAMP,
            .AddressW = d3d.D3D12_TEXTURE_ADDRESS_MODE_CLAMP,
            .MaxLOD = 0,
            .ShaderRegister = 0,
            .ShaderVisibility = d3d.D3D12_SHADER_VISIBILITY_PIXEL,
        }};
        const desc = d3d.D3D12_ROOT_SIGNATURE_DESC{
            .NumParameters = params.len,
            .pParameters = &params,
            .NumStaticSamplers = samplers.len,
            .pStaticSamplers = &samplers,
            .Flags = d3d.D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT,
        };
        var blob: ?*d3d.ID3DBlob = null;
        var errors: ?*d3d.ID3DBlob = null;
        const hr = r.api.D3D12SerializeRootSignature(&desc, d3d.D3D_ROOT_SIGNATURE_VERSION_1, &blob, &errors);
        if (errors) |e| {
            log("root signature: {s}", .{e.bytes()});
            _ = e.Release();
        }
        try check(hr, "D3D12SerializeRootSignature");
        defer _ = blob.?.Release();
        try check(r.device.CreateRootSignature(blob.?.bytes(), &r.root), "CreateRootSignature");
    }

    fn compile(r: *Renderer, source: []const u8, comptime target: [*:0]const u8, comptime name: [:0]const u8) Error!*d3d.ID3DBlob {
        var code: ?*d3d.ID3DBlob = null;
        var errors: ?*d3d.ID3DBlob = null;
        const hr = r.api.D3DCompile(source.ptr, source.len, name.ptr, null, null, "main", target, d3d.D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &code, &errors);
        if (errors) |e| {
            if (!d3d.ok(hr)) log("{s}: {s}", .{ name, e.bytes() });
            _ = e.Release();
        }
        try check(hr, "D3DCompile " ++ name);
        return code orelse error.D3D12Failed;
    }

    fn pipeline(r: *Renderer, vs: *d3d.ID3DBlob, ps: *d3d.ID3DBlob, p: PipelineDesc) Error!*d3d.ID3D12PipelineState {
        const vb = vs.bytes();
        const pb = ps.bytes();
        var desc = d3d.D3D12_GRAPHICS_PIPELINE_STATE_DESC{
            .pRootSignature = r.root,
            .VS = .{ .pShaderBytecode = vb.ptr, .BytecodeLength = vb.len },
            .PS = .{ .pShaderBytecode = pb.ptr, .BytecodeLength = pb.len },
            .InputLayout = .{ .pInputElementDescs = p.elements.ptr, .NumElements = @intCast(p.elements.len) },
            .PrimitiveTopologyType = if (p.lines) d3d.D3D12_PRIMITIVE_TOPOLOGY_TYPE_LINE else d3d.D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE,
            .NumRenderTargets = 1,
            .DSVFormat = depth_format,
            .SampleDesc = .{ .Count = r.samples },
        };
        desc.RTVFormats[0] = r.format;
        desc.RasterizerState.CullMode = if (p.cull) d3d.D3D12_CULL_MODE_BACK else d3d.D3D12_CULL_MODE_NONE;
        desc.RasterizerState.FrontCounterClockwise = d3d.TRUE;
        desc.RasterizerState.DepthBias = p.bias;
        desc.RasterizerState.SlopeScaledDepthBias = p.bias_slope;
        desc.RasterizerState.MultisampleEnable = if (r.samples > 1) d3d.TRUE else d3d.FALSE;
        desc.DepthStencilState.DepthFunc = d3d.D3D12_COMPARISON_FUNC_LESS_EQUAL;
        desc.DepthStencilState.DepthWriteMask = if (p.depth_write) d3d.D3D12_DEPTH_WRITE_MASK_ALL else d3d.D3D12_DEPTH_WRITE_MASK_ZERO;
        desc.BlendState.RenderTarget[0] = .{
            .BlendEnable = if (p.blend) d3d.TRUE else d3d.FALSE,
            .SrcBlend = d3d.D3D12_BLEND_SRC_ALPHA,
            .DestBlend = d3d.D3D12_BLEND_INV_SRC_ALPHA,
            .BlendOp = d3d.D3D12_BLEND_OP_ADD,
            .SrcBlendAlpha = d3d.D3D12_BLEND_ONE,
            .DestBlendAlpha = d3d.D3D12_BLEND_INV_SRC_ALPHA,
            .BlendOpAlpha = d3d.D3D12_BLEND_OP_ADD,
        };
        var out: ?*d3d.ID3D12PipelineState = null;
        try check(r.device.CreateGraphicsPipelineState(&desc, &out), "CreateGraphicsPipelineState");
        return out.?;
    }

    fn makePipelines(r: *Renderer) Error!void {
        const box_vs = try r.compile(hlsl.box_vs, "vs_5_0", "box.vs");
        defer _ = box_vs.Release();
        const box_ps = try r.compile(hlsl.box_ps, "ps_5_0", "box.ps");
        defer _ = box_ps.Release();
        const grid_vs = try r.compile(hlsl.grid_vs, "vs_5_0", "grid.vs");
        defer _ = grid_vs.Release();
        const grid_ps = try r.compile(hlsl.grid_ps, "ps_5_0", "grid.ps");
        defer _ = grid_ps.Release();
        const bed_vs = try r.compile(hlsl.bed_vs, "vs_5_0", "bed.vs");
        defer _ = bed_vs.Release();
        const bed_ps = try r.compile(hlsl.bed_ps, "ps_5_0", "bed.ps");
        defer _ = bed_ps.Release();
        const sign_ps = try r.compile(hlsl.sign_ps, "ps_5_0", "sign.ps");
        defer _ = sign_ps.Release();
        const decal_ps = try r.compile(hlsl.decal_ps, "ps_5_0", "decal.ps");
        defer _ = decal_ps.Release();
        const paint_vs = try r.compile(hlsl.paint_vs, "vs_5_0", "paint.vs");
        defer _ = paint_vs.Release();
        const paint_ps = try r.compile(hlsl.paint_ps, "ps_5_0", "paint.ps");
        defer _ = paint_ps.Release();

        // A bead is a closed mesh, so its back faces never show. The ghosts
        // show their back faces through their front.
        r.box_pipeline = try r.pipeline(box_vs, box_ps, .{ .elements = &box_elements, .cull = true });
        r.ghost_pipeline = try r.pipeline(box_vs, box_ps, .{ .elements = &box_elements, .blend = true, .depth_write = false });
        r.grid_pipeline = try r.pipeline(grid_vs, grid_ps, .{ .elements = &grid_elements, .lines = true });
        r.bed_pipeline = try r.pipeline(bed_vs, bed_ps, .{ .elements = &bed_elements, .blend = true, .bias = 4, .bias_slope = 2 });
        r.sign_pipeline = try r.pipeline(bed_vs, sign_ps, .{ .elements = &bed_elements, .blend = true, .depth_write = false });
        // A decal on a face stays in front of the beads of that face.
        r.decal_pipeline = try r.pipeline(bed_vs, decal_ps, .{ .elements = &bed_elements, .blend = true, .depth_write = false, .bias = -2, .bias_slope = -4 });
        // Both sides of each triangle draw: the winding of a file can be
        // either way.
        r.paint_pipeline = try r.pipeline(paint_vs, paint_ps, .{ .elements = &paint_elements });
    }

    // ---- buffers ----

    fn makeBuffer(r: *Renderer, b: *Buffer, size: usize) Error!void {
        r.freeBuffer(b);
        b.* = try r.createBuffer(@max(size, 16), d3d.D3D12_HEAP_TYPE_UPLOAD, d3d.D3D12_RESOURCE_STATE_GENERIC_READ);
    }

    fn createBuffer(r: *Renderer, size: usize, heap_type: u32, state: u32) Error!Buffer {
        var heap = d3d.D3D12_HEAP_PROPERTIES{ .Type = heap_type };
        var desc = d3d.D3D12_RESOURCE_DESC{
            .Dimension = d3d.D3D12_RESOURCE_DIMENSION_BUFFER,
            .Width = size,
            .Layout = d3d.D3D12_TEXTURE_LAYOUT_ROW_MAJOR,
        };
        var res: ?*d3d.ID3D12Resource = null;
        try check(r.device.CreateCommittedResource(&heap, &desc, state, null, &res), "CreateCommittedResource");
        errdefer _ = res.?.Release();
        var ptr: ?*anyopaque = null;
        // An upload buffer is never read through the mapping.
        const none = d3d.D3D12_RANGE{ .Begin = 0, .End = 0 };
        try check(res.?.Map(0, if (heap_type == d3d.D3D12_HEAP_TYPE_UPLOAD) &none else null, &ptr), "Map");
        return .{ .res = res, .map = @ptrCast(ptr), .gpu = res.?.GetGPUVirtualAddress(), .size = size };
    }

    fn freeBuffer(r: *Renderer, b: *Buffer) void {
        _ = r;
        if (b.res) |res| {
            res.Unmap(0, null);
            _ = res.Release();
        }
        b.* = .{};
    }

    /// Replaces the template mesh of a bead: vertices of 4 floats (see
    /// shaders/box.vert) and triangle indices.
    pub fn setMesh(r: *Renderer, verts: []const [4]f32, indices: []const u16) Error!void {
        if (verts.len > max_mesh_verts or indices.len > max_mesh_index) return error.OutOfMemory;
        @memcpy(r.mesh_verts[0..verts.len], verts);
        @memcpy(r.mesh_index[0..indices.len], indices);
        r.mesh_vert_count = verts.len;
        r.mesh_index_count = indices.len;
        r.lod_count = .{ 0, 0 };
        r.box_index_count = @intCast(indices.len);
        try r.uploadMesh();
    }

    /// A coarser mesh of a bead (level 1 or 2), after the full mesh in the
    /// same buffers. Call it after setMesh.
    pub fn setLodMesh(r: *Renderer, level: usize, verts: []const [4]f32, indices: []const u16) Error!void {
        const nv = r.mesh_vert_count;
        const ni = r.mesh_index_count;
        if (nv + verts.len > max_mesh_verts or ni + indices.len > max_mesh_index) return error.OutOfMemory;
        @memcpy(r.mesh_verts[nv .. nv + verts.len], verts);
        for (indices, r.mesh_index[ni .. ni + indices.len]) |i, *o| o.* = @intCast(nv + i);
        r.mesh_vert_count = nv + verts.len;
        r.mesh_index_count = ni + indices.len;
        r.lod_first[level - 1] = @intCast(ni);
        r.lod_count[level - 1] = @intCast(indices.len);
        try r.uploadMesh();
    }

    fn uploadMesh(r: *Renderer) Error!void {
        r.waitIdle();
        const vb = std.mem.sliceAsBytes(r.mesh_verts[0..r.mesh_vert_count]);
        try r.makeBuffer(&r.box_mesh, vb.len);
        @memcpy(r.box_mesh.map.?[0..vb.len], vb);
        const ib = std.mem.sliceAsBytes(r.mesh_index[0..r.mesh_index_count]);
        try r.makeBuffer(&r.box_index, ib.len);
        @memcpy(r.box_index.map.?[0..ib.len], ib);
    }

    /// The copy of the instances of a next scene on a thread (see
    /// `beginInstances`).
    const Upload = struct {
        thread: std.Thread = undefined,
        done: std.atomic.Value(bool) = .init(false),
        count: u32,

        fn run(u: *Upload, dst: [*]u8, items: []const Instance, marks: []const Instance) void {
            const a = std.mem.sliceAsBytes(items);
            const b = std.mem.sliceAsBytes(marks);
            @memcpy(dst[0..a.len], a);
            @memcpy(dst[a.len..][0..b.len], b);
            u.done.store(true, .release);
        }
    };

    /// Starts a copy of the beads, then the marks, of a next scene into a
    /// second instance buffer, on a thread. The frames still draw the
    /// instances before; `swapInstances` puts the new ones in. The caller
    /// keeps `items` and `marks` until then. False if the buffer is not
    /// free yet: then use `setInstances`.
    pub fn beginInstances(r: *Renderer, items: []const Instance, marks: []const Instance) Error!bool {
        r.cancelInstances();
        r.updateDone();
        if (r.retired.res != null and r.retired_until <= r.frames_done) r.freeBuffer(&r.retired);
        if (r.next_instances.res != null and r.next_until > r.frames_done) {
            // A frame on the GPU can still read it: it goes when that frame
            // is done.
            if (r.retired.res != null) return false;
            r.retired = r.next_instances;
            r.retired_until = r.next_until;
            r.next_instances = .{};
        }
        const need = (items.len + marks.len + max_extras) * @sizeOf(Instance);
        if (need > r.next_instances.size or r.next_instances.res == null) try r.makeBuffer(&r.next_instances, need);
        const u = std.heap.c_allocator.create(Upload) catch return error.OutOfMemory;
        u.* = .{ .count = @intCast(items.len + marks.len) };
        u.thread = std.Thread.spawn(.{}, Upload.run, .{ u, r.next_instances.map.?, items, marks }) catch {
            std.heap.c_allocator.destroy(u);
            return false;
        };
        r.upload = u;
        return true;
    }

    /// Counts the frames that the GPU has finished.
    fn updateDone(r: *Renderer) void {
        if (r.fence.?.GetCompletedValue() >= r.frame_value) r.frames_done = r.frames_sent;
    }

    /// True when the copy of `beginInstances` is done.
    pub fn instancesReady(r: *const Renderer) bool {
        const u = r.upload orelse return false;
        return u.done.load(.acquire);
    }

    /// Puts in the instances of `beginInstances` (it waits for the copy).
    /// The old buffer is the next one, after the frames that read it.
    pub fn swapInstances(r: *Renderer) void {
        const u = r.upload orelse return;
        u.thread.join();
        std.mem.swap(Buffer, &r.instances, &r.next_instances);
        r.next_until = r.frames_sent;
        r.instance_count = u.count;
        std.heap.c_allocator.destroy(u);
        r.upload = null;
    }

    /// Stops the copy of `beginInstances`: the instances stay.
    pub fn cancelInstances(r: *Renderer) void {
        const u = r.upload orelse return;
        u.thread.join();
        std.heap.c_allocator.destroy(u);
        r.upload = null;
    }

    /// The count of the beads and the marks in the instances.
    pub fn instanceCount(r: *const Renderer) usize {
        return r.instance_count;
    }

    /// Replaces the beads, then the marks after them. Waits for the GPU.
    /// The buffer has spare slots after them for Frame.extras and Frame.head.
    pub fn setInstances(r: *Renderer, items: []const Instance, marks: []const Instance) Error!void {
        r.waitIdle();
        const bytes = std.mem.sliceAsBytes(items);
        const mark_bytes = std.mem.sliceAsBytes(marks);
        const need = bytes.len + mark_bytes.len + max_extras * @sizeOf(Instance);
        if (need > r.instances.size) try r.makeBuffer(&r.instances, need);
        @memcpy(r.instances.map.?[0..bytes.len], bytes);
        @memcpy(r.instances.map.?[bytes.len .. bytes.len + mark_bytes.len], mark_bytes);
        r.instance_count = @intCast(items.len + marks.len);
    }

    /// The beads and the marks in the instance buffer, for the caller to
    /// change some of them in place. Waits for the GPU. Null with no buffer.
    pub fn instancesInPlace(r: *Renderer) ?[]Instance {
        const map = r.instances.map orelse return null;
        r.waitIdle();
        const p: [*]Instance = @ptrCast(@alignCast(map));
        return p[0..r.instance_count];
    }

    /// The instance buffer for `n` beads, for the caller to fill in place.
    /// The marks are none. Waits for the GPU.
    pub fn instanceBuffer(r: *Renderer, n: usize) Error![]Instance {
        r.waitIdle();
        const need = (n + max_extras) * @sizeOf(Instance);
        if (need > r.instances.size) try r.makeBuffer(&r.instances, need);
        r.instance_count = @intCast(n);
        const p: [*]Instance = @ptrCast(@alignCast(r.instances.map.?));
        return p[0..n];
    }

    /// Replaces the grid lines: pairs of points, x, y, z each.
    pub fn setGrid(r: *Renderer, points: []const f32) Error!void {
        r.waitIdle();
        const bytes = std.mem.sliceAsBytes(points);
        if (bytes.len > r.grid.size) try r.makeBuffer(&r.grid, bytes.len);
        @memcpy(r.grid.map.?[0..bytes.len], bytes);
    }

    /// Replaces the bed model: its triangles (see bed.zig), and its texture
    /// or null.
    pub fn setBed(r: *Renderer, verts: []const BedVertex, image: ?BedImage) Error!void {
        r.waitIdle();
        r.bed_count = 0;
        if (verts.len == 0) return;
        const bytes = std.mem.sliceAsBytes(verts);
        if (bytes.len > r.bed.size) try r.makeBuffer(&r.bed, bytes.len);
        @memcpy(r.bed.map.?[0..bytes.len], bytes);
        // A white pixel when the bed has no texture: the table needs an
        // image.
        const white = [4]u8{ 255, 255, 255, 255 };
        const img: BedImage = image orelse .{ .width = 1, .height = 1, .rgba = @constCast(&white) };
        try r.uploadTexture(img, &r.bed_tex, srv_bed);
        r.bed_count = @intCast(verts.len);
    }

    /// Replaces the image of the signs of the plates (null: none).
    pub fn setSignImage(r: *Renderer, image: ?BedImage) Error!void {
        r.waitIdle();
        const img = image orelse {
            if (r.sign_tex) |t| _ = t.Release();
            r.sign_tex = null;
            return;
        };
        try r.uploadTexture(img, &r.sign_tex, srv_sign);
    }

    /// Copies an RGBA image to a new texture, through an upload buffer, and
    /// writes its descriptor. The GPU is idle.
    fn uploadTexture(r: *Renderer, img: BedImage, tex: *?*d3d.ID3D12Resource, slot: u32) Error!void {
        if (tex.*) |t| _ = t.Release();
        tex.* = null;
        var heap = d3d.D3D12_HEAP_PROPERTIES{ .Type = d3d.D3D12_HEAP_TYPE_DEFAULT };
        var desc = d3d.D3D12_RESOURCE_DESC{
            .Dimension = d3d.D3D12_RESOURCE_DIMENSION_TEXTURE2D,
            .Width = img.width,
            .Height = img.height,
            .Format = d3d.DXGI_FORMAT_R8G8B8A8_UNORM,
        };
        var res: ?*d3d.ID3D12Resource = null;
        try check(r.device.CreateCommittedResource(&heap, &desc, d3d.D3D12_RESOURCE_STATE_COPY_DEST, null, &res), "CreateCommittedResource texture");
        tex.* = res;

        const row = img.width * 4;
        const pitch = std.mem.alignForward(u32, row, d3d.D3D12_TEXTURE_DATA_PITCH_ALIGNMENT);
        var staging = try r.createBuffer(@as(usize, pitch) * img.height, d3d.D3D12_HEAP_TYPE_UPLOAD, d3d.D3D12_RESOURCE_STATE_GENERIC_READ);
        defer r.freeBuffer(&staging);
        for (0..img.height) |y| @memcpy(staging.map.?[y * pitch..][0..row], img.rgba[y * row..][0..row]);

        const cmd = try r.beginList();
        const dst = d3d.D3D12_TEXTURE_COPY_LOCATION{
            .pResource = res,
            .Type = d3d.D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX,
            .u = .{ .SubresourceIndex = 0 },
        };
        const src = d3d.D3D12_TEXTURE_COPY_LOCATION{
            .pResource = staging.res,
            .Type = d3d.D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT,
            .u = .{ .PlacedFootprint = .{ .Footprint = .{
                .Format = d3d.DXGI_FORMAT_R8G8B8A8_UNORM,
                .Width = img.width,
                .Height = img.height,
                .RowPitch = pitch,
            } } },
        };
        cmd.CopyTextureRegion(&dst, 0, 0, 0, &src, null);
        transition(cmd, res.?, d3d.D3D12_RESOURCE_STATE_COPY_DEST, d3d.D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
        try r.execute(cmd);
        r.waitIdle();

        var view = d3d.D3D12_SHADER_RESOURCE_VIEW_DESC{
            .Format = d3d.DXGI_FORMAT_R8G8B8A8_UNORM,
            .ViewDimension = d3d.D3D12_SRV_DIMENSION_TEXTURE2D,
            .u = .{ .Texture2D = .{ .MipLevels = 1 } },
        };
        r.device.CreateShaderResourceView(res, &view, r.srv_heap.?.cpuStart() + slot * r.srv_size);
    }

    // ---- targets ----

    fn rtv(r: *const Renderer, index: u32) usize {
        return r.rtv_heap.?.cpuStart() + index * r.rtv_size;
    }

    fn createTarget(r: *Renderer, format: u32, samples: u32, flags: u32, state: u32, clear: ?*const d3d.D3D12_CLEAR_VALUE) Error!*d3d.ID3D12Resource {
        var heap = d3d.D3D12_HEAP_PROPERTIES{ .Type = d3d.D3D12_HEAP_TYPE_DEFAULT };
        var desc = d3d.D3D12_RESOURCE_DESC{
            .Dimension = d3d.D3D12_RESOURCE_DIMENSION_TEXTURE2D,
            .Width = r.width,
            .Height = r.height,
            .Format = format,
            .SampleDesc = .{ .Count = samples },
            .Flags = flags,
        };
        var out: ?*d3d.ID3D12Resource = null;
        try check(r.device.CreateCommittedResource(&heap, &desc, state, clear, &out), "CreateCommittedResource target");
        return out.?;
    }

    /// The depth image, and the multisampled color image, of the size of
    /// the drawing.
    fn makeDepthAndMsaa(r: *Renderer) Error!void {
        const clear = d3d.D3D12_CLEAR_VALUE{
            .Format = depth_format,
            .u = .{ .DepthStencil = .{ .Depth = 1, .Stencil = 0 } },
        };
        r.depth = try r.createTarget(depth_format, r.samples, d3d.D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL, d3d.D3D12_RESOURCE_STATE_DEPTH_WRITE, &clear);
        r.device.CreateDepthStencilView(r.depth, r.dsv_heap.?.cpuStart());
        if (r.samples > 1) {
            r.msaa = try r.createTarget(r.format, r.samples, d3d.D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET, d3d.D3D12_RESOURCE_STATE_RENDER_TARGET, null);
            r.device.CreateRenderTargetView(r.msaa, r.rtv(rtv_msaa));
        }
    }

    /// Releases the images that depend on the size. The GPU is idle.
    fn releaseTargets(r: *Renderer) void {
        for (&r.back) |*b| {
            if (b.*) |x| _ = x.Release();
            b.* = null;
        }
        r.back_count = 0;
        if (r.depth) |x| _ = x.Release();
        r.depth = null;
        if (r.msaa) |x| _ = x.Release();
        r.msaa = null;
    }

    fn adoptBackBuffers(r: *Renderer) Error!void {
        const sc = r.swapchain.?;
        var desc: d3d.DXGI_SWAP_CHAIN_DESC1 = undefined;
        try check(sc.GetDesc1(&desc), "GetDesc1");
        r.width = desc.Width;
        r.height = desc.Height;
        for (0..sc_buffers) |i| {
            var buf: ?*d3d.ID3D12Resource = null;
            try check(sc.GetBuffer(@intCast(i), &buf), "GetBuffer");
            r.back[i] = buf;
            r.device.CreateRenderTargetView(buf, r.rtv(@intCast(i)));
            r.back_count += 1;
        }
        try r.makeDepthAndMsaa();
        r.stale = false;
    }

    /// A composition swapchain: the shell sets it on its panel. The view is
    /// opaque, so the alpha is ignored. A composition surface that refuses
    /// that takes premultiplied alpha: each pixel has an alpha of 1.
    fn makeSwapchain(r: *Renderer) Error!void {
        var desc = d3d.DXGI_SWAP_CHAIN_DESC1{
            .Width = r.want_width,
            .Height = r.want_height,
            .Format = r.format,
            .BufferCount = sc_buffers,
            .AlphaMode = d3d.DXGI_ALPHA_MODE_IGNORE,
            .Flags = d3d.DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT,
        };
        var sc: ?*d3d.IDXGISwapChain3 = null;
        var hr = r.factory.CreateSwapChainForComposition(r.queue, &desc, &sc);
        if (!d3d.ok(hr)) {
            desc.AlphaMode = d3d.DXGI_ALPHA_MODE_PREMULTIPLIED;
            hr = r.factory.CreateSwapChainForComposition(r.queue, &desc, &sc);
        }
        try check(hr, "CreateSwapChainForComposition");
        r.swapchain = sc;
        try check(sc.?.SetMaximumFrameLatency(1), "SetMaximumFrameLatency");
        r.latency = sc.?.GetFrameLatencyWaitableObject() orelse return error.D3D12Failed;
        try r.adoptBackBuffers();
    }

    fn resizeSwapchain(r: *Renderer) Error!void {
        r.waitIdle();
        r.releaseTargets();
        // The flags of a swapchain must stay the same.
        try check(r.swapchain.?.ResizeBuffers(0, r.want_width, r.want_height, d3d.DXGI_FORMAT_UNKNOWN, d3d.DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT), "ResizeBuffers");
        try r.adoptBackBuffers();
    }

    /// The offscreen image of the wanted size, its depth and multisampled
    /// images, and the host buffer for the copy.
    fn makeTarget(r: *Renderer) Error!void {
        r.waitIdle();
        r.releaseTargets();
        if (r.target) |t| _ = t.Release();
        r.target = null;
        r.freeBuffer(&r.readback);
        r.drawn = false;
        r.width = r.want_width;
        r.height = r.want_height;
        r.target = try r.createTarget(r.format, 1, d3d.D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET, d3d.D3D12_RESOURCE_STATE_RENDER_TARGET, null);
        r.device.CreateRenderTargetView(r.target, r.rtv(rtv_target));
        try r.makeDepthAndMsaa();
        r.readback_pitch = std.mem.alignForward(u32, r.width * 4, d3d.D3D12_TEXTURE_DATA_PITCH_ALIGNMENT);
        r.readback = try r.createBuffer(@as(usize, r.readback_pitch) * r.height, d3d.D3D12_HEAP_TYPE_READBACK, d3d.D3D12_RESOURCE_STATE_COPY_DEST);
        r.stale = false;
    }

    /// Copies the last offscreen frame out, row by row from the top, with
    /// `stride` bytes from one row to the next. Waits for the frame.
    /// error.FrameBusy before the first frame, or for a swapchain renderer.
    pub fn read(r: *Renderer, out: []u8, stride: usize) Error!void {
        if (!r.offscreen or !r.drawn) return error.FrameBusy;
        while (!r.waitFrame(d3d.INFINITE)) {}
        const row = @as(usize, r.width) * 4;
        if (stride < row or out.len < stride * (r.height - 1) + row) return error.D3D12Failed;
        const src = r.readback.map.?;
        for (0..r.height) |y| @memcpy(out[y * stride ..][0..row], src[y * r.readback_pitch ..][0..row]);
    }

    /// The size of the offscreen image (after the first frame).
    pub fn targetSize(r: *const Renderer) [2]u32 {
        return .{ r.width, r.height };
    }

    // ---- frame ----

    /// Draws one frame and presents it. An offscreen renderer draws into
    /// its image and copies it to the host (see `read`).
    pub fn draw(r: *Renderer, frame: Frame) Error!void {
        if (r.offscreen) return r.drawOffscreen(frame);
        // A short wait only: the UI thread draws, and must not block. The
        // frame is skipped, and the shell tries again.
        if (!r.waitFrame(50)) return error.FrameBusy;
        r.frames_done = r.frames_sent;
        if (r.stale) try r.resizeSwapchain();
        if (r.back_count == 0) return;
        // The compositor holds the frame before: skip this one. The wait
        // takes one count of the object, so it stays held until a present.
        if (!r.latency_held) {
            if (d3d.WaitForSingleObject(r.latency.?, 0) != d3d.WAIT_OBJECT_0) return error.FrameBusy;
            r.latency_held = true;
        }
        try r.syncPlates(frame);

        const sc = r.swapchain.?;
        const index = sc.GetCurrentBackBufferIndex();
        const back = r.back[index].?;
        const cmd = try r.beginList();
        if (r.msaa) |ms| {
            transition(cmd, back, d3d.D3D12_RESOURCE_STATE_PRESENT, d3d.D3D12_RESOURCE_STATE_RESOLVE_DEST);
            r.recordPass(cmd, rtv_msaa, frame, true);
            transition(cmd, ms, d3d.D3D12_RESOURCE_STATE_RENDER_TARGET, d3d.D3D12_RESOURCE_STATE_RESOLVE_SOURCE);
            cmd.ResolveSubresource(back, 0, ms, 0, r.format);
            transition(cmd, ms, d3d.D3D12_RESOURCE_STATE_RESOLVE_SOURCE, d3d.D3D12_RESOURCE_STATE_RENDER_TARGET);
            transition(cmd, back, d3d.D3D12_RESOURCE_STATE_RESOLVE_DEST, d3d.D3D12_RESOURCE_STATE_PRESENT);
        } else {
            transition(cmd, back, d3d.D3D12_RESOURCE_STATE_PRESENT, d3d.D3D12_RESOURCE_STATE_RENDER_TARGET);
            r.recordPass(cmd, index, frame, true);
            transition(cmd, back, d3d.D3D12_RESOURCE_STATE_RENDER_TARGET, d3d.D3D12_RESOURCE_STATE_PRESENT);
        }
        try r.execute(cmd);
        const presented = sc.Present(1, 0);
        r.latency_held = false;
        try r.signalFrame();
        try check(presented, "Present");
    }

    /// Draws one frame into the offscreen image, and copies the image to
    /// the readback buffer. It waits for the frame before.
    fn drawOffscreen(r: *Renderer, frame: Frame) Error!void {
        while (!r.waitFrame(d3d.INFINITE)) {}
        r.frames_done = r.frames_sent;
        if (r.stale or r.target == null) try r.makeTarget();
        try r.syncPlates(frame);
        const target = r.target.?;
        const cmd = try r.beginList();
        const color: u32 = if (r.msaa != null) rtv_msaa else rtv_target;
        if (frame.cached) r.recordPrintView(cmd, color, frame) else r.recordPass(cmd, color, frame, true);
        if (r.msaa) |ms| {
            transition(cmd, ms, d3d.D3D12_RESOURCE_STATE_RENDER_TARGET, d3d.D3D12_RESOURCE_STATE_RESOLVE_SOURCE);
            transition(cmd, target, d3d.D3D12_RESOURCE_STATE_RENDER_TARGET, d3d.D3D12_RESOURCE_STATE_RESOLVE_DEST);
            cmd.ResolveSubresource(target, 0, ms, 0, r.format);
            transition(cmd, ms, d3d.D3D12_RESOURCE_STATE_RESOLVE_SOURCE, d3d.D3D12_RESOURCE_STATE_RENDER_TARGET);
            transition(cmd, target, d3d.D3D12_RESOURCE_STATE_RESOLVE_DEST, d3d.D3D12_RESOURCE_STATE_COPY_SOURCE);
        } else {
            transition(cmd, target, d3d.D3D12_RESOURCE_STATE_RENDER_TARGET, d3d.D3D12_RESOURCE_STATE_COPY_SOURCE);
        }
        const dst = d3d.D3D12_TEXTURE_COPY_LOCATION{
            .pResource = r.readback.res,
            .Type = d3d.D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT,
            .u = .{ .PlacedFootprint = .{ .Footprint = .{
                .Format = r.format,
                .Width = r.width,
                .Height = r.height,
                .RowPitch = r.readback_pitch,
            } } },
        };
        const src = d3d.D3D12_TEXTURE_COPY_LOCATION{
            .pResource = target,
            .Type = d3d.D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX,
            .u = .{ .SubresourceIndex = 0 },
        };
        cmd.CopyTextureRegion(&dst, 0, 0, 0, &src, null);
        transition(cmd, target, d3d.D3D12_RESOURCE_STATE_COPY_SOURCE, d3d.D3D12_RESOURCE_STATE_RENDER_TARGET);
        try r.execute(cmd);
        try r.signalFrame();
        r.drawn = true;
    }

    /// A frame of a print view (Frame.cached): the finished layers with
    /// `base`, then the top layer, the extras, and the toolhead over them.
    fn recordPrintView(r: *Renderer, cmd: *d3d.ID3D12GraphicsCommandList, color: u32, frame: Frame) void {
        const base_end = @min(frame.base_end, frame.box_count);
        var part = frame;
        part.extras = &.{};
        part.head = &.{};
        part.mark_count = 0;
        part.box = frame.base;
        part.box_count = base_end;
        r.recordPass(cmd, color, part, true);
        var rest = frame;
        rest.box_first = @max(frame.box_first, base_end);
        rest.grid_vertices = 0;
        rest.bed_vertices = 0;
        r.recordPass(cmd, color, rest, false);
    }

    /// True for a plate frame of another plate: the light beads of the
    /// active plate (flag_active, flag_part) are for the frame backend.
    fn otherPlate(pf: PlateFrame) bool {
        return pf.flags & (PlateFrame.flag_active | PlateFrame.flag_part) == 0 and pf.slot < max_plate_slots;
    }

    /// Uploads the bead buffer of each other plate whose generation changed,
    /// and the grid lines of their beds. The GPU is done with the frame
    /// before.
    fn syncPlates(r: *Renderer, frame: Frame) Error!void {
        for (frame.plates) |pf| {
            if (!otherPlate(pf)) continue;
            const sl = &r.plate_slots[pf.slot];
            if (sl.used and sl.gen == pf.gen) continue;
            const n = @as(usize, pf.instance_count) * @sizeOf(Instance);
            if (n > sl.buf.size or sl.buf.res == null) try r.makeBuffer(&sl.buf, n);
            if (n > 0) {
                const src: [*]const u8 = @ptrFromInt(pf.instances);
                @memcpy(sl.buf.map.?[0..n], src[0..n]);
            }
            sl.gen = pf.gen;
            sl.used = true;
        }
        if (frame.plate_grid_gen != r.plate_grid_gen) {
            const bytes = std.mem.sliceAsBytes(frame.plate_grid);
            if (bytes.len > r.plate_grid.size or r.plate_grid.res == null) try r.makeBuffer(&r.plate_grid, bytes.len);
            if (bytes.len > 0) @memcpy(r.plate_grid.map.?[0..bytes.len], bytes);
            r.plate_grid_gen = frame.plate_grid_gen;
        }
    }

    fn setPush(cmd: *d3d.ID3D12GraphicsCommandList, push: *const Push) void {
        cmd.SetGraphicsRoot32BitConstants(root_push, push_values, push, 0);
    }

    fn use(cmd: *d3d.ID3D12GraphicsCommandList, state: ?*d3d.ID3D12PipelineState, lines: bool) void {
        cmd.SetPipelineState(state.?);
        cmd.IASetPrimitiveTopology(if (lines) d3d.D3D_PRIMITIVE_TOPOLOGY_LINELIST else d3d.D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    }

    fn bindVertices(cmd: *d3d.ID3D12GraphicsCommandList, b: *const Buffer, stride: u32) void {
        const views = [_]d3d.D3D12_VERTEX_BUFFER_VIEW{vertexView(b, stride)};
        cmd.IASetVertexBuffers(0, 1, &views);
    }

    fn bindBeads(r: *const Renderer, cmd: *d3d.ID3D12GraphicsCommandList, instances: *const Buffer) void {
        const views = [_]d3d.D3D12_VERTEX_BUFFER_VIEW{
            vertexView(&r.box_mesh, 16),
            vertexView(instances, @sizeOf(Instance)),
        };
        cmd.IASetVertexBuffers(0, 2, &views);
        const index = d3d.D3D12_INDEX_BUFFER_VIEW{
            .BufferLocation = r.box_index.gpu,
            .SizeInBytes = @intCast(r.box_index.size),
            .Format = d3d.DXGI_FORMAT_R16_UINT,
        };
        cmd.IASetIndexBuffer(&index);
    }

    /// An instanced draw. The shader gets the first instance, for the
    /// highlight (see the file comment).
    fn drawIndexed(cmd: *d3d.ID3D12GraphicsCommandList, indices: u32, count: u32, first_index: u32, first_instance: u32) void {
        cmd.SetGraphicsRoot32BitConstant(root_first_instance, first_instance, 0);
        cmd.DrawIndexedInstanced(indices, count, first_index, 0, first_instance);
    }

    /// Draws ranges of beads, each with its mesh level. The last ranges
    /// first: the top layers, so the depth test drops the hidden pixels of
    /// the layers under them early.
    fn drawList(r: *const Renderer, cmd: *d3d.ID3D12GraphicsCommandList, list: []const Draw) void {
        var i = list.len;
        while (i > 0) {
            i -= 1;
            const dr = list[i];
            const lod = @min(dr.lod, 2);
            if (lod > 0 and r.lod_count[lod - 1] > 0) {
                drawIndexed(cmd, r.lod_count[lod - 1], dr.count, r.lod_first[lod - 1], dr.first);
            } else drawIndexed(cmd, r.box_index_count, dr.count, 0, dr.first);
        }
    }

    /// The beads of a frame: its draw list, or all beads box_first ..
    /// box_count with the full mesh for a frame with no list.
    fn drawBeads(r: *const Renderer, cmd: *d3d.ID3D12GraphicsCommandList, frame: Frame) void {
        if (!frame.culled) {
            const first = @min(frame.box_first, frame.box_count);
            drawIndexed(cmd, r.box_index_count, frame.box_count - first, 0, first);
            return;
        }
        r.drawList(cmd, frame.draws);
    }

    /// The beads of the other plates: each with its matrix and its fade
    /// (light.w), no highlight and no focus. The box pipeline is bound; the
    /// instance buffer of the active plate is bound again after.
    fn drawOtherPlates(r: *const Renderer, cmd: *d3d.ID3D12GraphicsCommandList, frame: Frame) void {
        var drew = false;
        for (frame.plates) |pf| {
            if (!otherPlate(pf) or pf.draws_count == 0) continue;
            const sl = &r.plate_slots[pf.slot];
            if (!sl.used or sl.buf.res == null or pf.draws_first + pf.draws_count > frame.plate_draws.len) continue;
            var push = frame.box;
            push.mvp = pf.mvp;
            push.vec[3] = pf.fade;
            push.params[0] = 0;
            push.params[1] = 0;
            push.params[2] = 0;
            setPush(cmd, &push);
            r.bindBeads(cmd, &sl.buf);
            r.drawList(cmd, frame.plate_draws[pf.draws_first .. pf.draws_first + pf.draws_count]);
            drew = true;
        }
        if (drew) {
            setPush(cmd, &frame.box);
            if (r.instances.res != null) r.bindBeads(cmd, &r.instances);
        }
    }

    fn setTexture(r: *const Renderer, cmd: *d3d.ID3D12GraphicsCommandList, slot: u32) void {
        cmd.SetGraphicsRootDescriptorTable(root_texture, r.srv_heap.?.gpuStart() + slot * r.srv_size);
    }

    /// The bed model, and its copy at each other plate of the same printer.
    fn drawBed(r: *const Renderer, cmd: *d3d.ID3D12GraphicsCommandList, frame: Frame) void {
        if (frame.bed_vertices == 0 or r.bed_count == 0) return;
        const n = @min(frame.bed_vertices, r.bed_count);
        use(cmd, r.bed_pipeline, false);
        r.setTexture(cmd, srv_bed);
        setPush(cmd, &frame.bed);
        bindVertices(cmd, &r.bed, @sizeOf(BedVertex));
        cmd.DrawInstanced(n, 1, 0, 0);
        for (frame.plates) |pf| {
            if (!otherPlate(pf) or pf.flags & PlateFrame.flag_bed == 0) continue;
            var push = frame.bed;
            push.mvp = pf.bed_mvp;
            setPush(cmd, &push);
            cmd.DrawInstanced(n, 1, 0, 0);
        }
    }

    /// The mesh of the Paint tool. It goes into its buffer only when it
    /// changes. The frame before is done, so the CPU can write the buffer.
    fn drawPaint(r: *Renderer, cmd: *d3d.ID3D12GraphicsCommandList, frame: Frame) void {
        const bytes = std.mem.sliceAsBytes(frame.paint);
        if (bytes.len > r.paint_buf.size) {
            r.makeBuffer(&r.paint_buf, bytes.len + bytes.len / 2) catch return;
            r.paint_len = std.math.maxInt(usize);
        }
        if (frame.paint_gen != r.paint_gen or r.paint_len != frame.paint.len) {
            // The buffer has the mesh of the frame before: only the
            // vertices that changed since then.
            const lo = @min(frame.paint_dirty[0], frame.paint.len);
            const hi = @min(frame.paint_dirty[1], frame.paint.len);
            const size = @sizeOf(BedVertex);
            if (r.paint_len != std.math.maxInt(usize) and r.paint_gen == frame.paint_base_gen) {
                if (lo < hi) @memcpy(r.paint_buf.map.?[lo * size .. hi * size], bytes[lo * size .. hi * size]);
            } else {
                @memcpy(r.paint_buf.map.?[0..bytes.len], bytes);
            }
            r.paint_gen = frame.paint_gen;
            r.paint_len = frame.paint.len;
        }
        var push = frame.sign;
        push.eye = frame.paint_light;
        use(cmd, r.paint_pipeline, false);
        setPush(cmd, &push);
        bindVertices(cmd, &r.paint_buf, @sizeOf(BedVertex));
        cmd.DrawInstanced(@intCast(frame.paint.len), 1, 0, 0);
    }

    /// Records the draws of a frame into the render target `color`. With
    /// `clear` it clears the color and the depth first.
    fn recordPass(r: *Renderer, cmd: *d3d.ID3D12GraphicsCommandList, color: u32, frame: Frame, clear: bool) void {
        const color_view = [_]usize{r.rtv(color)};
        const depth_view = r.dsv_heap.?.cpuStart();
        cmd.OMSetRenderTargets(1, &color_view, d3d.FALSE, &depth_view);
        if (clear) {
            const rgba = [4]f32{ frame.clear[0], frame.clear[1], frame.clear[2], 1 };
            cmd.ClearRenderTargetView(color_view[0], &rgba);
            cmd.ClearDepthStencilView(depth_view, d3d.D3D12_CLEAR_FLAG_DEPTH, 1, 0);
        }
        const viewports = [_]d3d.D3D12_VIEWPORT{.{
            .TopLeftX = 0,
            .TopLeftY = 0,
            .Width = @floatFromInt(r.width),
            .Height = @floatFromInt(r.height),
        }};
        cmd.RSSetViewports(1, &viewports);
        const scissors = [_]d3d.D3D12_RECT{.{ .left = 0, .top = 0, .right = @intCast(r.width), .bottom = @intCast(r.height) }};
        cmd.RSSetScissorRects(1, &scissors);
        cmd.SetGraphicsRootSignature(r.root.?);
        const heaps = [_]*d3d.ID3D12DescriptorHeap{r.srv_heap.?};
        cmd.SetDescriptorHeaps(1, &heaps);
        cmd.SetGraphicsRoot32BitConstant(root_first_instance, 0, 0);

        if (frame.grid_vertices > 0 and r.grid.res != null) {
            use(cmd, r.grid_pipeline, true);
            setPush(cmd, &frame.grid);
            bindVertices(cmd, &r.grid, 12);
            cmd.DrawInstanced(frame.grid_vertices, 1, 0, 0);
        }
        // The grids of the other plates: the plates that cannot slice in a
        // lighter color.
        const plate_grid_n: u32 = @intCast(frame.plate_grid.len / 3);
        if (plate_grid_n > 0 and r.plate_grid.res != null) {
            use(cmd, r.grid_pipeline, true);
            setPush(cmd, &frame.grid);
            bindVertices(cmd, &r.plate_grid, 12);
            const dim = @min(frame.plate_grid_dim, plate_grid_n);
            if (dim > 0) cmd.DrawInstanced(dim, 1, 0, 0);
            if (plate_grid_n > dim) {
                var light = frame.grid;
                light.vec = .{ 0.88, 0.89, 0.91, 1 };
                setPush(cmd, &light);
                cmd.DrawInstanced(plate_grid_n - dim, 1, dim, 0);
            }
        }
        // The Paint tool: the mesh of the part, the bed, and no beads.
        if (frame.paint.len > 0) {
            r.drawPaint(cmd, frame);
            r.drawBed(cmd, frame);
            return;
        }
        // The other plates, with no beads of the active plate too.
        if (frame.box_count == 0 and r.box_index_count > 0 and frame.plates.len > 0) {
            use(cmd, r.box_pipeline, false);
            r.drawOtherPlates(cmd, frame);
        }
        if (frame.box_count > 0 and r.instances.res != null and r.box_index_count > 0) {
            use(cmd, r.box_pipeline, false);
            setPush(cmd, &frame.box);
            r.bindBeads(cmd, &r.instances);
            r.drawBeads(cmd, frame);
            if (frame.mark_count > 0) drawIndexed(cmd, r.box_index_count, frame.mark_count, 0, frame.mark_first);
            r.drawOtherPlates(cmd, frame);
            // A part that turns in the view only: its own push data.
            if (frame.part_draws.len > 0) {
                setPush(cmd, &frame.part);
                r.drawList(cmd, frame.part_draws);
                setPush(cmd, &frame.box);
            }
            // With a focus (params.z != 0): the beads out of the focus, as
            // ghosts, after the solid beads (params.w = 2 in the shader).
            if (frame.box.params[2] != 0) {
                var ghost = frame.box;
                ghost.params[3] = 2;
                use(cmd, r.ghost_pipeline, false);
                setPush(cmd, &ghost);
                r.drawBeads(cmd, frame);
                if (frame.mark_count > 0) drawIndexed(cmd, r.box_index_count, frame.mark_count, 0, frame.mark_first);
                use(cmd, r.box_pipeline, false);
                setPush(cmd, &frame.box);
            }
        }
        if (frame.extras.len > 0 and r.instances.res != null and r.box_index_count > 0) {
            const extras = frame.extras[0..@min(frame.extras.len, max_extras)];
            // The spare slots after the beads. The previous frame is done,
            // so the CPU can write them.
            const off = @as(usize, r.instance_count) * @sizeOf(Instance);
            const eb = std.mem.sliceAsBytes(extras);
            @memcpy(r.instances.map.?[off .. off + eb.len], eb);
            if (frame.box_count == 0) {
                use(cmd, r.box_pipeline, false);
                setPush(cmd, &frame.box);
                r.bindBeads(cmd, &r.instances);
            }
            drawIndexed(cmd, r.box_index_count, @intCast(extras.len), 0, r.instance_count);
        }
        // The bed after the beads: its see-through parts blend over them.
        r.drawBed(cmd, frame);
        // The signs of the plates, after the bed: the parts hide them.
        if (frame.signs.len > 0 and r.sign_tex != null) sign: {
            const bytes = std.mem.sliceAsBytes(frame.signs);
            if (bytes.len > r.sign_buf.size) r.makeBuffer(&r.sign_buf, bytes.len * 2) catch break :sign;
            @memcpy(r.sign_buf.map.?[0..bytes.len], bytes);
            use(cmd, r.sign_pipeline, false);
            r.setTexture(cmd, srv_sign);
            setPush(cmd, &frame.sign);
            bindVertices(cmd, &r.sign_buf, @sizeOf(BedVertex));
            cmd.DrawInstanced(@intCast(frame.signs.len), 1, 0, 0);
        }
        // The decals of the labels: the parts hide them, and they cover the
        // beads of their face.
        if (frame.decals.len + frame.decal_edges.len > 0) decal: {
            const fill = std.mem.sliceAsBytes(frame.decals);
            const edges = std.mem.sliceAsBytes(frame.decal_edges);
            const need = fill.len + edges.len;
            if (need > r.decal_buf.size) {
                r.makeBuffer(&r.decal_buf, need * 2) catch break :decal;
                r.decal_fill = std.math.maxInt(usize);
            }
            // The fill goes into the buffer only when it changes.
            if (frame.decal_gen != r.decal_gen or r.decal_fill != frame.decals.len) {
                @memcpy(r.decal_buf.map.?[0..fill.len], fill);
                r.decal_gen = frame.decal_gen;
                r.decal_fill = frame.decals.len;
            }
            @memcpy(r.decal_buf.map.?[fill.len..need], edges);
            use(cmd, r.decal_pipeline, false);
            setPush(cmd, &frame.sign);
            bindVertices(cmd, &r.decal_buf, @sizeOf(BedVertex));
            cmd.DrawInstanced(@intCast(frame.decals.len + frame.decal_edges.len), 1, 0, 0);
        }
        if (frame.head.len > 0 and r.instances.res != null and r.box_index_count > 0) {
            const used = @min(frame.extras.len, max_extras);
            const head = frame.head[0..@min(frame.head.len, max_extras - used)];
            const off = (@as(usize, r.instance_count) + used) * @sizeOf(Instance);
            const hb = std.mem.sliceAsBytes(head);
            @memcpy(r.instances.map.?[off .. off + hb.len], hb);
            // Blended, with no depth write; params.w = 3 in the shader.
            var see = frame.box;
            see.params[2] = 0;
            see.params[3] = 3;
            use(cmd, r.ghost_pipeline, false);
            setPush(cmd, &see);
            r.bindBeads(cmd, &r.instances);
            drawIndexed(cmd, r.box_index_count, @intCast(head.len), 0, r.instance_count + @as(u32, @intCast(used)));
        }
    }
};
