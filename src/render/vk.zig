//! The Vulkan backend of the renderer.
//!
//! It draws the toolpath boxes, the bed grid, and the bed model into a window surface that
//! the shell gives (a Wayland surface or an X11 window on Linux). The scene
//! logic (which boxes, the camera) is in view.zig: this file only talks to
//! the GPU.
//!
//! Choices, and why:
//!
//! - No link-time dependency on Vulkan. The code loads the loader
//!   (libvulkan.so.1) at run time and gets each function with
//!   vkGetInstanceProcAddr and vkGetDeviceProcAddr. A program that never
//!   opens a view does not need Vulkan at all. The function tables are
//!   structs whose field names are the function names; `loadFns` fills them
//!   with comptime reflection.
//! - The vendored Khronos headers give the types. No VK_USE_PLATFORM_*
//!   macro is defined, because those pull in the X11 and Wayland headers.
//!   This file declares the two surface create-info structs that it needs.
//! - Push constants for all data of a draw (a matrix and three vectors),
//!   and no uniform buffers. The texture of the bed model is the one
//!   descriptor set: one image and one sampler.
//! - Host-visible, coherent buffers for the boxes and the grid: the CPU
//!   writes them directly, with no staging copy.
//! - One frame in flight. The view draws on demand (after a change), not at
//!   a fixed rate, so the simple form is enough.
//! - An offscreen renderer (a printer screen with no window system) draws
//!   into an image that it owns, and copies each frame to a host buffer
//!   that the host reads. It loads no surface or swapchain extension.
//! - A print view offscreen keeps the finished layers in a cached image
//!   (color and depth). A frame adds the new finished beads to it, copies
//!   it, and draws only the top layer and the nozzle over the copy. A new
//!   camera or new colors draw the cache again. See `recordCached`.
//!
//! The structure follows the Vulkan backend of charttable (same author, MIT
//! license, see docs/references/libraries.md): run-time loading, a surface from the shell,
//! a swapchain sized by the host because a Wayland surface has no size of
//! its own, and a UNORM swapchain format because the colors are already in
//! sRGB.

const std = @import("std");
const builtin = @import("builtin");
pub const c = @cImport({
    @cInclude("vulkan/vulkan.h");
});

pub const Error = error{
    NoVulkan,
    NoDevice,
    VulkanFailed,
    SurfaceFailed,
    OutOfMemory,
    /// No image is free now (the compositor holds them): the frame is
    /// skipped, and the shell draws again a moment later.
    FrameBusy,
};

/// The window surface that the shell gives, or an image that the
/// renderer owns (`offscreen`): the host reads each frame with `read`.
pub const Surface = union(enum) {
    wayland: struct { display: *anyopaque, surface: *anyopaque },
    xlib: struct { display: *anyopaque, window: u64 },
    /// `bgra`: the image has the bytes in B, G, R, A order (the order of
    /// a 32-bit Linux framebuffer); else R, G, B, A.
    offscreen: struct { bgra: bool = false },
};

const frame_mod = @import("frame.zig");
pub const Instance = frame_mod.Instance;
pub const max_extras = frame_mod.max_extras;
pub const Push = frame_mod.Push;
pub const Draw = frame_mod.Draw;
pub const PlateFrame = frame_mod.PlateFrame;

/// A sampled image: the texture of the bed model, or the image of the
/// signs.
const Texture = struct {
    image: c.VkImage = null,
    mem: c.VkDeviceMemory = null,
    view: c.VkImageView = null,
};

/// The bead buffer of another plate of the row (see Frame.plates), by its
/// slot: uploaded again when the generation of the plate changes.
const PlateSlot = struct {
    buf: Buffer = .{},
    gen: u32 = 0,
    used: bool = false,
};
const max_plate_slots = 64;

// ---------------------------------------------------------------------------
// Function tables

const Global = struct {
    vkCreateInstance: c.PFN_vkCreateInstance,
    vkEnumerateInstanceExtensionProperties: c.PFN_vkEnumerateInstanceExtensionProperties,
};

const Instance_ = struct {
    vkDestroyInstance: c.PFN_vkDestroyInstance,
    vkEnumeratePhysicalDevices: c.PFN_vkEnumeratePhysicalDevices,
    vkGetPhysicalDeviceProperties: c.PFN_vkGetPhysicalDeviceProperties,
    vkGetPhysicalDeviceQueueFamilyProperties: c.PFN_vkGetPhysicalDeviceQueueFamilyProperties,
    vkGetPhysicalDeviceMemoryProperties: c.PFN_vkGetPhysicalDeviceMemoryProperties,
    vkGetPhysicalDeviceSurfaceSupportKHR: c.PFN_vkGetPhysicalDeviceSurfaceSupportKHR,
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR: c.PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR,
    vkGetPhysicalDeviceSurfaceFormatsKHR: c.PFN_vkGetPhysicalDeviceSurfaceFormatsKHR,
    vkGetPhysicalDeviceSurfacePresentModesKHR: c.PFN_vkGetPhysicalDeviceSurfacePresentModesKHR,
    vkDestroySurfaceKHR: c.PFN_vkDestroySurfaceKHR,
    vkCreateDevice: c.PFN_vkCreateDevice,
    vkGetDeviceProcAddr: c.PFN_vkGetDeviceProcAddr,
};

const Device = struct {
    vkDestroyDevice: c.PFN_vkDestroyDevice,
    vkGetDeviceQueue: c.PFN_vkGetDeviceQueue,
    vkDeviceWaitIdle: c.PFN_vkDeviceWaitIdle,
    vkCreateSwapchainKHR: c.PFN_vkCreateSwapchainKHR,
    vkDestroySwapchainKHR: c.PFN_vkDestroySwapchainKHR,
    vkGetSwapchainImagesKHR: c.PFN_vkGetSwapchainImagesKHR,
    vkAcquireNextImageKHR: c.PFN_vkAcquireNextImageKHR,
    vkQueuePresentKHR: c.PFN_vkQueuePresentKHR,
    vkQueueSubmit: c.PFN_vkQueueSubmit,
    vkCreateImageView: c.PFN_vkCreateImageView,
    vkDestroyImageView: c.PFN_vkDestroyImageView,
    vkCreateImage: c.PFN_vkCreateImage,
    vkDestroyImage: c.PFN_vkDestroyImage,
    vkGetImageMemoryRequirements: c.PFN_vkGetImageMemoryRequirements,
    vkBindImageMemory: c.PFN_vkBindImageMemory,
    vkCreateBuffer: c.PFN_vkCreateBuffer,
    vkDestroyBuffer: c.PFN_vkDestroyBuffer,
    vkGetBufferMemoryRequirements: c.PFN_vkGetBufferMemoryRequirements,
    vkBindBufferMemory: c.PFN_vkBindBufferMemory,
    vkAllocateMemory: c.PFN_vkAllocateMemory,
    vkFreeMemory: c.PFN_vkFreeMemory,
    vkMapMemory: c.PFN_vkMapMemory,
    vkCreateRenderPass: c.PFN_vkCreateRenderPass,
    vkDestroyRenderPass: c.PFN_vkDestroyRenderPass,
    vkCreateFramebuffer: c.PFN_vkCreateFramebuffer,
    vkDestroyFramebuffer: c.PFN_vkDestroyFramebuffer,
    vkCreateShaderModule: c.PFN_vkCreateShaderModule,
    vkDestroyShaderModule: c.PFN_vkDestroyShaderModule,
    vkCreatePipelineLayout: c.PFN_vkCreatePipelineLayout,
    vkDestroyPipelineLayout: c.PFN_vkDestroyPipelineLayout,
    vkCreateGraphicsPipelines: c.PFN_vkCreateGraphicsPipelines,
    vkDestroyPipeline: c.PFN_vkDestroyPipeline,
    vkCreateCommandPool: c.PFN_vkCreateCommandPool,
    vkDestroyCommandPool: c.PFN_vkDestroyCommandPool,
    vkAllocateCommandBuffers: c.PFN_vkAllocateCommandBuffers,
    vkBeginCommandBuffer: c.PFN_vkBeginCommandBuffer,
    vkEndCommandBuffer: c.PFN_vkEndCommandBuffer,
    vkResetCommandBuffer: c.PFN_vkResetCommandBuffer,
    vkCmdBeginRenderPass: c.PFN_vkCmdBeginRenderPass,
    vkCmdEndRenderPass: c.PFN_vkCmdEndRenderPass,
    vkCmdBindPipeline: c.PFN_vkCmdBindPipeline,
    vkCmdBindVertexBuffers: c.PFN_vkCmdBindVertexBuffers,
    vkCmdBindIndexBuffer: c.PFN_vkCmdBindIndexBuffer,
    vkCmdDraw: c.PFN_vkCmdDraw,
    vkCmdDrawIndexed: c.PFN_vkCmdDrawIndexed,
    vkCmdPushConstants: c.PFN_vkCmdPushConstants,
    vkCmdSetViewport: c.PFN_vkCmdSetViewport,
    vkCmdSetScissor: c.PFN_vkCmdSetScissor,
    vkCmdPipelineBarrier: c.PFN_vkCmdPipelineBarrier,
    vkCmdCopyBufferToImage: c.PFN_vkCmdCopyBufferToImage,
    vkCmdCopyImageToBuffer: c.PFN_vkCmdCopyImageToBuffer,
    vkCmdCopyImage: c.PFN_vkCmdCopyImage,
    vkCmdBindDescriptorSets: c.PFN_vkCmdBindDescriptorSets,
    vkCreateSampler: c.PFN_vkCreateSampler,
    vkDestroySampler: c.PFN_vkDestroySampler,
    vkCreateDescriptorSetLayout: c.PFN_vkCreateDescriptorSetLayout,
    vkDestroyDescriptorSetLayout: c.PFN_vkDestroyDescriptorSetLayout,
    vkCreateDescriptorPool: c.PFN_vkCreateDescriptorPool,
    vkDestroyDescriptorPool: c.PFN_vkDestroyDescriptorPool,
    vkAllocateDescriptorSets: c.PFN_vkAllocateDescriptorSets,
    vkUpdateDescriptorSets: c.PFN_vkUpdateDescriptorSets,
    vkCreateSemaphore: c.PFN_vkCreateSemaphore,
    vkDestroySemaphore: c.PFN_vkDestroySemaphore,
    vkCreateFence: c.PFN_vkCreateFence,
    vkDestroyFence: c.PFN_vkDestroyFence,
    vkWaitForFences: c.PFN_vkWaitForFences,
    vkResetFences: c.PFN_vkResetFences,
};

/// Fills a function table: each field name is a Vulkan function name.
/// The functions of the surface and swapchain extensions (a name that
/// ends in KHR) can be null: an offscreen renderer does not load them.
fn loadFns(comptime T: type, getter: anytype, handle: anytype) Error!T {
    var out: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        const p = getter(handle, f.name ++ "");
        if (p == null and !comptime std.mem.endsWith(u8, f.name, "KHR")) return error.NoVulkan;
        @field(out, f.name) = @ptrCast(p);
    }
    return out;
}

fn check(r: c.VkResult) Error!void {
    if (r != c.VK_SUCCESS) return error.VulkanFailed;
}

// The two surface create-info structs (see the file comment).
const WaylandSurfaceCreateInfo = extern struct {
    sType: c.VkStructureType = 1000006000, // VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    display: *anyopaque,
    surface: *anyopaque,
};
const PfnCreateWaylandSurface = *const fn (c.VkInstance, *const WaylandSurfaceCreateInfo, ?*const anyopaque, *c.VkSurfaceKHR) callconv(.c) c.VkResult;

const XlibSurfaceCreateInfo = extern struct {
    sType: c.VkStructureType = 1000004000, // VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    dpy: *anyopaque,
    window: c_ulong,
};
const PfnCreateXlibSurface = *const fn (c.VkInstance, *const XlibSurfaceCreateInfo, ?*const anyopaque, *c.VkSurfaceKHR) callconv(.c) c.VkResult;

// Precompiled SPIR-V (tools/shaders.sh). @embedFile gives no alignment,
// and vkCreateShaderModule wants 4-byte aligned code, so the bytes are
// copied to u32 words at comptime.
fn spvWords(comptime raw: []const u8) []const u32 {
    if (raw.len % 4 != 0) @compileError("SPIR-V length is not a multiple of 4");
    comptime var words: [raw.len / 4]u32 = undefined;
    comptime @memcpy(std.mem.sliceAsBytes(words[0..]), raw);
    const final = words;
    return &final;
}
const box_vert = spvWords(@embedFile("shaders/box.vert.spv"));
const box_frag = spvWords(@embedFile("shaders/box.frag.spv"));
const grid_vert = spvWords(@embedFile("shaders/grid.vert.spv"));
const grid_frag = spvWords(@embedFile("shaders/grid.frag.spv"));
const bed_vert = spvWords(@embedFile("shaders/bed.vert.spv"));
const bed_frag = spvWords(@embedFile("shaders/bed.frag.spv"));
const sign_frag = spvWords(@embedFile("shaders/sign.frag.spv"));
const decal_frag = spvWords(@embedFile("shaders/decal.frag.spv"));

