//! The Vulkan backend of the renderer.
//!
//! It draws the toolpath boxes and the bed grid into a window surface that
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
//! - Push constants only (a matrix and a vector): no descriptor sets, no
//!   uniform buffers.
//! - Host-visible, coherent buffers for the boxes and the grid: the CPU
//!   writes them directly, with no staging copy.
//! - One frame in flight. The view draws on demand (after a change), not at
//!   a fixed rate, so the simple form is enough.
//!
//! The structure follows the Vulkan backend of charttable (same author, MIT
//! license, see REFERENCES.md): run-time loading, a surface from the shell,
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
};

/// The window surface that the shell gives.
pub const Surface = union(enum) {
    wayland: struct { display: *anyopaque, surface: *anyopaque },
    xlib: struct { display: *anyopaque, window: u64 },
};

/// One toolpath segment, drawn as one box. The layout matches the
/// per-instance attributes of shaders/box.vert.
pub const Instance = extern struct {
    ax: f32,
    ay: f32,
    bx: f32,
    by: f32,
    z: f32,
    h: f32,
    w: f32,
    rgba: [4]u8,
};

comptime {
    std.debug.assert(@sizeOf(Instance) == 32);
}

/// The push constants of both pipelines: a matrix and a vector (the light
/// direction for the boxes, the color for the grid).
pub const Push = extern struct {
    mvp: [16]f32,
    vec: [4]f32,
};

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
    vkCreateSemaphore: c.PFN_vkCreateSemaphore,
    vkDestroySemaphore: c.PFN_vkDestroySemaphore,
    vkCreateFence: c.PFN_vkCreateFence,
    vkDestroyFence: c.PFN_vkDestroyFence,
    vkWaitForFences: c.PFN_vkWaitForFences,
    vkResetFences: c.PFN_vkResetFences,
};

/// Fills a function table: each field name is a Vulkan function name.
fn loadFns(comptime T: type, getter: anytype, handle: anytype) Error!T {
    var out: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        const p = getter(handle, f.name ++ "");
        if (p == null) return error.NoVulkan;
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

const depth_format = c.VK_FORMAT_D32_SFLOAT;

const Buffer = struct {
    buf: c.VkBuffer = null,
    mem: c.VkDeviceMemory = null,
    map: ?[*]u8 = null,
    size: usize = 0,
};

const max_images = 8;

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
    grid_pipeline: c.VkPipeline,
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
    instances: Buffer = .{},
    grid: Buffer = .{},

    pub fn init(surface: Surface, width: u32, height: u32) Error!*Renderer {
        var lib = std.DynLib.open("libvulkan.so.1") catch return error.NoVulkan;
        errdefer lib.close();
        const get = lib.lookup(c.PFN_vkGetInstanceProcAddr, "vkGetInstanceProcAddr") orelse return error.NoVulkan;
        const gipa = get orelse return error.NoVulkan;
        const g = try loadFns(Global, gipa, @as(c.VkInstance, null));

        // The instance, with the surface extension of the window system.
        const surface_ext: [*:0]const u8 = switch (surface) {
            .wayland => "VK_KHR_wayland_surface",
            .xlib => "VK_KHR_xlib_surface",
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
            .enabledExtensionCount = exts.len,
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
        }
        errdefer i.vkDestroySurfaceKHR.?(instance, vk_surface, null);

        // The first device with a queue that draws and presents to this
        // surface. The loader lists the device that drives the display
        // first.
        var count: u32 = 0;
        try check(i.vkEnumeratePhysicalDevices.?(instance, &count, null));
        var devs: [16]c.VkPhysicalDevice = undefined;
        count = @min(count, devs.len);
        try check(i.vkEnumeratePhysicalDevices.?(instance, &count, &devs));
        var phys: c.VkPhysicalDevice = null;
        var family: u32 = 0;
        outer: for (devs[0..count]) |pd| {
            var qn: u32 = 0;
            i.vkGetPhysicalDeviceQueueFamilyProperties.?(pd, &qn, null);
            var qs: [16]c.VkQueueFamilyProperties = undefined;
            qn = @min(qn, qs.len);
            i.vkGetPhysicalDeviceQueueFamilyProperties.?(pd, &qn, &qs);
            for (qs[0..qn], 0..) |q, qi| {
                if (q.queueFlags & c.VK_QUEUE_GRAPHICS_BIT == 0) continue;
                var present: c.VkBool32 = 0;
                _ = i.vkGetPhysicalDeviceSurfaceSupportKHR.?(pd, @intCast(qi), vk_surface, &present);
                if (present == 0) continue;
                phys = pd;
                family = @intCast(qi);
                break :outer;
            }
        }
        if (phys == null) return error.NoDevice;

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
            .enabledExtensionCount = dev_exts.len,
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
        r.format = try r.pickFormat();
        try r.makeRenderPass();
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
        try r.makeBoxMesh();
    }

    pub fn deinit(r: *Renderer) void {
        const d = r.d;
        if (r.device != null) _ = d.vkDeviceWaitIdle.?(r.device);
        r.destroySwapchain();
        if (r.swapchain != null) d.vkDestroySwapchainKHR.?(r.device, r.swapchain, null);
        for ([_]*Buffer{ &r.box_mesh, &r.box_index, &r.instances, &r.grid }) |b| r.freeBuffer(b);
        if (r.fence != null) d.vkDestroyFence.?(r.device, r.fence, null);
        if (r.acquired != null) d.vkDestroySemaphore.?(r.device, r.acquired, null);
        if (r.pool != null) d.vkDestroyCommandPool.?(r.device, r.pool, null);
        if (r.box_pipeline != null) d.vkDestroyPipeline.?(r.device, r.box_pipeline, null);
        if (r.grid_pipeline != null) d.vkDestroyPipeline.?(r.device, r.grid_pipeline, null);
        if (r.layout != null) d.vkDestroyPipelineLayout.?(r.device, r.layout, null);
        if (r.render_pass != null) d.vkDestroyRenderPass.?(r.device, r.render_pass, null);
        d.vkDestroyDevice.?(r.device, null);
        r.i.vkDestroySurfaceKHR.?(r.instance, r.surface, null);
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

    fn makeRenderPass(r: *Renderer) Error!void {
        const attachments = [_]c.VkAttachmentDescription{
            .{
                .format = r.format.format,
                .samples = c.VK_SAMPLE_COUNT_1_BIT,
                .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
                .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
                .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
                .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
                .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
                .finalLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
            },
            .{
                .format = depth_format,
                .samples = c.VK_SAMPLE_COUNT_1_BIT,
                .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
                .storeOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
                .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
                .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
                .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
                .finalLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
            },
        };
        const color_ref: c.VkAttachmentReference = .{ .attachment = 0, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
        const depth_ref: c.VkAttachmentReference = .{ .attachment = 1, .layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL };
        const subpass: c.VkSubpassDescription = .{
            .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS,
            .colorAttachmentCount = 1,
            .pColorAttachments = &color_ref,
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
            .attachmentCount = attachments.len,
            .pAttachments = &attachments,
            .subpassCount = 1,
            .pSubpasses = &subpass,
            .dependencyCount = 1,
            .pDependencies = &dep,
        }, null, &r.render_pass));
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
            .{ .binding = 0, .stride = 24, .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX },
            .{ .binding = 1, .stride = @sizeOf(Instance), .inputRate = c.VK_VERTEX_INPUT_RATE_INSTANCE },
        };
        const box_attrs = [_]c.VkVertexInputAttributeDescription{
            .{ .location = 0, .binding = 0, .format = c.VK_FORMAT_R32G32B32_SFLOAT, .offset = 0 },
            .{ .location = 1, .binding = 0, .format = c.VK_FORMAT_R32G32B32_SFLOAT, .offset = 12 },
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
        r.box_pipeline = try r.pipeline(bv, bf, &box_bindings, &box_attrs, c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST);
        r.grid_pipeline = try r.pipeline(gv, gf, &grid_bindings, &grid_attrs, c.VK_PRIMITIVE_TOPOLOGY_LINE_LIST);
    }

    fn pipeline(
        r: *Renderer,
        vs: c.VkShaderModule,
        fs: c.VkShaderModule,
        bindings: []const c.VkVertexInputBindingDescription,
        attrs: []const c.VkVertexInputAttributeDescription,
        topology: c.VkPrimitiveTopology,
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
            .cullMode = c.VK_CULL_MODE_NONE,
            .frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE,
            .lineWidth = 1,
        };
        const multisample: c.VkPipelineMultisampleStateCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT,
        };
        const depth: c.VkPipelineDepthStencilStateCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
            .depthTestEnable = c.VK_TRUE,
            .depthWriteEnable = c.VK_TRUE,
            .depthCompareOp = c.VK_COMPARE_OP_LESS_OR_EQUAL,
        };
        const blend_attachment: c.VkPipelineColorBlendAttachmentState = .{
            .colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT,
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
            .layout = r.layout,
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
        try check(r.d.vkAllocateMemory.?(r.device, &.{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = req.size,
            .memoryTypeIndex = try r.memoryType(req.memoryTypeBits, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT),
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

    /// The unit box: 6 faces of 4 vertices (corner xyz, normal xyz), and 36
    /// indices. See shaders/box.vert for the frame.
    fn makeBoxMesh(r: *Renderer) Error!void {
        const faces = [6][4][3]f32{
            .{ .{ 0, -1, 0 }, .{ 1, -1, 0 }, .{ 1, 1, 0 }, .{ 0, 1, 0 } }, // top
            .{ .{ 0, -1, -1 }, .{ 0, 1, -1 }, .{ 1, 1, -1 }, .{ 1, -1, -1 } }, // bottom
            .{ .{ 0, 1, -1 }, .{ 0, 1, 0 }, .{ 1, 1, 0 }, .{ 1, 1, -1 } }, // left side
            .{ .{ 0, -1, -1 }, .{ 1, -1, -1 }, .{ 1, -1, 0 }, .{ 0, -1, 0 } }, // right side
            .{ .{ 1, -1, -1 }, .{ 1, 1, -1 }, .{ 1, 1, 0 }, .{ 1, -1, 0 } }, // end
            .{ .{ 0, -1, -1 }, .{ 0, -1, 0 }, .{ 0, 1, 0 }, .{ 0, 1, -1 } }, // start
        };
        const normals = [6][3]f32{ .{ 0, 0, 1 }, .{ 0, 0, -1 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 1, 0, 0 }, .{ -1, 0, 0 } };
        var verts: [24 * 6]f32 = undefined;
        var idx: [36]u16 = undefined;
        for (0..6) |f| {
            for (0..4) |k| {
                const o = (f * 4 + k) * 6;
                @memcpy(verts[o .. o + 3], &faces[f][k]);
                @memcpy(verts[o + 3 .. o + 6], &normals[f]);
            }
            const b: u16 = @intCast(f * 4);
            const q = [6]u16{ b, b + 1, b + 2, b, b + 2, b + 3 };
            @memcpy(idx[f * 6 .. f * 6 + 6], &q);
        }
        try r.makeBuffer(&r.box_mesh, @sizeOf(@TypeOf(verts)), c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        @memcpy(r.box_mesh.map.?[0..@sizeOf(@TypeOf(verts))], std.mem.asBytes(&verts));
        try r.makeBuffer(&r.box_index, @sizeOf(@TypeOf(idx)), c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT);
        @memcpy(r.box_index.map.?[0..@sizeOf(@TypeOf(idx))], std.mem.asBytes(&idx));
    }

    /// Replaces the boxes. Waits for the GPU, because the buffer can be in
    /// use by the frame before.
    pub fn setInstances(r: *Renderer, items: []const Instance) Error!void {
        _ = r.d.vkDeviceWaitIdle.?(r.device);
        const bytes = std.mem.sliceAsBytes(items);
        if (bytes.len > r.instances.size) try r.makeBuffer(&r.instances, bytes.len, c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        @memcpy(r.instances.map.?[0..bytes.len], bytes);
    }

    /// Replaces the grid lines: pairs of points, x, y, z each.
    pub fn setGrid(r: *Renderer, points: []const f32) Error!void {
        _ = r.d.vkDeviceWaitIdle.?(r.device);
        const bytes = std.mem.sliceAsBytes(points);
        if (bytes.len > r.grid.size) try r.makeBuffer(&r.grid, bytes.len, c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        @memcpy(r.grid.map.?[0..bytes.len], bytes);
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
        const alpha: c.VkCompositeAlphaFlagBitsKHR = if (caps.supportedCompositeAlpha & c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR != 0)
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
            .presentMode = c.VK_PRESENT_MODE_FIFO_KHR,
            .clipped = c.VK_TRUE,
            .oldSwapchain = old,
        }, null, &r.swapchain));
        if (old != null) d.vkDestroySwapchainKHR.?(r.device, old, null);
        r.extent = extent;

        var n: u32 = 0;
        try check(d.vkGetSwapchainImagesKHR.?(r.device, r.swapchain, &n, null));
        n = @min(n, max_images);
        try check(d.vkGetSwapchainImagesKHR.?(r.device, r.swapchain, &n, &r.images));

        // The depth buffer.
        try check(d.vkCreateImage.?(r.device, &.{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .imageType = c.VK_IMAGE_TYPE_2D,
            .format = depth_format,
            .extent = .{ .width = extent.width, .height = extent.height, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .tiling = c.VK_IMAGE_TILING_OPTIMAL,
            .usage = c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
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

        for (0..n) |k| {
            try check(d.vkCreateImageView.?(r.device, &.{
                .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .image = r.images[k],
                .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
                .format = r.format.format,
                .subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .levelCount = 1, .layerCount = 1 },
            }, null, &r.views[k]));
            const atts = [_]c.VkImageView{ r.views[k], r.depth_view };
            try check(d.vkCreateFramebuffer.?(r.device, &.{
                .sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
                .renderPass = r.render_pass,
                .attachmentCount = atts.len,
                .pAttachments = &atts,
                .width = extent.width,
                .height = extent.height,
                .layers = 1,
            }, null, &r.framebuffers[k]));
            // One "rendered" semaphore for each image: the present of an
            // image can still wait on its semaphore when the next frame
            // starts.
            try check(d.vkCreateSemaphore.?(r.device, &.{ .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO }, null, &r.rendered[k]));
            r.image_count += 1;
        }
        r.stale = false;
    }

    // ---- frame ----

    pub const Frame = struct {
        clear: [3]f32,
        box: Push,
        box_count: u32,
        grid: Push,
        grid_vertices: u32,
    };

    /// Draws one frame and presents it.
    pub fn draw(r: *Renderer, frame: Frame) Error!void {
        const d = r.d;
        if (r.stale or r.swapchain == null) try r.makeSwapchain();
        if (r.image_count == 0) return;

        try check(d.vkWaitForFences.?(r.device, 1, &r.fence, c.VK_TRUE, std.math.maxInt(u64)));
        var index: u32 = 0;
        const acq = d.vkAcquireNextImageKHR.?(r.device, r.swapchain, std.math.maxInt(u64), r.acquired, null, &index);
        if (acq == c.VK_ERROR_OUT_OF_DATE_KHR) {
            r.stale = true;
            return;
        }
        if (acq != c.VK_SUCCESS and acq != c.VK_SUBOPTIMAL_KHR) return error.VulkanFailed;
        try check(d.vkResetFences.?(r.device, 1, &r.fence));

        const cmd = r.cmd;
        try check(d.vkResetCommandBuffer.?(cmd, 0));
        try check(d.vkBeginCommandBuffer.?(cmd, &.{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        }));
        const clears = [_]c.VkClearValue{
            .{ .color = .{ .float32 = .{ frame.clear[0], frame.clear[1], frame.clear[2], 1 } } },
            .{ .depthStencil = .{ .depth = 1, .stencil = 0 } },
        };
        d.vkCmdBeginRenderPass.?(cmd, &.{
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .renderPass = r.render_pass,
            .framebuffer = r.framebuffers[index],
            .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = r.extent },
            .clearValueCount = clears.len,
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
        if (frame.box_count > 0 and r.instances.buf != null) {
            d.vkCmdBindPipeline.?(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, r.box_pipeline);
            d.vkCmdPushConstants.?(cmd, r.layout, stages, 0, @sizeOf(Push), &frame.box);
            const bufs = [_]c.VkBuffer{ r.box_mesh.buf, r.instances.buf };
            const offs = [_]c.VkDeviceSize{ 0, 0 };
            d.vkCmdBindVertexBuffers.?(cmd, 0, 2, &bufs, &offs);
            d.vkCmdBindIndexBuffer.?(cmd, r.box_index.buf, 0, c.VK_INDEX_TYPE_UINT16);
            d.vkCmdDrawIndexed.?(cmd, 36, frame.box_count, 0, 0, 0);
        }
        d.vkCmdEndRenderPass.?(cmd);
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
};