const BedVertex = @import("../bed.zig").Vertex;
const BedImage = @import("../bed.zig").Image;

const depth_format = c.VK_FORMAT_D32_SFLOAT;

const Buffer = struct {
    buf: c.VkBuffer = null,
    mem: c.VkDeviceMemory = null,
    map: ?[*]u8 = null,
    size: usize = 0,
};

const max_images = 8;

/// The dependencies of the passes of an offscreen renderer: a pass waits
/// for the copies before it (into or out of its images) and for the
/// passes before it, and a copy after it waits for the pass (and for the
/// layout change at its end).
const cache_deps = [2]c.VkSubpassDependency{ cache_dep, .{
    .srcSubpass = 0,
    .dstSubpass = c.VK_SUBPASS_EXTERNAL,
    .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | c.VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
    .dstStageMask = c.VK_PIPELINE_STAGE_TRANSFER_BIT,
    .srcAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
    .dstAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT | c.VK_ACCESS_TRANSFER_WRITE_BIT,
} };
const cache_dep: c.VkSubpassDependency = .{
    .srcSubpass = c.VK_SUBPASS_EXTERNAL,
    .dstSubpass = 0,
    .srcStageMask = c.VK_PIPELINE_STAGE_TRANSFER_BIT | c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | c.VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
    .dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT | c.VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
    .srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT | c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
    .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT | c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
};

/// What the cached image of a print view depends on.
const CacheKey = struct {
    base: Push,
    grid: Push,
    bed: Push,
    clear: [3]f32,
    first: u32,
    grid_vertices: u32,
    bed_vertices: u32,
};

pub const Renderer = struct {
    lib: std.DynLib,
    g: Global,
    i: Instance_,
    d: Device,
    instance: c.VkInstance,
    surface: c.VkSurfaceKHR,
    phys: c.VkPhysicalDevice,
    device: c.VkDevice,
    queue: c.VkQueue,
    queue_family: u32,
    mem_props: c.VkPhysicalDeviceMemoryProperties,

    format: c.VkSurfaceFormatKHR,
    render_pass: c.VkRenderPass,
    layout: c.VkPipelineLayout,
    box_pipeline: c.VkPipeline,
    /// The beads out of a focus: blended, with no depth write, so they do
    /// not hide the beads in focus behind them.
    ghost_pipeline: c.VkPipeline = null,
    grid_pipeline: c.VkPipeline,
    /// The bed model: blended (its parts over the plate are see-through),
    /// with a depth bias, so the grid lines at z = 0 stay in front of the
    /// flat bed.
    bed_pipeline: c.VkPipeline = null,
    bed_layout: c.VkPipelineLayout = null,
    bed_set_layout: c.VkDescriptorSetLayout = null,
    desc_pool: c.VkDescriptorPool = null,
    bed_set: c.VkDescriptorSet = null,
    sampler: c.VkSampler = null,
    bed: Buffer = .{},
    bed_count: u32 = 0,
    tex: Texture = .{},
    /// The signs of the plates (Frame.signs): blended, with no depth
    /// write, with the image of the signs in their own descriptor set.
    sign_pipeline: c.VkPipeline = null,
    sign_set: c.VkDescriptorSet = null,
    sign_tex: Texture = .{},
    sign_buf: Buffer = .{},
    /// The decals of the labels (Frame.decals): blended, with no depth
    /// write, and a depth bias toward the camera. The buffer has the fill
    /// of generation `decal_gen` (decal_fill vertices), then the outlines
    /// of the frame.
    decal_pipeline: c.VkPipeline = null,
    decal_buf: Buffer = .{},
    decal_gen: u32 = 0,
    decal_fill: usize = 0,
    pool: c.VkCommandPool,
    cmd: c.VkCommandBuffer,
    acquired: c.VkSemaphore,
    fence: c.VkFence,

    swapchain: c.VkSwapchainKHR = null,
    extent: c.VkExtent2D = .{ .width = 0, .height = 0 },
    image_count: u32 = 0,
    images: [max_images]c.VkImage = undefined,
    views: [max_images]c.VkImageView = undefined,
    framebuffers: [max_images]c.VkFramebuffer = undefined,
    rendered: [max_images]c.VkSemaphore = undefined,
    depth_image: c.VkImage = null,
    depth_mem: c.VkDeviceMemory = null,
    depth_view: c.VkImageView = null,
    want_width: u32,
    want_height: u32,
    stale: bool = true,

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
    samples: c.VkSampleCountFlagBits = c.VK_SAMPLE_COUNT_1_BIT,
    msaa_image: c.VkImage = null,
    msaa_mem: c.VkDeviceMemory = null,
    msaa_view: c.VkImageView = null,
    instances: Buffer = .{},
    /// The instance buffer of the next scene (see `beginInstances`): a
    /// thread copies the beads into it while the frames draw the old
    /// scene. `next_until` is the last frame that can read it (it was the
    /// instance buffer before), and `retired` a buffer that frames can
    /// still read until frame `retired_until`.
    next_instances: Buffer = .{},
    next_until: u64 = 0,
    retired: Buffer = .{},
    retired_until: u64 = 0,
    upload: ?*Upload = null,
    /// The frames sent to the GPU, and the frames that the GPU is done
    /// with (the fence was signaled after them).
    frames_sent: u64 = 0,
    frames_done: u64 = 0,
    grid: Buffer = .{},
    /// The other plates of the row: their bead buffers, and the grid
    /// lines of their beds (Frame.plate_grid) with its generation.
    plate_slots: [max_plate_slots]PlateSlot = [_]PlateSlot{.{}} ** max_plate_slots,
    plate_grid: Buffer = .{},
    plate_grid_gen: u32 = 0,

    /// The offscreen target (Surface.offscreen): the color image, its
    /// framebuffer, and a host buffer that each frame copies into.
    offscreen: bool = false,
    target_image: c.VkImage = null,
    target_mem: c.VkDeviceMemory = null,
    target_view: c.VkImageView = null,
    target_fb: c.VkFramebuffer = null,
    readback: Buffer = .{},
    /// A frame was drawn and its copy is not yet read.
    drawn: bool = false,
    /// The cache of a print view (see Frame.cached): images of the
    /// color and the depth of the finished layers, the passes that clear
    /// and add to them, and the pass that draws the rest over a copy.
    cache_color: c.VkImage = null,
    cache_color_mem: c.VkDeviceMemory = null,
    cache_color_view: c.VkImageView = null,
    cache_depth: c.VkImage = null,
    cache_depth_mem: c.VkDeviceMemory = null,
    cache_depth_view: c.VkImageView = null,
    cache_fb: c.VkFramebuffer = null,
    cache_clear_pass: c.VkRenderPass = null,
    cache_add_pass: c.VkRenderPass = null,
    over_pass: c.VkRenderPass = null,
    /// The beads in the cache (its end), and the frame that drew it: a
    /// change of the camera or the colors draws it again.
    cache_end: u32 = 0,
    cache_valid: bool = false,
    cache_key: CacheKey = undefined,

    pub fn init(surface: Surface, width: u32, height: u32) Error!*Renderer {
        var lib = std.DynLib.open("libvulkan.so.1") catch return error.NoVulkan;
        errdefer lib.close();
        const get = lib.lookup(c.PFN_vkGetInstanceProcAddr, "vkGetInstanceProcAddr") orelse return error.NoVulkan;
        const gipa = get orelse return error.NoVulkan;
        const g = try loadFns(Global, gipa, @as(c.VkInstance, null));

        // The instance, with the surface extension of the window system.
        const offscreen = surface == .offscreen;
        const surface_ext: [*:0]const u8 = switch (surface) {
            .wayland => "VK_KHR_wayland_surface",
            .xlib => "VK_KHR_xlib_surface",
            .offscreen => "",
        };
        const exts = [_][*:0]const u8{ "VK_KHR_surface", surface_ext };
        const app_info: c.VkApplicationInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pApplicationName = "zslice",
            .apiVersion = c.VK_API_VERSION_1_1,
        };
        var instance: c.VkInstance = null;
        try check(g.vkCreateInstance.?(&.{
            .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pApplicationInfo = &app_info,
            .enabledExtensionCount = if (offscreen) 0 else exts.len,
            .ppEnabledExtensionNames = @ptrCast(&exts),
        }, null, &instance));
        const i = loadFns(Instance_, gipa, instance) catch |e| {
            return e;
        };
        errdefer i.vkDestroyInstance.?(instance, null);

        // The surface.
        var vk_surface: c.VkSurfaceKHR = null;
        switch (surface) {
            .wayland => |w| {
                const f: PfnCreateWaylandSurface = @ptrCast(gipa(instance, "vkCreateWaylandSurfaceKHR") orelse return error.SurfaceFailed);
                if (f(instance, &.{ .display = w.display, .surface = w.surface }, null, &vk_surface) != c.VK_SUCCESS) return error.SurfaceFailed;
            },
            .xlib => |x| {
                const f: PfnCreateXlibSurface = @ptrCast(gipa(instance, "vkCreateXlibSurfaceKHR") orelse return error.SurfaceFailed);
                if (f(instance, &.{ .dpy = x.display, .window = @intCast(x.window) }, null, &vk_surface) != c.VK_SUCCESS) return error.SurfaceFailed;
            },
            .offscreen => {},
        }
        errdefer if (vk_surface != null) i.vkDestroySurfaceKHR.?(instance, vk_surface, null);

        // A device with a queue that draws and presents to this surface:
        // a discrete GPU first (a laptop or a desktop with two GPUs can
        // list the integrated GPU first), else the first one.
        var count: u32 = 0;
        try check(i.vkEnumeratePhysicalDevices.?(instance, &count, null));
        var devs: [16]c.VkPhysicalDevice = undefined;
        count = @min(count, devs.len);
        try check(i.vkEnumeratePhysicalDevices.?(instance, &count, &devs));
        var phys: c.VkPhysicalDevice = null;
        var family: u32 = 0;
        var phys_discrete = false;
        outer: for (devs[0..count]) |pd| {
            var dp: c.VkPhysicalDeviceProperties = undefined;
            i.vkGetPhysicalDeviceProperties.?(pd, &dp);
            const discrete = dp.deviceType == c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU;
            if (phys != null and (phys_discrete or !discrete)) continue;
            var qn: u32 = 0;
            i.vkGetPhysicalDeviceQueueFamilyProperties.?(pd, &qn, null);
            var qs: [16]c.VkQueueFamilyProperties = undefined;
            qn = @min(qn, qs.len);
            i.vkGetPhysicalDeviceQueueFamilyProperties.?(pd, &qn, &qs);
            for (qs[0..qn], 0..) |q, qi| {
                if (q.queueFlags & c.VK_QUEUE_GRAPHICS_BIT == 0) continue;
                if (!offscreen) {
                    var present: c.VkBool32 = 0;
                    _ = i.vkGetPhysicalDeviceSurfaceSupportKHR.?(pd, @intCast(qi), vk_surface, &present);
                    if (present == 0) continue;
                }
                phys = pd;
                family = @intCast(qi);
                phys_discrete = discrete;
                continue :outer;
            }
        }
        if (phys == null) return error.NoDevice;
        {
            var dp: c.VkPhysicalDeviceProperties = undefined;
            i.vkGetPhysicalDeviceProperties.?(phys, &dp);
            std.log.info("GPU: {s}", .{std.mem.sliceTo(&dp.deviceName, 0)});
        }

        const priority: f32 = 1;
        const dev_exts = [_][*:0]const u8{"VK_KHR_swapchain"};
        var device: c.VkDevice = null;
        try check(i.vkCreateDevice.?(phys, &.{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &.{
                .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                .queueFamilyIndex = family,
                .queueCount = 1,
                .pQueuePriorities = &priority,
            },
            .enabledExtensionCount = if (offscreen) 0 else dev_exts.len,
            .ppEnabledExtensionNames = @ptrCast(&dev_exts),
        }, null, &device));
        const d = loadFns(Device, i.vkGetDeviceProcAddr.?, device) catch |e| return e;
        errdefer d.vkDestroyDevice.?(device, null);

        const r = std.heap.c_allocator.create(Renderer) catch return error.OutOfMemory;
        r.* = .{
            .lib = lib,
            .g = g,
            .i = i,
            .d = d,
            .instance = instance,
            .surface = vk_surface,
            .phys = phys,
            .device = device,
            .queue = null,
            .queue_family = family,
            .mem_props = undefined,
            .format = undefined,
            .render_pass = null,
            .layout = null,
            .box_pipeline = null,
            .grid_pipeline = null,
            .pool = null,
            .cmd = null,
            .acquired = null,
            .fence = null,
            .want_width = @max(width, 1),
            .want_height = @max(height, 1),
            .offscreen = offscreen,
        };
        if (offscreen) r.format = .{
            .format = if (surface.offscreen.bgra) c.VK_FORMAT_B8G8R8A8_UNORM else c.VK_FORMAT_R8G8B8A8_UNORM,
            .colorSpace = c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR,
        };
        d.vkGetDeviceQueue.?(device, family, 0, &r.queue);
        i.vkGetPhysicalDeviceMemoryProperties.?(phys, &r.mem_props);
        r.setup() catch |e| {
            r.deinit();
            return e;
        };
        return r;
    }

    /// The parts that do not depend on the window size.
    fn setup(r: *Renderer) Error!void {
        if (!r.offscreen) r.format = try r.pickFormat();
        // 4x multisampling if the device has it for color and depth.
        var props: c.VkPhysicalDeviceProperties = undefined;
        r.i.vkGetPhysicalDeviceProperties.?(r.phys, &props);
        const counts = props.limits.framebufferColorSampleCounts & props.limits.framebufferDepthSampleCounts;
        r.samples = if (counts & c.VK_SAMPLE_COUNT_4_BIT != 0) c.VK_SAMPLE_COUNT_4_BIT else c.VK_SAMPLE_COUNT_1_BIT;
        try r.makeRenderPass();
        if (r.offscreen) try r.makeCachePasses();
        try r.makePipelines();
        try check(r.d.vkCreateCommandPool.?(r.device, &.{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = r.queue_family,
        }, null, &r.pool));
        try check(r.d.vkAllocateCommandBuffers.?(r.device, &.{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = r.pool,
            .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        }, &r.cmd));
        try check(r.d.vkCreateSemaphore.?(r.device, &.{ .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO }, null, &r.acquired));
        try check(r.d.vkCreateFence.?(r.device, &.{ .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, .flags = c.VK_FENCE_CREATE_SIGNALED_BIT }, null, &r.fence));
    }

    pub fn deinit(r: *Renderer) void {
        const d = r.d;
        r.cancelInstances();
        if (r.device != null) _ = d.vkDeviceWaitIdle.?(r.device);
        r.destroySwapchain();
        r.destroyTarget();
        if (r.swapchain != null) d.vkDestroySwapchainKHR.?(r.device, r.swapchain, null);
        for ([_]*Buffer{ &r.box_mesh, &r.box_index, &r.instances, &r.next_instances, &r.retired, &r.grid, &r.bed, &r.readback, &r.plate_grid }) |b| r.freeBuffer(b);
        for (&r.plate_slots) |*sl| r.freeBuffer(&sl.buf);
        r.freeTexture(&r.tex);
        r.freeTexture(&r.sign_tex);
        r.freeBuffer(&r.sign_buf);
        r.freeBuffer(&r.decal_buf);
        if (r.sign_pipeline != null) d.vkDestroyPipeline.?(r.device, r.sign_pipeline, null);
        if (r.decal_pipeline != null) d.vkDestroyPipeline.?(r.device, r.decal_pipeline, null);
        if (r.sampler != null) d.vkDestroySampler.?(r.device, r.sampler, null);
        if (r.desc_pool != null) d.vkDestroyDescriptorPool.?(r.device, r.desc_pool, null);
        if (r.bed_pipeline != null) d.vkDestroyPipeline.?(r.device, r.bed_pipeline, null);
        if (r.bed_layout != null) d.vkDestroyPipelineLayout.?(r.device, r.bed_layout, null);
        if (r.bed_set_layout != null) d.vkDestroyDescriptorSetLayout.?(r.device, r.bed_set_layout, null);
        if (r.fence != null) d.vkDestroyFence.?(r.device, r.fence, null);
        if (r.acquired != null) d.vkDestroySemaphore.?(r.device, r.acquired, null);
        if (r.pool != null) d.vkDestroyCommandPool.?(r.device, r.pool, null);
        if (r.box_pipeline != null) d.vkDestroyPipeline.?(r.device, r.box_pipeline, null);
        if (r.ghost_pipeline != null) d.vkDestroyPipeline.?(r.device, r.ghost_pipeline, null);
        if (r.grid_pipeline != null) d.vkDestroyPipeline.?(r.device, r.grid_pipeline, null);
        if (r.layout != null) d.vkDestroyPipelineLayout.?(r.device, r.layout, null);
        if (r.render_pass != null) d.vkDestroyRenderPass.?(r.device, r.render_pass, null);
        for ([_]c.VkRenderPass{ r.cache_clear_pass, r.cache_add_pass, r.over_pass }) |p| if (p != null) d.vkDestroyRenderPass.?(r.device, p, null);
        d.vkDestroyDevice.?(r.device, null);
        if (r.surface != null) r.i.vkDestroySurfaceKHR.?(r.instance, r.surface, null);
        r.i.vkDestroyInstance.?(r.instance, null);
        r.lib.close();
        std.heap.c_allocator.destroy(r);
    }

    /// The size of the drawing in pixels. The swapchain is made again
    /// before the next frame.
    pub fn resize(r: *Renderer, width: u32, height: u32) void {
        if (width == r.want_width and height == r.want_height) return;
        r.want_width = @max(width, 1);
        r.want_height = @max(height, 1);
        r.stale = true;
    }

    /// MAILBOX if the driver has it: a present never waits for the
    /// compositor, so the UI thread never blocks (with FIFO, a window that
    /// does not repaint, for example under a popup, holds all images).
    /// Else FIFO, which each driver has.
    fn pickPresentMode(r: *Renderer) c.VkPresentModeKHR {
        var n: u32 = 0;
        const get = r.i.vkGetPhysicalDeviceSurfacePresentModesKHR orelse return c.VK_PRESENT_MODE_FIFO_KHR;
        if (get(r.phys, r.surface, &n, null) != c.VK_SUCCESS) return c.VK_PRESENT_MODE_FIFO_KHR;
        var modes: [16]c.VkPresentModeKHR = undefined;
        n = @min(n, modes.len);
        if (get(r.phys, r.surface, &n, &modes) != c.VK_SUCCESS) return c.VK_PRESENT_MODE_FIFO_KHR;
        // ZSLICE_PRESENT=fifo or immediate picks the mode, to find the cause
        // of a view that does not show on a compositor (a test aid).
        if (std.c.getenv("ZSLICE_PRESENT")) |e| {
            const want: c.VkPresentModeKHR = if (std.mem.eql(u8, std.mem.span(e), "immediate")) c.VK_PRESENT_MODE_IMMEDIATE_KHR else c.VK_PRESENT_MODE_FIFO_KHR;
            for (modes[0..n]) |m| if (m == want) return m;
            return c.VK_PRESENT_MODE_FIFO_KHR;
        }
        for (modes[0..n]) |m| if (m == c.VK_PRESENT_MODE_MAILBOX_KHR) return m;
        return c.VK_PRESENT_MODE_FIFO_KHR;
    }

    fn pickFormat(r: *Renderer) Error!c.VkSurfaceFormatKHR {
        var n: u32 = 0;
        try check(r.i.vkGetPhysicalDeviceSurfaceFormatsKHR.?(r.phys, r.surface, &n, null));
        var fs: [64]c.VkSurfaceFormatKHR = undefined;
        n = @min(n, fs.len);
        try check(r.i.vkGetPhysicalDeviceSurfaceFormatsKHR.?(r.phys, r.surface, &n, &fs));
        if (n == 0) return error.SurfaceFailed;
        // A UNORM format first: the colors are already sRGB values, and an
        // _SRGB format would encode them a second time.
        for (fs[0..n]) |f| {
            if (f.format == c.VK_FORMAT_B8G8R8A8_UNORM or f.format == c.VK_FORMAT_R8G8B8A8_UNORM) return f;
        }
        return fs[0];
    }

    fn memoryType(r: *Renderer, bits: u32, flags: c.VkMemoryPropertyFlags) Error!u32 {
        for (0..r.mem_props.memoryTypeCount) |k| {
            const ok_bit = bits & (@as(u32, 1) << @intCast(k)) != 0;
            if (ok_bit and r.mem_props.memoryTypes[k].propertyFlags & flags == flags) return @intCast(k);
        }
        return error.VulkanFailed;
    }

    /// With multisampling: a multisampled color image (0) and depth (1),
    /// resolved into the swapchain image (2). Without: the swapchain image
    /// (0) and depth (1).
    fn makeRenderPass(r: *Renderer) Error!void {
        const msaa = r.samples != c.VK_SAMPLE_COUNT_1_BIT;
        const attachments = [_]c.VkAttachmentDescription{
            .{
                .format = r.format.format,
                .samples = r.samples,
                .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
                .storeOp = if (msaa) c.VK_ATTACHMENT_STORE_OP_DONT_CARE else c.VK_ATTACHMENT_STORE_OP_STORE,
                .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
                .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
                .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
                .finalLayout = if (msaa) c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL else r.outLayout(),
            },
            .{
                .format = depth_format,
                .samples = r.samples,
                .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
                .storeOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
                .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
                .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
                .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
                .finalLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
            },
            .{
                .format = r.format.format,
                .samples = c.VK_SAMPLE_COUNT_1_BIT,
                .loadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
                .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
                .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
                .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
                .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
                .finalLayout = r.outLayout(),
            },
        };
        const color_ref: c.VkAttachmentReference = .{ .attachment = 0, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
        const depth_ref: c.VkAttachmentReference = .{ .attachment = 1, .layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL };
        const resolve_ref: c.VkAttachmentReference = .{ .attachment = 2, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
        const subpass: c.VkSubpassDescription = .{
            .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS,
            .colorAttachmentCount = 1,
            .pColorAttachments = &color_ref,
            .pResolveAttachments = if (msaa) &resolve_ref else null,
            .pDepthStencilAttachment = &depth_ref,
        };
        // The color and depth writes wait for the image (from the acquire
        // semaphore) and for the depth reads of the frame before.
        const dep: c.VkSubpassDependency = .{
            .srcSubpass = c.VK_SUBPASS_EXTERNAL,
            .dstSubpass = 0,
            .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | c.VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
            .dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
            .srcAccessMask = c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
            .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
        };
        try check(r.d.vkCreateRenderPass.?(r.device, &.{
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
            .attachmentCount = if (msaa) 3 else 2,
            .pAttachments = &attachments,
            .subpassCount = 1,
            .pSubpasses = &subpass,
            // An offscreen renderer has the dependencies of the cache
            // passes: compatible passes need the same dependencies.
            .dependencyCount = if (r.offscreen) cache_deps.len else 1,
            .pDependencies = if (r.offscreen) &cache_deps else &dep,
        }, null, &r.render_pass));
    }

    /// The layout of the drawn image at the end of the pass: ready to
    /// present, or for an offscreen image ready to copy to the host.
    fn outLayout(r: *const Renderer) c.VkImageLayout {
        return if (r.offscreen) c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL else c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    }

    fn shader(r: *Renderer, code: []const u32) Error!c.VkShaderModule {
        var m: c.VkShaderModule = null;
        try check(r.d.vkCreateShaderModule.?(r.device, &.{
            .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .codeSize = code.len * 4,
            .pCode = code.ptr,
        }, null, &m));
        return m;
    }

    fn makePipelines(r: *Renderer) Error!void {
        const push_range: c.VkPushConstantRange = .{
            .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .offset = 0,
            .size = @sizeOf(Push),
        };
        try check(r.d.vkCreatePipelineLayout.?(r.device, &.{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pushConstantRangeCount = 1,
            .pPushConstantRanges = &push_range,
        }, null, &r.layout));

        const bv = try r.shader(box_vert);
        defer r.d.vkDestroyShaderModule.?(r.device, bv, null);
        const bf = try r.shader(box_frag);
        defer r.d.vkDestroyShaderModule.?(r.device, bf, null);
        const gv = try r.shader(grid_vert);
        defer r.d.vkDestroyShaderModule.?(r.device, gv, null);
        const gf = try r.shader(grid_frag);
        defer r.d.vkDestroyShaderModule.?(r.device, gf, null);

        const box_bindings = [_]c.VkVertexInputBindingDescription{
            .{ .binding = 0, .stride = 16, .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX },
            .{ .binding = 1, .stride = @sizeOf(Instance), .inputRate = c.VK_VERTEX_INPUT_RATE_INSTANCE },
        };
        const box_attrs = [_]c.VkVertexInputAttributeDescription{
            .{ .location = 0, .binding = 0, .format = c.VK_FORMAT_R32G32B32A32_SFLOAT, .offset = 0 },
            .{ .location = 2, .binding = 1, .format = c.VK_FORMAT_R32G32B32A32_SFLOAT, .offset = @offsetOf(Instance, "ax") },
            .{ .location = 3, .binding = 1, .format = c.VK_FORMAT_R32G32B32_SFLOAT, .offset = @offsetOf(Instance, "z") },
            .{ .location = 4, .binding = 1, .format = c.VK_FORMAT_R8G8B8A8_UNORM, .offset = @offsetOf(Instance, "rgba") },
        };
        const grid_bindings = [_]c.VkVertexInputBindingDescription{
            .{ .binding = 0, .stride = 12, .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX },
        };
        const grid_attrs = [_]c.VkVertexInputAttributeDescription{
            .{ .location = 0, .binding = 0, .format = c.VK_FORMAT_R32G32B32_SFLOAT, .offset = 0 },
        };
        r.box_pipeline = try r.pipeline(bv, bf, &box_bindings, &box_attrs, c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, false, false, r.layout);
        r.ghost_pipeline = try r.pipeline(bv, bf, &box_bindings, &box_attrs, c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, true, false, r.layout);
        r.grid_pipeline = try r.pipeline(gv, gf, &grid_bindings, &grid_attrs, c.VK_PRIMITIVE_TOPOLOGY_LINE_LIST, false, false, r.layout);
        try r.makeBedPipeline(push_range);
    }

    /// The pipeline of the bed model, with its descriptor set (the
    /// texture), and the sampler.
    fn makeBedPipeline(r: *Renderer, push_range: c.VkPushConstantRange) Error!void {
        const d = r.d;
        const binding: c.VkDescriptorSetLayoutBinding = .{
            .binding = 0,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT,
        };
        try check(d.vkCreateDescriptorSetLayout.?(r.device, &.{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .bindingCount = 1,
            .pBindings = &binding,
        }, null, &r.bed_set_layout));
        try check(d.vkCreatePipelineLayout.?(r.device, &.{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .setLayoutCount = 1,
            .pSetLayouts = &r.bed_set_layout,
            .pushConstantRangeCount = 1,
            .pPushConstantRanges = &push_range,
        }, null, &r.bed_layout));
        // Two sets: the bed model, and the signs of the plates.
        const pool_size: c.VkDescriptorPoolSize = .{ .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 2 };
        try check(d.vkCreateDescriptorPool.?(r.device, &.{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .maxSets = 2,
            .poolSizeCount = 1,
            .pPoolSizes = &pool_size,
        }, null, &r.desc_pool));
        try check(d.vkAllocateDescriptorSets.?(r.device, &.{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .descriptorPool = r.desc_pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &r.bed_set_layout,
        }, &r.bed_set));
        try check(d.vkAllocateDescriptorSets.?(r.device, &.{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .descriptorPool = r.desc_pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &r.bed_set_layout,
        }, &r.sign_set));
        try check(d.vkCreateSampler.?(r.device, &.{
            .sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .magFilter = c.VK_FILTER_LINEAR,
            .minFilter = c.VK_FILTER_LINEAR,
            .mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_NEAREST,
            .addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .maxLod = 0,
        }, null, &r.sampler));
        const vs = try r.shader(bed_vert);
        defer d.vkDestroyShaderModule.?(r.device, vs, null);
        const fs = try r.shader(bed_frag);
        defer d.vkDestroyShaderModule.?(r.device, fs, null);
        const bindings = [_]c.VkVertexInputBindingDescription{
            .{ .binding = 0, .stride = @sizeOf(BedVertex), .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX },
        };
        const attrs = [_]c.VkVertexInputAttributeDescription{
            .{ .location = 0, .binding = 0, .format = c.VK_FORMAT_R32G32B32_SFLOAT, .offset = @offsetOf(BedVertex, "pos") },
            .{ .location = 1, .binding = 0, .format = c.VK_FORMAT_R32G32B32_SFLOAT, .offset = @offsetOf(BedVertex, "normal") },
            .{ .location = 2, .binding = 0, .format = c.VK_FORMAT_R32G32_SFLOAT, .offset = @offsetOf(BedVertex, "uv") },
        };
        r.bed_pipeline = try r.pipeline(vs, fs, &bindings, &attrs, c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, false, true, r.bed_layout);
        // The signs: the vertex shader of the bed, and their own fragment
        // shader. Blended with no depth write, as a ghost.
        const sf = try r.shader(sign_frag);
        defer d.vkDestroyShaderModule.?(r.device, sf, null);
        r.sign_pipeline = try r.pipeline(vs, sf, &bindings, &attrs, c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, true, false, r.bed_layout);
        // The decals: the vertex shader of the bed, a flat color, blended
        // with no depth write, and a depth bias toward the camera, so a
        // decal on a face stays in front of the beads of that face.
        const df = try r.shader(decal_frag);
        defer d.vkDestroyShaderModule.?(r.device, df, null);
        r.decal_pipeline = try r.pipelineBias(vs, df, &bindings, &attrs, c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, true, false, r.bed_layout, -2, -4);
    }

    fn pipeline(
        r: *Renderer,
        vs: c.VkShaderModule,
        fs: c.VkShaderModule,
        bindings: []const c.VkVertexInputBindingDescription,
        attrs: []const c.VkVertexInputAttributeDescription,
        topology: c.VkPrimitiveTopology,
        /// Blend with alpha, and no depth write.
        ghost: bool,
        /// The bed: blend with alpha, depth write, and a depth bias.
        bed: bool,
        layout: c.VkPipelineLayout,
    ) Error!c.VkPipeline {
        return r.pipelineBias(vs, fs, bindings, attrs, topology, ghost, bed, layout, if (bed) 4 else 0, if (bed) 2 else 0);
    }

    /// `pipeline` with a depth bias of its own (constant and slope; 0 and
    /// 0: none).
    fn pipelineBias(
        r: *Renderer,
        vs: c.VkShaderModule,
        fs: c.VkShaderModule,
        bindings: []const c.VkVertexInputBindingDescription,
        attrs: []const c.VkVertexInputAttributeDescription,
        topology: c.VkPrimitiveTopology,
        ghost: bool,
        bed: bool,
        layout: c.VkPipelineLayout,
        bias: f32,
        bias_slope: f32,
    ) Error!c.VkPipeline {
        const stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = vs, .pName = "main" },
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = fs, .pName = "main" },
        };
        const vertex_input: c.VkPipelineVertexInputStateCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .vertexBindingDescriptionCount = @intCast(bindings.len),
            .pVertexBindingDescriptions = bindings.ptr,
            .vertexAttributeDescriptionCount = @intCast(attrs.len),
            .pVertexAttributeDescriptions = attrs.ptr,
        };
        const assembly: c.VkPipelineInputAssemblyStateCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .topology = topology,
        };
        const viewport: c.VkPipelineViewportStateCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .viewportCount = 1,
            .scissorCount = 1,
        };
        const raster: c.VkPipelineRasterizationStateCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .polygonMode = c.VK_POLYGON_MODE_FILL,
            // The solid beads: a bead is a closed mesh, wound the same way,
            // so its back faces never show (as the web does, 23901eb). The
            // picture is the same; the GPU shades fewer pixels. The ghosts
            // show their back faces through their front.
            .cullMode = if (!ghost and !bed and topology == c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST) c.VK_CULL_MODE_BACK_BIT else c.VK_CULL_MODE_NONE,
            .frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE,
            .depthBiasEnable = if (bias != 0 or bias_slope != 0) c.VK_TRUE else c.VK_FALSE,
            .depthBiasConstantFactor = bias,
            .depthBiasSlopeFactor = bias_slope,
            .lineWidth = 1,
        };
        const multisample: c.VkPipelineMultisampleStateCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .rasterizationSamples = r.samples,
        };
        const depth: c.VkPipelineDepthStencilStateCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
            .depthTestEnable = c.VK_TRUE,
            .depthWriteEnable = if (ghost) c.VK_FALSE else c.VK_TRUE,
            .depthCompareOp = c.VK_COMPARE_OP_LESS_OR_EQUAL,
        };
        const blend_attachment: c.VkPipelineColorBlendAttachmentState = .{
            .colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT,
            .blendEnable = if (ghost or bed) c.VK_TRUE else c.VK_FALSE,
            .srcColorBlendFactor = c.VK_BLEND_FACTOR_SRC_ALPHA,
            .dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .colorBlendOp = c.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .alphaBlendOp = c.VK_BLEND_OP_ADD,
        };
        const blend: c.VkPipelineColorBlendStateCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .attachmentCount = 1,
            .pAttachments = &blend_attachment,
        };
        const dyn_states = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
        const dynamic: c.VkPipelineDynamicStateCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .dynamicStateCount = dyn_states.len,
            .pDynamicStates = &dyn_states,
        };
        var p: c.VkPipeline = null;
        try check(r.d.vkCreateGraphicsPipelines.?(r.device, null, 1, &.{
            .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .stageCount = stages.len,
            .pStages = &stages,
            .pVertexInputState = &vertex_input,
            .pInputAssemblyState = &assembly,
            .pViewportState = &viewport,
            .pRasterizationState = &raster,
            .pMultisampleState = &multisample,
            .pDepthStencilState = &depth,
            .pColorBlendState = &blend,
            .pDynamicState = &dynamic,
            .layout = layout,
            .renderPass = r.render_pass,
            .subpass = 0,
        }, null, &p));
        return p;
    }

    // ---- buffers ----

    fn makeBuffer(r: *Renderer, b: *Buffer, size: usize, usage: c.VkBufferUsageFlags) Error!void {
        r.freeBuffer(b);
        const n = @max(size, 16);
        try check(r.d.vkCreateBuffer.?(r.device, &.{
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .size = n,
            .usage = usage,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        }, null, &b.buf));
        var req: c.VkMemoryRequirements = undefined;
        r.d.vkGetBufferMemoryRequirements.?(r.device, b.buf, &req);
        // GPU memory that the CPU can write first: the GPU reads it each
        // frame, and on a discrete GPU host memory is across the bus. When
        // there is no such memory, or it is full, host memory.
        const host = c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        var allocated = false;
        if (r.memoryType(req.memoryTypeBits, host | c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) |t| {
            allocated = r.d.vkAllocateMemory.?(r.device, &.{
                .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                .allocationSize = req.size,
                .memoryTypeIndex = t,
            }, null, &b.mem) == c.VK_SUCCESS;
        } else |_| {}
        if (!allocated) try check(r.d.vkAllocateMemory.?(r.device, &.{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = req.size,
            .memoryTypeIndex = try r.memoryType(req.memoryTypeBits, host),
        }, null, &b.mem));
        try check(r.d.vkBindBufferMemory.?(r.device, b.buf, b.mem, 0));
        var ptr: ?*anyopaque = null;
        try check(r.d.vkMapMemory.?(r.device, b.mem, 0, n, 0, &ptr));
        b.map = @ptrCast(ptr);
        b.size = n;
    }

    fn freeBuffer(r: *Renderer, b: *Buffer) void {
        // Freeing the memory also unmaps it.
        if (b.buf != null) r.d.vkDestroyBuffer.?(r.device, b.buf, null);
        if (b.mem != null) r.d.vkFreeMemory.?(r.device, b.mem, null);
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

    const max_mesh_verts = 256;
    const max_mesh_index = 1024;

    fn uploadMesh(r: *Renderer) Error!void {
        r.cache_valid = false;
        _ = r.d.vkDeviceWaitIdle.?(r.device);
        const vb = std.mem.sliceAsBytes(r.mesh_verts[0..r.mesh_vert_count]);
        try r.makeBuffer(&r.box_mesh, vb.len, c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        @memcpy(r.box_mesh.map.?[0..vb.len], vb);
        const ib = std.mem.sliceAsBytes(r.mesh_index[0..r.mesh_index_count]);
        try r.makeBuffer(&r.box_index, ib.len, c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT);
        @memcpy(r.box_index.map.?[0..ib.len], ib);
    }

    /// Draws the beads of a frame: its draw list (the chunks in the view,
    /// each with its mesh level), or all beads box_first .. box_count
    /// with the full mesh for a frame with no list (a print view).
    /// True for a plate frame of another plate: the light beads of the
    /// active plate (flag_active, flag_part) are for the frame backend.
    fn otherPlate(pf: PlateFrame) bool {
        return pf.flags & (PlateFrame.flag_active | PlateFrame.flag_part) == 0 and pf.slot < max_plate_slots;
    }

    /// Uploads the bead buffer of each other plate whose generation
    /// changed, and the grid lines of their beds. Call it when the GPU is
    /// done with the frame before.
    fn syncPlates(r: *Renderer, frame: Frame) Error!void {
        for (frame.plates) |pf| {
            if (!otherPlate(pf)) continue;
            const sl = &r.plate_slots[pf.slot];
            if (sl.used and sl.gen == pf.gen) continue;
            const n = @as(usize, pf.instance_count) * @sizeOf(Instance);
            if (n > sl.buf.size or sl.buf.buf == null) try r.makeBuffer(&sl.buf, n, c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
            if (n > 0) {
                const src: [*]const u8 = @ptrFromInt(pf.instances);
                @memcpy(sl.buf.map.?[0..n], src[0..n]);
            }
            sl.gen = pf.gen;
            sl.used = true;
        }
        if (frame.plate_grid_gen != r.plate_grid_gen) {
            const bytes = std.mem.sliceAsBytes(frame.plate_grid);
            if (bytes.len > r.plate_grid.size or r.plate_grid.buf == null) try r.makeBuffer(&r.plate_grid, bytes.len, c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
            if (bytes.len > 0) @memcpy(r.plate_grid.map.?[0..bytes.len], bytes);
            r.plate_grid_gen = frame.plate_grid_gen;
        }
    }

    /// The beads of the other plates: each with its matrix and its fade
    /// (light.w), no highlight and no focus, and its draws. The box
    /// pipeline and the index buffer are bound; the instance buffer of the
    /// active plate is bound again after.
    fn drawOtherPlates(r: *Renderer, cmd: c.VkCommandBuffer, frame: Frame) void {
        const d = r.d;
        const stages = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT;
        var drew = false;
        for (frame.plates) |pf| {
            if (!otherPlate(pf) or pf.draws_count == 0) continue;
            const sl = &r.plate_slots[pf.slot];
            if (!sl.used or sl.buf.buf == null or pf.draws_first + pf.draws_count > frame.plate_draws.len) continue;
            var push = frame.box;
            push.mvp = pf.mvp;
            push.vec[3] = pf.fade;
            push.params[0] = 0;
            push.params[1] = 0;
            push.params[2] = 0;
            d.vkCmdPushConstants.?(cmd, r.layout, stages, 0, @sizeOf(Push), &push);
            const bufs = [_]c.VkBuffer{ r.box_mesh.buf, sl.buf.buf };
            const offs = [_]c.VkDeviceSize{ 0, 0 };
            d.vkCmdBindVertexBuffers.?(cmd, 0, 2, &bufs, &offs);
            r.drawList(cmd, frame.plate_draws[pf.draws_first .. pf.draws_first + pf.draws_count]);
            drew = true;
        }
        if (drew) {
            d.vkCmdPushConstants.?(cmd, r.layout, stages, 0, @sizeOf(Push), &frame.box);
            if (r.instances.buf != null) {
                const bufs = [_]c.VkBuffer{ r.box_mesh.buf, r.instances.buf };
                const offs = [_]c.VkDeviceSize{ 0, 0 };
                d.vkCmdBindVertexBuffers.?(cmd, 0, 2, &bufs, &offs);
            }
        }
    }

    fn drawBeads(r: *Renderer, cmd: c.VkCommandBuffer, frame: Frame) void {
        const d = r.d;
        if (!frame.culled) {
            const first = @min(frame.box_first, frame.box_count);
            d.vkCmdDrawIndexed.?(cmd, r.box_index_count, frame.box_count - first, 0, 0, first);
            return;
        }
        r.drawList(cmd, frame.draws);
    }

    /// Draws ranges of beads, each with its mesh level. The last ranges
    /// first: the top layers, so the depth test drops the hidden pixels of
    /// the layers under them early.
    fn drawList(r: *Renderer, cmd: c.VkCommandBuffer, list: []const Draw) void {
        const d = r.d;
        var i = list.len;
        while (i > 0) {
            i -= 1;
            const dr = list[i];
            const lod = @min(dr.lod, 2);
            if (lod > 0 and r.lod_count[lod - 1] > 0) {
                d.vkCmdDrawIndexed.?(cmd, r.lod_count[lod - 1], dr.count, r.lod_first[lod - 1], 0, dr.first);
            } else d.vkCmdDrawIndexed.?(cmd, r.box_index_count, dr.count, 0, 0, dr.first);
        }
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
    /// instances before; `swapInstances` puts the new ones in, with no
    /// wait for the GPU. The caller keeps `items` and `marks` until then.
    /// False if the buffer is not free yet: then use `setInstances`.
    pub fn beginInstances(r: *Renderer, items: []const Instance, marks: []const Instance) Error!bool {
        r.cancelInstances();
        if (r.retired.buf != null and r.retired_until <= r.frames_done) r.freeBuffer(&r.retired);
        if (r.next_instances.buf != null and r.next_until > r.frames_done) {
            // A frame on the GPU can still read it: it goes when that
            // frame is done.
            if (r.retired.buf != null) return false;
            r.retired = r.next_instances;
            r.retired_until = r.next_until;
            r.next_instances = .{};
        }
        const need = (items.len + marks.len + max_extras) * @sizeOf(Instance);
        if (need > r.next_instances.size or r.next_instances.buf == null) try r.makeBuffer(&r.next_instances, need, c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        const u = std.heap.c_allocator.create(Upload) catch return error.OutOfMemory;
        u.* = .{ .count = @intCast(items.len + marks.len) };
        u.thread = std.Thread.spawn(.{}, Upload.run, .{ u, r.next_instances.map.?, items, marks }) catch {
            std.heap.c_allocator.destroy(u);
            return false;
        };
        r.upload = u;
        return true;
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
        r.cache_valid = false;
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

    /// Replaces the boxes. Waits for the GPU, because the buffer can be in
    /// use by the frame before.
    /// The buffer has one spare slot after the items, for the bead that
    /// the replay is printing (see Frame.partial).
    /// The beads, then the marks (seams, travel, retractions) after
    /// them: Frame.mark_first is beads.len.
    pub fn setInstances(r: *Renderer, items: []const Instance, marks: []const Instance) Error!void {
        r.cache_valid = false;
        _ = r.d.vkDeviceWaitIdle.?(r.device);
        const bytes = std.mem.sliceAsBytes(items);
        const mark_bytes = std.mem.sliceAsBytes(marks);
        const need = bytes.len + mark_bytes.len + max_extras * @sizeOf(Instance);
        if (need > r.instances.size) try r.makeBuffer(&r.instances, need, c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        @memcpy(r.instances.map.?[0..bytes.len], bytes);
        @memcpy(r.instances.map.?[bytes.len .. bytes.len + mark_bytes.len], mark_bytes);
        r.instance_count = @intCast(items.len + marks.len);
    }

    /// The beads and the marks in the instance buffer, for the caller to
    /// change some of them in place (the colors of a changed selection):
    /// no copy of the other beads. Waits for the GPU. Null with no buffer.
    /// The slice stays valid until the next call that changes the beads.
    pub fn instancesInPlace(r: *Renderer) ?[]Instance {
        const map = r.instances.map orelse return null;
        r.cache_valid = false;
        _ = r.d.vkDeviceWaitIdle.?(r.device);
        const p: [*]Instance = @ptrCast(@alignCast(map));
        return p[0..r.instance_count];
    }

    /// The instance buffer for `n` beads, for the caller to fill in place
    /// (no copy in host memory). The marks are none. Waits for the GPU.
    /// The slice stays valid until the next call that changes the beads.
    pub fn instanceBuffer(r: *Renderer, n: usize) Error![]Instance {
        r.cache_valid = false;
        _ = r.d.vkDeviceWaitIdle.?(r.device);
        const need = (n + max_extras) * @sizeOf(Instance);
        if (need > r.instances.size) try r.makeBuffer(&r.instances, need, c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        r.instance_count = @intCast(n);
        const p: [*]Instance = @ptrCast(@alignCast(r.instances.map.?));
        return p[0..n];
    }

    /// Replaces the grid lines: pairs of points, x, y, z each.
    pub fn setGrid(r: *Renderer, points: []const f32) Error!void {
        r.cache_valid = false;
        _ = r.d.vkDeviceWaitIdle.?(r.device);
        const bytes = std.mem.sliceAsBytes(points);
        if (bytes.len > r.grid.size) try r.makeBuffer(&r.grid, bytes.len, c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        @memcpy(r.grid.map.?[0..bytes.len], bytes);
    }

    /// Replaces the bed model: its triangles (see bed.zig), and its
    /// texture or null. The bed is static: this runs once for each
    /// printer, so a wait for the GPU is fine.
    pub fn setBed(r: *Renderer, verts: []const BedVertex, image: ?BedImage) Error!void {
        r.cache_valid = false;
        _ = r.d.vkDeviceWaitIdle.?(r.device);
        r.bed_count = 0;
        if (verts.len == 0) return;
        const bytes = std.mem.sliceAsBytes(verts);
        if (bytes.len > r.bed.size) try r.makeBuffer(&r.bed, bytes.len, c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        @memcpy(r.bed.map.?[0..bytes.len], bytes);
        // A white pixel when the bed has no texture: the set needs an image.
        const white = [4]u8{ 255, 255, 255, 255 };
        const img: BedImage = image orelse .{ .width = 1, .height = 1, .rgba = @constCast(&white) };
        try r.uploadTexture(img, &r.tex, r.bed_set);
        r.bed_count = @intCast(verts.len);
    }

    fn freeTexture(r: *Renderer, t: *Texture) void {
        const d = r.d;
        if (t.view != null) d.vkDestroyImageView.?(r.device, t.view, null);
        if (t.image != null) d.vkDestroyImage.?(r.device, t.image, null);
        if (t.mem != null) d.vkFreeMemory.?(r.device, t.mem, null);
        t.* = .{};
    }

    /// Replaces the image of the signs of the plates (null: none). The
    /// signs change seldom (a new plate, a new status), so a wait for the
    /// GPU is fine.
    pub fn setSignImage(r: *Renderer, image: ?BedImage) Error!void {
        r.cache_valid = false;
        _ = r.d.vkDeviceWaitIdle.?(r.device);
        // No image: no signs (the draw skips them).
        const img = image orelse return r.freeTexture(&r.sign_tex);
        try r.uploadTexture(img, &r.sign_tex, r.sign_set);
    }

    /// Copies an RGBA image to a new sampled image (through a host buffer),
    /// and points the descriptor set at it. The GPU is idle.
    fn uploadTexture(r: *Renderer, img: BedImage, t: *Texture, set: c.VkDescriptorSet) Error!void {
        const d = r.d;
        r.freeTexture(t);
        const extent: c.VkExtent2D = .{ .width = img.width, .height = img.height };
        try check(d.vkCreateImage.?(r.device, &.{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .imageType = c.VK_IMAGE_TYPE_2D,
            .format = c.VK_FORMAT_R8G8B8A8_UNORM,
            .extent = .{ .width = extent.width, .height = extent.height, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .tiling = c.VK_IMAGE_TILING_OPTIMAL,
            .usage = c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        }, null, &t.image));
        var req: c.VkMemoryRequirements = undefined;
        d.vkGetImageMemoryRequirements.?(r.device, t.image, &req);
        try check(d.vkAllocateMemory.?(r.device, &.{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = req.size,
            .memoryTypeIndex = try r.memoryType(req.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
        }, null, &t.mem));
        try check(d.vkBindImageMemory.?(r.device, t.image, t.mem, 0));
        try check(d.vkCreateImageView.?(r.device, &.{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = t.image,
            .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
            .format = c.VK_FORMAT_R8G8B8A8_UNORM,
            .subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .levelCount = 1, .layerCount = 1 },
        }, null, &t.view));

        var staging: Buffer = .{};
        defer r.freeBuffer(&staging);
        const n = @as(usize, img.width) * img.height * 4;
        try r.makeBuffer(&staging, n, c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
        @memcpy(staging.map.?[0..n], img.rgba[0..n]);

        const cmd = r.cmd;
        try check(d.vkResetCommandBuffer.?(cmd, 0));
        try check(d.vkBeginCommandBuffer.?(cmd, &.{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        }));
        const range: c.VkImageSubresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .levelCount = 1, .layerCount = 1 };
        d.vkCmdPipelineBarrier.?(cmd, c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &.{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .srcAccessMask = 0,
            .dstAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT,
            .oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .image = t.image,
            .subresourceRange = range,
        });
        d.vkCmdCopyBufferToImage.?(cmd, staging.buf, t.image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &.{
            .bufferOffset = 0,
            .imageSubresource = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 },
            .imageExtent = .{ .width = img.width, .height = img.height, .depth = 1 },
        });
        d.vkCmdPipelineBarrier.?(cmd, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &.{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT,
            .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT,
            .oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .image = t.image,
            .subresourceRange = range,
        });
        try check(d.vkEndCommandBuffer.?(cmd));
        // The frame fence is signaled (the GPU is idle). Use it for the
        // copy, and wait: it is signaled again for the next frame.
        try check(d.vkResetFences.?(r.device, 1, &r.fence));
        try check(d.vkQueueSubmit.?(r.queue, 1, &.{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .commandBufferCount = 1,
            .pCommandBuffers = &cmd,
        }, r.fence));
        try check(d.vkWaitForFences.?(r.device, 1, &r.fence, c.VK_TRUE, std.math.maxInt(u64)));

        const info: c.VkDescriptorImageInfo = .{
            .sampler = r.sampler,
            .imageView = t.view,
            .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
        d.vkUpdateDescriptorSets.?(r.device, 1, &.{
            .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = set,
            .dstBinding = 0,
            .descriptorCount = 1,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImageInfo = &info,
        }, 0, null);
    }

    // ---- swapchain ----

    fn destroySwapchain(r: *Renderer) void {
        const d = r.d;
        for (0..r.image_count) |k| {
            d.vkDestroyFramebuffer.?(r.device, r.framebuffers[k], null);
            d.vkDestroyImageView.?(r.device, r.views[k], null);
            d.vkDestroySemaphore.?(r.device, r.rendered[k], null);
        }
        r.image_count = 0;
        if (r.msaa_view != null) d.vkDestroyImageView.?(r.device, r.msaa_view, null);
        if (r.msaa_image != null) d.vkDestroyImage.?(r.device, r.msaa_image, null);
        if (r.msaa_mem != null) d.vkFreeMemory.?(r.device, r.msaa_mem, null);
        r.msaa_view = null;
        r.msaa_image = null;
        r.msaa_mem = null;
        if (r.depth_view != null) d.vkDestroyImageView.?(r.device, r.depth_view, null);
        if (r.depth_image != null) d.vkDestroyImage.?(r.device, r.depth_image, null);
        if (r.depth_mem != null) d.vkFreeMemory.?(r.device, r.depth_mem, null);
        r.depth_view = null;
        r.depth_image = null;
        r.depth_mem = null;
    }

    fn makeSwapchain(r: *Renderer) Error!void {
        const d = r.d;
        _ = d.vkDeviceWaitIdle.?(r.device);
        r.destroySwapchain();

        var caps: c.VkSurfaceCapabilitiesKHR = undefined;
        try check(r.i.vkGetPhysicalDeviceSurfaceCapabilitiesKHR.?(r.phys, r.surface, &caps));
        // A Wayland surface has no size of its own (0xFFFFFFFF): the host
        // gives the size.
        var extent = caps.currentExtent;
        if (extent.width == 0xFFFFFFFF) {
            extent = .{
                .width = std.math.clamp(r.want_width, caps.minImageExtent.width, caps.maxImageExtent.width),
                .height = std.math.clamp(r.want_height, caps.minImageExtent.height, caps.maxImageExtent.height),
            };
        }
        if (extent.width == 0 or extent.height == 0) return; // minimized
        var image_count = caps.minImageCount + 1;
        if (caps.maxImageCount > 0) image_count = @min(image_count, caps.maxImageCount);
        image_count = @min(image_count, max_images);
        // Pre-multiplied alpha first, though each pixel of a frame has an
        // alpha of 1. With an opaque format (XRGB), Hyprland 0.56 counts the
        // view (a subsurface under the window, out to its right and bottom
        // edges) as the whole window, marks the window opaque, and draws
        // the window with no blending: its transparent hole then covers
        // the view. The shell sets the opaque region of the surface.
        const supported = caps.supportedCompositeAlpha;
        const alpha: c.VkCompositeAlphaFlagBitsKHR = if (supported & c.VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR != 0)
            c.VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR
        else if (supported & c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR != 0)
            c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR
        else
            c.VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR;

        const old = r.swapchain;
        try check(d.vkCreateSwapchainKHR.?(r.device, &.{
            .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .surface = r.surface,
            .minImageCount = image_count,
            .imageFormat = r.format.format,
            .imageColorSpace = r.format.colorSpace,
            .imageExtent = extent,
            .imageArrayLayers = 1,
            .imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            .imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .preTransform = caps.currentTransform,
            .compositeAlpha = alpha,
            .presentMode = r.pickPresentMode(),
            .clipped = c.VK_TRUE,
            .oldSwapchain = old,
        }, null, &r.swapchain));
        if (old != null) d.vkDestroySwapchainKHR.?(r.device, old, null);
        r.extent = extent;

        var n: u32 = 0;
        try check(d.vkGetSwapchainImagesKHR.?(r.device, r.swapchain, &n, null));
        n = @min(n, max_images);
        try check(d.vkGetSwapchainImagesKHR.?(r.device, r.swapchain, &n, &r.images));

        // The multisampled color image (it lives only during the render
        // pass, so it can be transient).
        const msaa = r.samples != c.VK_SAMPLE_COUNT_1_BIT;
        if (msaa) {
            try r.makeImage(extent, r.format.format, r.samples, c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT, c.VK_IMAGE_ASPECT_COLOR_BIT, &r.msaa_image, &r.msaa_mem, &r.msaa_view);
        }
        try r.makeDepth(extent, 0);

        for (0..n) |k| {
            try check(d.vkCreateImageView.?(r.device, &.{
                .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .image = r.images[k],
                .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
                .format = r.format.format,
                .subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .levelCount = 1, .layerCount = 1 },
            }, null, &r.views[k]));
            r.framebuffers[k] = try r.makeFramebuffer(r.views[k], extent);
            // One "rendered" semaphore for each image: the present of an
            // image can still wait on its semaphore when the next frame
            // starts.
            try check(d.vkCreateSemaphore.?(r.device, &.{ .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO }, null, &r.rendered[k]));
            r.image_count += 1;
        }
        r.stale = false;
    }

    /// The depth buffer (and its view) of the size of the drawing.
    fn makeDepth(r: *Renderer, extent: c.VkExtent2D, usage: c.VkImageUsageFlags) Error!void {
        const d = r.d;
        try check(d.vkCreateImage.?(r.device, &.{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .imageType = c.VK_IMAGE_TYPE_2D,
            .format = depth_format,
            .extent = .{ .width = extent.width, .height = extent.height, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = r.samples,
            .tiling = c.VK_IMAGE_TILING_OPTIMAL,
            .usage = @as(c.VkImageUsageFlags, c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT) | usage,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        }, null, &r.depth_image));
        var req: c.VkMemoryRequirements = undefined;
        d.vkGetImageMemoryRequirements.?(r.device, r.depth_image, &req);
        try check(d.vkAllocateMemory.?(r.device, &.{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = req.size,
            .memoryTypeIndex = try r.memoryType(req.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
        }, null, &r.depth_mem));
        try check(d.vkBindImageMemory.?(r.device, r.depth_image, r.depth_mem, 0));
        try check(d.vkCreateImageView.?(r.device, &.{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = r.depth_image,
            .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
            .format = depth_format,
            .subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT, .levelCount = 1, .layerCount = 1 },
        }, null, &r.depth_view));
    }

    /// A framebuffer of the render pass that resolves (or draws) into
    /// `color`.
    fn makeFramebuffer(r: *Renderer, color: c.VkImageView, extent: c.VkExtent2D) Error!c.VkFramebuffer {
        const msaa = r.samples != c.VK_SAMPLE_COUNT_1_BIT;
        const atts = if (msaa) [_]c.VkImageView{ r.msaa_view, r.depth_view, color } else [_]c.VkImageView{ color, r.depth_view, null };
        var fb: c.VkFramebuffer = null;
        try check(r.d.vkCreateFramebuffer.?(r.device, &.{
            .sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            .renderPass = r.render_pass,
            .attachmentCount = if (msaa) 3 else 2,
            .pAttachments = &atts,
            .width = extent.width,
            .height = extent.height,
            .layers = 1,
        }, null, &fb));
        return fb;
    }

    // ---- the offscreen target ----

    fn destroyTarget(r: *Renderer) void {
        const d = r.d;
        if (r.target_fb != null) d.vkDestroyFramebuffer.?(r.device, r.target_fb, null);
        if (r.target_view != null) d.vkDestroyImageView.?(r.device, r.target_view, null);
        if (r.target_image != null) d.vkDestroyImage.?(r.device, r.target_image, null);
        if (r.target_mem != null) d.vkFreeMemory.?(r.device, r.target_mem, null);
        r.target_fb = null;
        r.target_view = null;
        r.target_image = null;
        r.target_mem = null;
        if (r.cache_fb != null) d.vkDestroyFramebuffer.?(r.device, r.cache_fb, null);
        for ([_]c.VkImageView{ r.cache_color_view, r.cache_depth_view }) |v| if (v != null) d.vkDestroyImageView.?(r.device, v, null);
        for ([_]c.VkImage{ r.cache_color, r.cache_depth }) |im| if (im != null) d.vkDestroyImage.?(r.device, im, null);
        for ([_]c.VkDeviceMemory{ r.cache_color_mem, r.cache_depth_mem }) |m| if (m != null) d.vkFreeMemory.?(r.device, m, null);
        r.cache_fb = null;
        r.cache_color_view = null;
        r.cache_depth_view = null;
        r.cache_color = null;
        r.cache_depth = null;
        r.cache_color_mem = null;
        r.cache_depth_mem = null;
        r.cache_valid = false;
    }

    /// The offscreen image of the wanted size, the images of the pass, and
    /// the host buffer for the copy.
    fn makeTarget(r: *Renderer) Error!void {
        _ = r.d.vkDeviceWaitIdle.?(r.device);
        r.destroySwapchain();
        r.destroyTarget();
        r.drawn = false;
        const extent: c.VkExtent2D = .{ .width = r.want_width, .height = r.want_height };
        // The images take a copy of the cache (see drawCached).
        const dst = c.VK_IMAGE_USAGE_TRANSFER_DST_BIT;
        try r.makeImage(extent, r.format.format, c.VK_SAMPLE_COUNT_1_BIT, c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT | dst, c.VK_IMAGE_ASPECT_COLOR_BIT, &r.target_image, &r.target_mem, &r.target_view);
        if (r.samples != c.VK_SAMPLE_COUNT_1_BIT) {
            try r.makeImage(extent, r.format.format, r.samples, c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | dst, c.VK_IMAGE_ASPECT_COLOR_BIT, &r.msaa_image, &r.msaa_mem, &r.msaa_view);
        }
        try r.makeDepth(extent, dst);
        r.target_fb = try r.makeFramebuffer(r.target_view, extent);
        const bytes = @as(usize, extent.width) * extent.height * 4;
        if (r.readback.size < bytes) try r.makeReadback(bytes);
        r.extent = extent;
        r.stale = false;
    }

    /// A host buffer that the GPU copies into and the CPU reads: cached
    /// host memory if the device has it (an uncached read is slow).
    fn makeReadback(r: *Renderer, size: usize) Error!void {
        const b = &r.readback;
        r.freeBuffer(b);
        try check(r.d.vkCreateBuffer.?(r.device, &.{
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .size = size,
            .usage = c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        }, null, &b.buf));
        var req: c.VkMemoryRequirements = undefined;
        r.d.vkGetBufferMemoryRequirements.?(r.device, b.buf, &req);
        const host = c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        const t = r.memoryType(req.memoryTypeBits, host | c.VK_MEMORY_PROPERTY_HOST_CACHED_BIT) catch try r.memoryType(req.memoryTypeBits, host);
        try check(r.d.vkAllocateMemory.?(r.device, &.{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = req.size,
            .memoryTypeIndex = t,
        }, null, &b.mem));
        try check(r.d.vkBindBufferMemory.?(r.device, b.buf, b.mem, 0));
        var ptr: ?*anyopaque = null;
        try check(r.d.vkMapMemory.?(r.device, b.mem, 0, size, 0, &ptr));
        b.map = @ptrCast(ptr);
        b.size = size;
    }

    /// Copies the last offscreen frame out, row by row from the top, with
    /// `stride` bytes from one row to the next. Waits for the frame.
    /// error.FrameBusy before the first frame, or for a window renderer.
    pub fn read(r: *Renderer, out: []u8, stride: usize) Error!void {
        if (!r.offscreen or !r.drawn) return error.FrameBusy;
        try check(r.d.vkWaitForFences.?(r.device, 1, &r.fence, c.VK_TRUE, std.math.maxInt(u64)));
        const row = @as(usize, r.extent.width) * 4;
        if (stride < row or out.len < stride * (r.extent.height - 1) + row) return error.VulkanFailed;
        const src = r.readback.map.?;
        for (0..r.extent.height) |y| @memcpy(out[y * stride ..][0..row], src[y * row ..][0..row]);
    }

    /// The size of the offscreen image (after the first frame).
    pub fn targetSize(r: *const Renderer) [2]u32 {
        return .{ r.extent.width, r.extent.height };
    }

    /// A device-local image with one view, for a render target.
    fn makeImage(r: *Renderer, extent: c.VkExtent2D, format: c.VkFormat, samples: c.VkSampleCountFlagBits, usage: c.VkImageUsageFlags, aspect: c.VkImageAspectFlags, image: *c.VkImage, mem: *c.VkDeviceMemory, view: *c.VkImageView) Error!void {
        const d = r.d;
        try check(d.vkCreateImage.?(r.device, &.{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .imageType = c.VK_IMAGE_TYPE_2D,
            .format = format,
            .extent = .{ .width = extent.width, .height = extent.height, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = samples,
            .tiling = c.VK_IMAGE_TILING_OPTIMAL,
            .usage = usage,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        }, null, image));
        var req: c.VkMemoryRequirements = undefined;
        d.vkGetImageMemoryRequirements.?(r.device, image.*, &req);
        try check(d.vkAllocateMemory.?(r.device, &.{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = req.size,
            .memoryTypeIndex = try r.memoryType(req.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
        }, null, mem));
        try check(d.vkBindImageMemory.?(r.device, image.*, mem.*, 0));
        try check(d.vkCreateImageView.?(r.device, &.{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = image.*,
            .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
            .format = format,
            .subresourceRange = .{ .aspectMask = aspect, .levelCount = 1, .layerCount = 1 },
        }, null, view));
    }

    // ---- frame ----

    pub const Frame = frame_mod.Frame;

    /// Draws one frame and presents it. An offscreen renderer draws into
    /// its image and copies it to the host (see `read`).
    pub fn draw(r: *Renderer, frame: Frame) Error!void {
        if (r.offscreen) return r.drawOffscreen(frame);
        const d = r.d;
        if (r.stale or r.swapchain == null) try r.makeSwapchain();
        if (r.image_count == 0) return;

        // Short waits only: the UI thread draws, and must not block. The
        // last frame's GPU work ends in a few ms; an image can stay held by
        // the compositor for as long as the window does not repaint. In
        // both cases this frame is skipped, and the shell tries again.
        const fw = d.vkWaitForFences.?(r.device, 1, &r.fence, c.VK_TRUE, 50 * std.time.ns_per_ms);
        if (fw == c.VK_TIMEOUT) return error.FrameBusy;
        try check(fw);
        r.frames_done = r.frames_sent;
        var index: u32 = 0;
        const acq = d.vkAcquireNextImageKHR.?(r.device, r.swapchain, 2 * std.time.ns_per_ms, r.acquired, null, &index);
        if (acq == c.VK_TIMEOUT or acq == c.VK_NOT_READY) return error.FrameBusy;
        if (acq == c.VK_ERROR_OUT_OF_DATE_KHR) {
            r.stale = true;
            return;
        }
        if (acq != c.VK_SUCCESS and acq != c.VK_SUBOPTIMAL_KHR) return error.VulkanFailed;
        // The frame before is done (the fence): the buffers of the plates
        // can change.
        try r.syncPlates(frame);
        try check(d.vkResetFences.?(r.device, 1, &r.fence));

        const cmd = r.cmd;
        try check(d.vkResetCommandBuffer.?(cmd, 0));
        try check(d.vkBeginCommandBuffer.?(cmd, &.{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        }));
        r.recordPass(cmd, r.render_pass, r.framebuffers[index], frame);
        try check(d.vkEndCommandBuffer.?(cmd));

        const wait_stage: c.VkPipelineStageFlags = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        try check(d.vkQueueSubmit.?(r.queue, 1, &.{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &r.acquired,
            .pWaitDstStageMask = &wait_stage,
            .commandBufferCount = 1,
            .pCommandBuffers = &cmd,
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &r.rendered[index],
        }, r.fence));
        r.frames_sent += 1;
        const pres = d.vkQueuePresentKHR.?(r.queue, &.{
            .sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &r.rendered[index],
            .swapchainCount = 1,
            .pSwapchains = &r.swapchain,
            .pImageIndices = &index,
        });
        if (pres == c.VK_ERROR_OUT_OF_DATE_KHR or pres == c.VK_SUBOPTIMAL_KHR) r.stale = true else try check(pres);
    }

    /// Records the render pass of a frame into `fb`.
    fn recordPass(r: *Renderer, cmd: c.VkCommandBuffer, pass: c.VkRenderPass, fb: c.VkFramebuffer, frame: Frame) void {
        const d = r.d;
        const clears = [_]c.VkClearValue{
            .{ .color = .{ .float32 = .{ frame.clear[0], frame.clear[1], frame.clear[2], 1 } } },
            .{ .depthStencil = .{ .depth = 1, .stencil = 0 } },
            .{ .color = .{ .float32 = .{ 0, 0, 0, 1 } } },
        };
        d.vkCmdBeginRenderPass.?(cmd, &.{
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .renderPass = pass,
            .framebuffer = fb,
            .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = r.extent },
            .clearValueCount = if (r.samples != c.VK_SAMPLE_COUNT_1_BIT) 3 else 2,
            .pClearValues = &clears,
        }, c.VK_SUBPASS_CONTENTS_INLINE);
        d.vkCmdSetViewport.?(cmd, 0, 1, &.{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(r.extent.width),
            .height = @floatFromInt(r.extent.height),
            .minDepth = 0,
            .maxDepth = 1,
        });
        d.vkCmdSetScissor.?(cmd, 0, 1, &.{ .offset = .{ .x = 0, .y = 0 }, .extent = r.extent });
        const zero: c.VkDeviceSize = 0;
        const stages = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT;

        if (frame.grid_vertices > 0 and r.grid.buf != null) {
            d.vkCmdBindPipeline.?(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, r.grid_pipeline);
            d.vkCmdPushConstants.?(cmd, r.layout, stages, 0, @sizeOf(Push), &frame.grid);
            d.vkCmdBindVertexBuffers.?(cmd, 0, 1, &r.grid.buf, &zero);
            d.vkCmdDraw.?(cmd, frame.grid_vertices, 1, 0, 0);
        }
        // The grids of the other plates: the plates that cannot slice in a
        // lighter color.
        const plate_grid_n: u32 = @intCast(frame.plate_grid.len / 3);
        if (plate_grid_n > 0 and r.plate_grid.buf != null) {
            d.vkCmdBindPipeline.?(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, r.grid_pipeline);
            d.vkCmdPushConstants.?(cmd, r.layout, stages, 0, @sizeOf(Push), &frame.grid);
            d.vkCmdBindVertexBuffers.?(cmd, 0, 1, &r.plate_grid.buf, &zero);
            const dim = @min(frame.plate_grid_dim, plate_grid_n);
            if (dim > 0) d.vkCmdDraw.?(cmd, dim, 1, 0, 0);
            if (plate_grid_n > dim) {
                var light = frame.grid;
                light.vec = .{ 0.88, 0.89, 0.91, 1 };
                d.vkCmdPushConstants.?(cmd, r.layout, stages, 0, @sizeOf(Push), &light);
                d.vkCmdDraw.?(cmd, plate_grid_n - dim, 1, dim, 0);
            }
        }
        // The other plates, with no beads of the active plate too.
        if (frame.box_count == 0 and r.box_index_count > 0 and frame.plates.len > 0) {
            d.vkCmdBindPipeline.?(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, r.box_pipeline);
            d.vkCmdBindIndexBuffer.?(cmd, r.box_index.buf, 0, c.VK_INDEX_TYPE_UINT16);
            r.drawOtherPlates(cmd, frame);
        }
        if (frame.box_count > 0 and r.instances.buf != null and r.box_index_count > 0) {
            d.vkCmdBindPipeline.?(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, r.box_pipeline);
            d.vkCmdPushConstants.?(cmd, r.layout, stages, 0, @sizeOf(Push), &frame.box);
            const bufs = [_]c.VkBuffer{ r.box_mesh.buf, r.instances.buf };
            const offs = [_]c.VkDeviceSize{ 0, 0 };
            d.vkCmdBindVertexBuffers.?(cmd, 0, 2, &bufs, &offs);
            d.vkCmdBindIndexBuffer.?(cmd, r.box_index.buf, 0, c.VK_INDEX_TYPE_UINT16);
            r.drawBeads(cmd, frame);
            if (frame.mark_count > 0) d.vkCmdDrawIndexed.?(cmd, r.box_index_count, frame.mark_count, 0, 0, frame.mark_first);
            r.drawOtherPlates(cmd, frame);
            // A part that turns in the view only: its own push data.
            if (frame.part_draws.len > 0) {
                d.vkCmdPushConstants.?(cmd, r.layout, stages, 0, @sizeOf(Push), &frame.part);
                r.drawList(cmd, frame.part_draws);
                d.vkCmdPushConstants.?(cmd, r.layout, stages, 0, @sizeOf(Push), &frame.box);
            }
            // With a focus (params.z != 0): the beads out of the focus, as
            // ghosts, after the solid beads (params.w = 2 in the shader).
            if (frame.box.params[2] != 0) {
                var ghost = frame.box;
                ghost.params[3] = 2;
                d.vkCmdBindPipeline.?(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, r.ghost_pipeline);
                d.vkCmdPushConstants.?(cmd, r.layout, stages, 0, @sizeOf(Push), &ghost);
                r.drawBeads(cmd, frame);
                if (frame.mark_count > 0) d.vkCmdDrawIndexed.?(cmd, r.box_index_count, frame.mark_count, 0, 0, frame.mark_first);
                d.vkCmdBindPipeline.?(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, r.box_pipeline);
                d.vkCmdPushConstants.?(cmd, r.layout, stages, 0, @sizeOf(Push), &frame.box);
            }
        }
        if (frame.extras.len > 0 and r.instances.buf != null and r.box_index_count > 0) {
            const extras = frame.extras[0..@min(frame.extras.len, max_extras)];
            // The spare slots after the beads. The previous frame is done
            // (the fence), so the CPU can write them.
            const off = @as(usize, r.instance_count) * @sizeOf(Instance);
            const eb = std.mem.sliceAsBytes(extras);
            @memcpy(r.instances.map.?[off .. off + eb.len], eb);
            if (frame.box_count == 0) {
                d.vkCmdBindPipeline.?(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, r.box_pipeline);
                d.vkCmdPushConstants.?(cmd, r.layout, stages, 0, @sizeOf(Push), &frame.box);
                const bufs = [_]c.VkBuffer{ r.box_mesh.buf, r.instances.buf };
                const offs = [_]c.VkDeviceSize{ 0, 0 };
                d.vkCmdBindVertexBuffers.?(cmd, 0, 2, &bufs, &offs);
                d.vkCmdBindIndexBuffer.?(cmd, r.box_index.buf, 0, c.VK_INDEX_TYPE_UINT16);
            }
            d.vkCmdDrawIndexed.?(cmd, r.box_index_count, @intCast(extras.len), 0, 0, r.instance_count);
        }
        // The bed after the beads and the extras: its see-through parts blend over them.
        if (frame.bed_vertices > 0 and r.bed_count > 0) {
            d.vkCmdBindPipeline.?(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, r.bed_pipeline);
            d.vkCmdBindDescriptorSets.?(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, r.bed_layout, 0, 1, &r.bed_set, 0, null);
            d.vkCmdPushConstants.?(cmd, r.bed_layout, stages, 0, @sizeOf(Push), &frame.bed);
            d.vkCmdBindVertexBuffers.?(cmd, 0, 1, &r.bed.buf, &zero);
            d.vkCmdDraw.?(cmd, @min(frame.bed_vertices, r.bed_count), 1, 0, 0);
            // The bed model at each other plate of the same printer.
            for (frame.plates) |pf| {
                if (!otherPlate(pf) or pf.flags & PlateFrame.flag_bed == 0) continue;
                var push = frame.bed;
                push.mvp = pf.bed_mvp;
                d.vkCmdPushConstants.?(cmd, r.bed_layout, stages, 0, @sizeOf(Push), &push);
                d.vkCmdDraw.?(cmd, @min(frame.bed_vertices, r.bed_count), 1, 0, 0);
            }
        }
        // The signs of the plates, after the bed: the parts hide them.
        if (frame.signs.len > 0 and r.sign_tex.image != null) sign: {
            const bytes = std.mem.sliceAsBytes(frame.signs);
            if (bytes.len > r.sign_buf.size) r.makeBuffer(&r.sign_buf, bytes.len * 2, c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT) catch break :sign;
            @memcpy(r.sign_buf.map.?[0..bytes.len], bytes);
            d.vkCmdBindPipeline.?(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, r.sign_pipeline);
            d.vkCmdBindDescriptorSets.?(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, r.bed_layout, 0, 1, &r.sign_set, 0, null);
            d.vkCmdPushConstants.?(cmd, r.bed_layout, stages, 0, @sizeOf(Push), &frame.sign);
            d.vkCmdBindVertexBuffers.?(cmd, 0, 1, &r.sign_buf.buf, &zero);
            d.vkCmdDraw.?(cmd, @intCast(frame.signs.len), 1, 0, 0);
        }
        // The decals of the labels: the parts hide them, and they cover
        // the beads of their face.
        if (frame.decals.len + frame.decal_edges.len > 0 and r.decal_pipeline != null) decal: {
            const fill = std.mem.sliceAsBytes(frame.decals);
            const edges = std.mem.sliceAsBytes(frame.decal_edges);
            const need = fill.len + edges.len;
            if (need > r.decal_buf.size) {
                r.makeBuffer(&r.decal_buf, need * 2, c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT) catch break :decal;
                r.decal_fill = std.math.maxInt(usize);
            }
            // The fill goes into the buffer only when it changes.
            if (frame.decal_gen != r.decal_gen or r.decal_fill != frame.decals.len) {
                @memcpy(r.decal_buf.map.?[0..fill.len], fill);
                r.decal_gen = frame.decal_gen;
                r.decal_fill = frame.decals.len;
            }
            @memcpy(r.decal_buf.map.?[fill.len..need], edges);
            d.vkCmdBindPipeline.?(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, r.decal_pipeline);
            d.vkCmdPushConstants.?(cmd, r.bed_layout, stages, 0, @sizeOf(Push), &frame.sign);
            d.vkCmdBindVertexBuffers.?(cmd, 0, 1, &r.decal_buf.buf, &zero);
            d.vkCmdDraw.?(cmd, @intCast(frame.decals.len + frame.decal_edges.len), 1, 0, 0);
        }
        if (frame.head.len > 0 and r.instances.buf != null and r.box_index_count > 0) {
            const used = @min(frame.extras.len, max_extras);
            const head = frame.head[0..@min(frame.head.len, max_extras - used)];
            const off = (@as(usize, r.instance_count) + used) * @sizeOf(Instance);
            const hb = std.mem.sliceAsBytes(head);
            @memcpy(r.instances.map.?[off .. off + hb.len], hb);
            // Blended, with no depth write; params.w = 3 in the shader.
            var see = frame.box;
            see.params[2] = 0;
            see.params[3] = 3;
            d.vkCmdBindPipeline.?(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, r.ghost_pipeline);
            d.vkCmdPushConstants.?(cmd, r.layout, stages, 0, @sizeOf(Push), &see);
            const bufs = [_]c.VkBuffer{ r.box_mesh.buf, r.instances.buf };
            const offs = [_]c.VkDeviceSize{ 0, 0 };
            d.vkCmdBindVertexBuffers.?(cmd, 0, 2, &bufs, &offs);
            d.vkCmdBindIndexBuffer.?(cmd, r.box_index.buf, 0, c.VK_INDEX_TYPE_UINT16);
            d.vkCmdDrawIndexed.?(cmd, r.box_index_count, @intCast(head.len), 0, 0, r.instance_count + @as(u32, @intCast(used)));
        }
        d.vkCmdEndRenderPass.?(cmd);
    }

    // ---- the cache of a print view ----

    /// The passes of the cache: one clears the cache and draws into it,
    /// one adds to it, and one draws over a copy of it into the target.
    /// Each has one subpass, so the pipelines of the main pass work in
    /// them (the resolve attachments do not count for compatibility).
    fn makeCachePasses(r: *Renderer) Error!void {
        const msaa = r.samples != c.VK_SAMPLE_COUNT_1_BIT;
        const src = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        const dst = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        const att = struct {
            fn f(format: c.VkFormat, samples: c.VkSampleCountFlagBits, load: c.VkAttachmentLoadOp, store: c.VkAttachmentStoreOp, from: c.VkImageLayout, to: c.VkImageLayout) c.VkAttachmentDescription {
                return .{
                    .format = format,
                    .samples = samples,
                    .loadOp = load,
                    .storeOp = store,
                    .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
                    .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
                    .initialLayout = from,
                    .finalLayout = to,
                };
            }
        }.f;
        const fmt = r.format.format;
        const store = c.VK_ATTACHMENT_STORE_OP_STORE;
        const drop = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        const load = c.VK_ATTACHMENT_LOAD_OP_LOAD;
        const clear = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        const undef = c.VK_IMAGE_LAYOUT_UNDEFINED;
        const cache_clear = [_]c.VkAttachmentDescription{ att(fmt, r.samples, clear, store, undef, src), att(depth_format, r.samples, clear, store, undef, src) };
        const cache_add = [_]c.VkAttachmentDescription{ att(fmt, r.samples, load, store, src, src), att(depth_format, r.samples, load, store, src, src) };
        const over = if (msaa)
            [_]c.VkAttachmentDescription{ att(fmt, r.samples, load, drop, dst, c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL), att(depth_format, r.samples, load, drop, dst, c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL), att(fmt, c.VK_SAMPLE_COUNT_1_BIT, c.VK_ATTACHMENT_LOAD_OP_DONT_CARE, store, undef, src) }
        else
            [_]c.VkAttachmentDescription{ att(fmt, r.samples, load, store, dst, src), att(depth_format, r.samples, load, drop, dst, c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL), undefined };
        try r.cachePass(&cache_clear, false, &r.cache_clear_pass);
        try r.cachePass(&cache_add, false, &r.cache_add_pass);
        try r.cachePass(over[0..if (msaa) 3 else 2], msaa, &r.over_pass);
    }

    fn cachePass(r: *Renderer, atts: []const c.VkAttachmentDescription, resolve: bool, out: *c.VkRenderPass) Error!void {
        const color_ref: c.VkAttachmentReference = .{ .attachment = 0, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
        const depth_ref: c.VkAttachmentReference = .{ .attachment = 1, .layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL };
        const resolve_ref: c.VkAttachmentReference = .{ .attachment = 2, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
        const subpass: c.VkSubpassDescription = .{
            .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS,
            .colorAttachmentCount = 1,
            .pColorAttachments = &color_ref,
            .pResolveAttachments = if (resolve) &resolve_ref else null,
            .pDepthStencilAttachment = &depth_ref,
        };
        try check(r.d.vkCreateRenderPass.?(r.device, &.{
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
            .attachmentCount = @intCast(atts.len),
            .pAttachments = atts.ptr,
            .subpassCount = 1,
            .pSubpasses = &subpass,
            .dependencyCount = cache_deps.len,
            .pDependencies = &cache_deps,
        }, null, out));
    }

    /// The images of the cache, of the size of the target.
    fn makeCache(r: *Renderer) Error!void {
        const usage = c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
        try r.makeImage(r.extent, r.format.format, r.samples, c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | usage, c.VK_IMAGE_ASPECT_COLOR_BIT, &r.cache_color, &r.cache_color_mem, &r.cache_color_view);
        try r.makeImage(r.extent, depth_format, r.samples, c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | usage, c.VK_IMAGE_ASPECT_DEPTH_BIT, &r.cache_depth, &r.cache_depth_mem, &r.cache_depth_view);
        const atts = [_]c.VkImageView{ r.cache_color_view, r.cache_depth_view };
        try check(r.d.vkCreateFramebuffer.?(r.device, &.{
            .sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            .renderPass = r.cache_clear_pass,
            .attachmentCount = 2,
            .pAttachments = &atts,
            .width = r.extent.width,
            .height = r.extent.height,
            .layers = 1,
        }, null, &r.cache_fb));
        r.cache_valid = false;
    }

    /// A frame of a print view (Frame.cached):
    ///
    /// 1. The cache: with the same camera and colors as the frame that
    ///    drew it, only the new finished beads draw into it. Else it
    ///    clears, and the grid, the finished beads, and the bed draw.
    /// 2. A copy of the cache goes to the images of the frame.
    /// 3. The beads of the top layer, the extras, and the toolhead draw
    ///    over the copy (and resolve into the target).
    ///
    /// A print that moves on draws only its new beads: the cost of a
    /// frame does not grow with the beads under the top layer.
    fn recordCached(r: *Renderer, cmd: c.VkCommandBuffer, frame: Frame) Error!void {
        const d = r.d;
        if (r.cache_color == null) try r.makeCache();
        const base_end = @min(frame.base_end, frame.box_count);
        const key: CacheKey = .{
            .base = frame.base,
            .grid = frame.grid,
            .bed = frame.bed,
            .clear = frame.clear,
            .first = frame.box_first,
            .grid_vertices = frame.grid_vertices,
            .bed_vertices = frame.bed_vertices,
        };
        const same = r.cache_valid and std.mem.eql(u8, std.mem.asBytes(&key), std.mem.asBytes(&r.cache_key)) and base_end >= r.cache_end;
        var part = frame;
        part.extras = &.{};
        part.head = &.{};
        part.mark_count = 0;
        part.box = frame.base;
        part.box_count = base_end;
        if (same) {
            if (base_end > r.cache_end) {
                part.box_first = r.cache_end;
                part.grid_vertices = 0;
                part.bed_vertices = 0;
                r.recordPass(cmd, r.cache_add_pass, r.cache_fb, part);
            }
        } else {
            r.recordPass(cmd, r.cache_clear_pass, r.cache_fb, part);
        }
        r.cache_key = key;
        r.cache_end = base_end;
        r.cache_valid = true;

        // The copy. The cache is ready to copy (the final layout of its
        // passes); the images of the frame take it in place of their old
        // content.
        const msaa = r.samples != c.VK_SAMPLE_COUNT_1_BIT;
        const color = if (msaa) r.msaa_image else r.target_image;
        const color_range: c.VkImageSubresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .levelCount = 1, .layerCount = 1 };
        const depth_range: c.VkImageSubresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT, .levelCount = 1, .layerCount = 1 };
        const to_dst = [_]c.VkImageMemoryBarrier{
            .{ .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, .srcAccessMask = 0, .dstAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT, .oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED, .image = color, .subresourceRange = color_range },
            .{ .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, .srcAccessMask = 0, .dstAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT, .oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED, .image = r.depth_image, .subresourceRange = depth_range },
        };
        // The cache passes wrote the cache; the copy reads it.
        const mem: c.VkMemoryBarrier = .{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
            .srcAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
            .dstAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT,
        };
        d.vkCmdPipelineBarrier.?(cmd, c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | c.VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT | c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 1, &mem, 0, null, to_dst.len, &to_dst);
        const full: c.VkExtent3D = .{ .width = r.extent.width, .height = r.extent.height, .depth = 1 };
        d.vkCmdCopyImage.?(cmd, r.cache_color, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, color, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &.{
            .srcSubresource = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 },
            .srcOffset = .{ .x = 0, .y = 0, .z = 0 },
            .dstSubresource = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 },
            .dstOffset = .{ .x = 0, .y = 0, .z = 0 },
            .extent = full,
        });
        d.vkCmdCopyImage.?(cmd, r.cache_depth, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, r.depth_image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &.{
            .srcSubresource = .{ .aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 },
            .srcOffset = .{ .x = 0, .y = 0, .z = 0 },
            .dstSubresource = .{ .aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 },
            .dstOffset = .{ .x = 0, .y = 0, .z = 0 },
            .extent = full,
        });

        // The rest of the frame over the copy.
        var rest = frame;
        rest.box_first = @max(frame.box_first, base_end);
        rest.grid_vertices = 0;
        rest.bed_vertices = 0;
        r.recordPass(cmd, r.over_pass, r.target_fb, rest);
    }

    /// Draws one frame into the offscreen image, and copies the image to
    /// the readback buffer. It waits for the frame before (a host that
    /// draws at a fixed rate gets one frame in flight).
    fn drawOffscreen(r: *Renderer, frame: Frame) Error!void {
        const d = r.d;
        try check(d.vkWaitForFences.?(r.device, 1, &r.fence, c.VK_TRUE, std.math.maxInt(u64)));
        r.frames_done = r.frames_sent;
        if (r.stale or r.target_image == null) try r.makeTarget();
        try r.syncPlates(frame);
        try check(d.vkResetFences.?(r.device, 1, &r.fence));
        const cmd = r.cmd;
        try check(d.vkResetCommandBuffer.?(cmd, 0));
        try check(d.vkBeginCommandBuffer.?(cmd, &.{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        }));
        if (frame.cached) try r.recordCached(cmd, frame) else r.recordPass(cmd, r.render_pass, r.target_fb, frame);
        // The pass leaves the image ready to copy; the copy waits for the
        // color writes.
        const range: c.VkImageSubresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .levelCount = 1, .layerCount = 1 };
        d.vkCmdPipelineBarrier.?(cmd, c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &.{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .srcAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dstAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT,
            .oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            .newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .image = r.target_image,
            .subresourceRange = range,
        });
        d.vkCmdCopyImageToBuffer.?(cmd, r.target_image, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, r.readback.buf, 1, &.{
            .bufferOffset = 0,
            .bufferRowLength = 0,
            .bufferImageHeight = 0,
            .imageSubresource = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 },
            .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
            .imageExtent = .{ .width = r.extent.width, .height = r.extent.height, .depth = 1 },
        });
        d.vkCmdPipelineBarrier.?(cmd, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_HOST_BIT, 0, 0, null, 1, &.{
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
            .srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT,
            .dstAccessMask = c.VK_ACCESS_HOST_READ_BIT,
            .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .buffer = r.readback.buf,
            .offset = 0,
            .size = c.VK_WHOLE_SIZE,
        }, 0, null);
        try check(d.vkEndCommandBuffer.?(cmd));
        try check(d.vkQueueSubmit.?(r.queue, 1, &.{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .commandBufferCount = 1,
            .pCommandBuffers = &cmd,
        }, r.fence));
        r.frames_sent += 1;
        r.drawn = true;
    }
};
