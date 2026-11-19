//! FrameRenderer: draws the frame data of the 3D view with Metal.
//!
//! On macOS the core does not draw. After each zs_view_draw, the view
//! keeps the data of the frame (zs_web_frame): the bead instances, the
//! bead mesh, the grid, the bed model, the other plates, and the push
//! constants. This file reads that data and makes the draw calls of the
//! Vulkan backend (src/render/vk.zig): the grid lines, the beads (instanced
//! draws of one bead mesh), the marks, the beads out of a focus as ghosts
//! (blended, no depth write), the bed model, the extras, and the
//! see-through toolhead of a replay. web/app/gl.js does the same with
//! WebGL2.
//!
//! A buffer goes to the GPU again only when its generation changes. Each
//! upload makes a new MTLBuffer, so a frame that the GPU still draws keeps
//! its old buffer. The scene changes only after a slice, so this costs
//! little.
//!
//! Reference: the Metal documentation of Apple (see REFERENCES.md).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import CZslice
@preconcurrency import Metal
import QuartzCore
import simd

/// The values of the shaders that the core does not give (Extra in
/// Shaders.swift).
private struct Extra {
    var hoff: Float = 0
    var fade: Float = 0
    var background: SIMD3<Float> = .zero
}

private let instanceStride = 32 // MemoryLayout<zs_web_instance>.stride
private let noHighlight: Float = 1e9

@MainActor
final class FrameRenderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    private let boxOpaque: MTLRenderPipelineState
    /// The beads with a focus (a discard for the beads out of it).
    private let boxFocus: MTLRenderPipelineState
    private let boxBlend: MTLRenderPipelineState
    private let grid: MTLRenderPipelineState
    private let bed: MTLRenderPipelineState
    /// The bed model, depth only: the first of its two passes.
    private let bedDepth: MTLRenderPipelineState
    private let depthWrite: MTLDepthStencilState
    private let depthRead: MTLDepthStencilState
    /// Only where the depth is the same, with no write: the color pass of
    /// the bed model.
    private let depthEqual: MTLDepthStencilState
    private let sampler: MTLSamplerState
    static let sampleCount = 4
    static let colorFormat = MTLPixelFormat.bgra8Unorm

    // The buffers of the scene, and the generation of each.
    private var meshVerts: MTLBuffer?
    private var meshIndex: MTLBuffer?
    private var meshFull = 0
    private var lod: [(first: Int, count: Int)] = [(0, 0), (0, 0)]
    private(set) var instances: MTLBuffer?
    private var instanceCount = 0
    private(set) var gridPoints: MTLBuffer?
    private var bedVerts: MTLBuffer?
    private var bedVertexCount = 0
    private var bedTexture: MTLTexture?
    private var plateGrid: MTLBuffer?
    private var slots: [UInt32: (buffer: MTLBuffer?, gen: UInt32)] = [:]
    private(set) var gridVertices = 0
    private var gen = (mesh: UInt32.max, instances: UInt32.max, grid: UInt32.max, bed: UInt32.max, plateGrid: UInt32.max)

    // The targets: the multisample color and the depth, at the drawable size.
    private var msaa: MTLTexture?
    private var depth: MTLTexture?

    /// The shaders, compiled once for the app (a compile takes long, and
    /// each window and the 2D page use the same library).
    nonisolated(unsafe) private static var shared: MTLLibrary?
    let library: MTLLibrary

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        do {
            let t = CACurrentMediaTime()
            let lib = try Self.shared ?? device.makeLibrary(source: shaderSource, options: nil)
            if Self.shared == nil, ProcessInfo.processInfo.environment["ZSLICE_TIMING"] != nil {
                NSLog("zslice timing: shaders compiled in %.0f ms", (CACurrentMediaTime() - t) * 1000)
            }
            Self.shared = lib
            library = lib
            func pipeline(_ vertex: String, _ fragment: String, blend: Bool, color: Bool = true) throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = lib.makeFunction(name: vertex)
                d.fragmentFunction = lib.makeFunction(name: fragment)
                d.rasterSampleCount = Self.sampleCount
                d.colorAttachments[0].pixelFormat = Self.colorFormat
                d.depthAttachmentPixelFormat = .depth32Float
                if !color { d.colorAttachments[0].writeMask = [] }
                if blend {
                    let c = d.colorAttachments[0]!
                    c.isBlendingEnabled = true
                    c.sourceRGBBlendFactor = .sourceAlpha
                    c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                    c.sourceAlphaBlendFactor = .sourceAlpha
                    c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                }
                return try device.makeRenderPipelineState(descriptor: d)
            }
            // ZSLICE_DISCARD_SHADER=1: the plain beads with the shader of a
            // focus, to measure the cost of a discard (for tests).
            let plain = ProcessInfo.processInfo.environment["ZSLICE_DISCARD_SHADER"] != nil ? "box_fragment_focus" : "box_fragment"
            boxOpaque = try pipeline("box_vertex", plain, blend: false)
            boxFocus = try pipeline("box_vertex", "box_fragment_focus", blend: false)
            boxBlend = try pipeline("box_vertex", "box_fragment_focus", blend: true)
            grid = try pipeline("grid_vertex", "grid_fragment", blend: false)
            bed = try pipeline("bed_vertex", "bed_fragment", blend: true)
            bedDepth = try pipeline("bed_vertex", "bed_fragment", blend: false, color: false)
        } catch {
            NSLog("zslice: the Metal shaders did not compile: \(error)")
            return nil
        }
        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .lessEqual
        ds.isDepthWriteEnabled = true
        depthWrite = device.makeDepthStencilState(descriptor: ds)!
        ds.isDepthWriteEnabled = false
        depthRead = device.makeDepthStencilState(descriptor: ds)!
        ds.depthCompareFunction = .equal
        depthEqual = device.makeDepthStencilState(descriptor: ds)!
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: sd)!
    }

    func buffer(_ ptr: UnsafeRawPointer?, _ length: Int) -> MTLBuffer? {
        guard let ptr, length > 0 else { return nil }
        return device.makeBuffer(bytes: ptr, length: length, options: .storageModeShared)
    }

    /// Sends the buffers of the frame that changed to the GPU.
    func sync(_ f: zs_web_frame) {
        if f.mesh_gen != gen.mesh {
            meshVerts = buffer(f.mesh_verts, Int(f.mesh_vert_count) * 16)
            meshIndex = buffer(f.mesh_index, Int(f.mesh_index_count) * 2)
            meshFull = Int(f.mesh_full_count != 0 ? f.mesh_full_count : f.mesh_index_count)
            lod = [(Int(f.mesh_lod_first.0), Int(f.mesh_lod_count.0)), (Int(f.mesh_lod_first.1), Int(f.mesh_lod_count.1))]
            gen.mesh = f.mesh_gen
        }
        if f.instances_gen != gen.instances {
            instances = buffer(f.instances, Int(f.instance_count) * instanceStride)
            instanceCount = Int(f.instance_count)
            gen.instances = f.instances_gen
        }
        if f.grid_gen != gen.grid {
            gridPoints = buffer(f.grid_points, Int(f.grid_vertices) * 12)
            gridVertices = Int(f.grid_vertices)
            gen.grid = f.grid_gen
        }
        if f.bed_gen != gen.bed {
            // The bed model is static: it goes to the GPU once for each printer.
            bedVerts = buffer(f.bed_verts, Int(f.bed_vertex_count) * 32)
            bedVertexCount = Int(f.bed_vertex_count)
            bedTexture = makeTexture(f.bed_tex, Int(f.bed_tex_width), Int(f.bed_tex_height))
            gen.bed = f.bed_gen
        }
        if f.plate_grid_gen != gen.plateGrid {
            plateGrid = buffer(f.plate_grid, Int(f.plate_grid_vertices) * 12)
            gen.plateGrid = f.plate_grid_gen
        }
        // The bead buffers of the plates in the frame, one for each slot.
        for p in plates(f) where slots[p.slot]?.gen != p.gen {
            slots[p.slot] = (buffer(p.instances, Int(p.instance_count) * instanceStride), p.gen)
        }
    }

    private func makeTexture(_ rgba: UnsafePointer<UInt8>?, _ w: Int, _ h: Int) -> MTLTexture? {
        let white: [UInt8] = [255, 255, 255, 255]
        let (width, height) = rgba != nil && w > 0 ? (w, h) : (1, 1)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        let region = MTLRegionMake2D(0, 0, width, height)
        if let rgba, w > 0 {
            t.replace(region: region, mipmapLevel: 0, withBytes: rgba, bytesPerRow: width * 4)
        } else {
            white.withUnsafeBytes { t.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 4) }
        }
        return t
    }

    private func plates(_ f: zs_web_frame) -> UnsafeBufferPointer<zs_web_plate> {
        UnsafeBufferPointer(start: f.plates, count: f.plates == nil ? 0 : Int(f.plates_count))
    }

    private func draws(_ ptr: UnsafePointer<zs_web_draw>?, _ count: UInt32) -> UnsafeBufferPointer<zs_web_draw> {
        UnsafeBufferPointer(start: ptr, count: ptr == nil ? 0 : Int(count))
    }

    private func targets(for size: CGSize) {
        let w = max(1, Int(size.width)), h = max(1, Int(size.height))
        if let msaa, msaa.width == w, msaa.height == h { return }
        let c = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.colorFormat, width: w, height: h, mipmapped: false)
        c.textureType = .type2DMultisample
        c.sampleCount = Self.sampleCount
        c.usage = .renderTarget
        c.storageMode = .private
        msaa = device.makeTexture(descriptor: c)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: w, height: h, mipmapped: false)
        d.textureType = .type2DMultisample
        d.sampleCount = Self.sampleCount
        d.usage = .renderTarget
        d.storageMode = .memoryless
        depth = device.makeTexture(descriptor: d)
    }

    /// Draws one frame into the next drawable of the layer. With
    /// `snapshot`, it also gives the frame as an image, on a thread of
    /// Metal (the layer must not be framebufferOnly).
    func draw(_ f: zs_web_frame, in layer: CAMetalLayer, snapshot: (@Sendable (CGImage) -> Void)? = nil) {
        sync(f)
        guard let drawable = layer.nextDrawable(), let cmd = queue.makeCommandBuffer() else { return }
        targets(for: layer.drawableSize)
        let desc = MTLRenderPassDescriptor()
        desc.colorAttachments[0].texture = msaa
        desc.colorAttachments[0].resolveTexture = drawable.texture
        desc.colorAttachments[0].loadAction = .clear
        desc.colorAttachments[0].storeAction = .multisampleResolve
        desc.colorAttachments[0].clearColor = MTLClearColor(red: Double(f.clear.0), green: Double(f.clear.1), blue: Double(f.clear.2), alpha: 1)
        desc.depthAttachment.texture = depth
        desc.depthAttachment.loadAction = .clear
        desc.depthAttachment.storeAction = .dontCare
        desc.depthAttachment.clearDepth = 1
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: desc) else { return }
        enc.setCullMode(.none)
        enc.setDepthStencilState(depthWrite)
        var pass = Pass(f: f, r: self, enc: enc)
        pass.run()
        enc.endEncoding()
        if let snapshot { copyOut(drawable.texture, in: cmd, then: snapshot) }
        cmd.present(drawable)
        let gpu = gpuTime
        cmd.addCompletedHandler { cb in gpu.set((cb.gpuEndTime - cb.gpuStartTime) * 1000) }
        cmd.commit()
    }

    /// Back face culling of the beads (ZSLICE_NO_CULL=1 turns it off, to
    /// compare), and the winding of a front face in the frame of Metal.
    let cull = ProcessInfo.processInfo.environment["ZSLICE_NO_CULL"] == nil
    static let front: MTLWinding = ProcessInfo.processInfo.environment["ZSLICE_CULL_CW"] != nil ? .clockwise : .counterClockwise

    /// The GPU time of the last frame that is done (ms), for the tests of
    /// the frame time (ZSLICE_ORBIT_TEST).
    let gpuTime = GPUTime()
    var lastGPUms: Double { gpuTime.ms }

    /// Copies the texture to a buffer, and makes an image of it when the
    /// GPU is done. For development and screenshots (ZSLICE_SNAPSHOT).
    func copyOut(_ tex: MTLTexture, in cmd: MTLCommandBuffer, then done: @escaping @Sendable (CGImage) -> Void) {
        let w = tex.width, h = tex.height, row = w * 4
        guard let made = device.makeBuffer(length: row * h, options: .storageModeShared), let blit = cmd.makeBlitCommandEncoder() else { return }
        blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: made, destinationOffset: 0, destinationBytesPerRow: row, destinationBytesPerImage: row * h)
        blit.endEncoding()
        nonisolated(unsafe) let buf = made
        cmd.addCompletedHandler { _ in
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            guard let ctx = CGContext(data: buf.contents(), width: w, height: h, bitsPerComponent: 8, bytesPerRow: row,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info.rawValue),
                  let image = ctx.makeImage() else { return }
            done(image)
        }
    }

    /// The draw calls of one frame.
    @MainActor
    private struct Pass {
        let f: zs_web_frame
        let r: FrameRenderer
        let enc: MTLRenderCommandEncoder
        var extra = Extra()

        init(f: zs_web_frame, r: FrameRenderer, enc: MTLRenderCommandEncoder) {
            self.f = f
            self.r = r
            self.enc = enc
            extra.background = SIMD3(f.clear.0, f.clear.1, f.clear.2)
        }

        mutating func run() {
            drawGrids()
            if r.meshVerts == nil || r.meshIndex == nil || r.instances == nil {
                drawBed(mvp: f.bed.mvp)
                return
            }
            // The plain pipeline with no focus: the early depth test stays on.
            enc.setRenderPipelineState(f.box.params.2 != 0 ? r.boxFocus : r.boxOpaque)
            // A bead is a closed mesh, wound the same way: its back faces are
            // always behind its front faces. Culling them gives the same
            // picture with half the triangles (web/app/gl.js).
            if r.cull {
                enc.setFrontFacing(FrameRenderer.front)
                enc.setCullMode(.back)
            }
            setPush(f.box)
            drawList(first: min(f.box_first, f.box_count))
            // A part that turns in the view only (zs_view_part_preview: a
            // fall, a turn): its beads with its own matrix.
            if f.part_draws_count > 0 {
                setPush(f.part)
                for d in r.draws(f.part_draws, f.part_draws_count) {
                    drawBeads(first: Int(d.first), count: Int(d.count), lod: Int(d.lod))
                }
                setPush(f.box)
            }
            drawBeads(first: Int(f.mark_first), count: Int(f.mark_count))
            drawPlates(ghost: nil)
            enc.setCullMode(.none)
            // With a focus: the beads out of it, as ghosts (params.w = 2).
            if f.box.params.2 != 0 {
                var ghost = f.box
                ghost.params.3 = 2
                enc.setRenderPipelineState(r.boxBlend)
                enc.setDepthStencilState(r.depthRead)
                setPush(ghost)
                drawList(first: min(f.box_first, f.box_count))
                drawPlates(ghost: ghost)
                drawBeads(first: Int(f.mark_first), count: Int(f.mark_count))
                enc.setDepthStencilState(r.depthWrite)
            }
            drawBed(mvp: f.bed.mvp)
            // The bed model at each other plate of the same printer.
            for p in r.plates(f) where p.flags & 1 != 0 { drawBed(mvp: p.bed_mvp) }
            drawExtras()
        }

        func setPush(_ push: zs_web_push) {
            var p = push
            enc.setVertexBytes(&p, length: MemoryLayout<zs_web_push>.size, index: 2)
            enc.setFragmentBytes(&p, length: MemoryLayout<zs_web_push>.size, index: 0)
        }

        func setExtra(_ e: Extra) {
            var e = e
            enc.setVertexBytes(&e, length: MemoryLayout<Extra>.stride, index: 3)
            enc.setFragmentBytes(&e, length: MemoryLayout<Extra>.stride, index: 1)
        }

        func drawGrids() {
            enc.setRenderPipelineState(r.grid)
            var push = f.grid
            enc.setVertexBytes(&push, length: MemoryLayout<zs_web_push>.size, index: 1)
            var color = SIMD4<Float>(f.grid.vec.0, f.grid.vec.1, f.grid.vec.2, 1)
            enc.setFragmentBytes(&color, length: 16, index: 0)
            if let g = r.gridPoints, f.grid_vertices > 0 {
                enc.setVertexBuffer(g, offset: 0, index: 0)
                enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: Int(f.grid_vertices))
            }
            // The grids of the other plates: the plates that cannot slice in
            // a lighter color.
            if let g = r.plateGrid, f.plate_grid_vertices > 0 {
                enc.setVertexBuffer(g, offset: 0, index: 0)
                if f.plate_grid_dim > 0 {
                    enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: Int(f.plate_grid_dim))
                }
                if f.plate_grid_vertices > f.plate_grid_dim {
                    var light = SIMD4<Float>(0.88, 0.89, 0.91, 1)
                    enc.setFragmentBytes(&light, length: 16, index: 0)
                    enc.drawPrimitives(type: .line, vertexStart: Int(f.plate_grid_dim), vertexCount: Int(f.plate_grid_vertices - f.plate_grid_dim))
                }
            }
        }

        /// Draws the beads first ..< first + count of a buffer with the
        /// full mesh, or with a coarser mesh (lod 1 or 2) if there is one.
        func drawBeads(first: Int, count: Int, lod: Int = 0, buffer: MTLBuffer? = nil, hoff: Float = 0) {
            guard count > 0, let buf = buffer ?? r.instances, let verts = r.meshVerts, let index = r.meshIndex else { return }
            var e = extra
            e.hoff = hoff
            setExtra(e)
            enc.setVertexBuffer(verts, offset: 0, index: 0)
            enc.setVertexBuffer(buf, offset: 0, index: 1)
            var start = 0, n = r.meshFull
            if lod > 0, r.lod[lod - 1].count > 0 { (start, n) = r.lod[lod - 1] }
            enc.drawIndexedPrimitives(type: .triangle, indexCount: n, indexType: .uint16, indexBuffer: index,
                                      indexBufferOffset: start * 2, instanceCount: count, baseVertex: 0, baseInstance: first)
        }

        /// The beads of the frame: its draw list, the last ranges first
        /// (the top layers, so the depth test drops hidden pixels early).
        /// An empty list draws no bead.
        func drawList(first: UInt32) {
            for d in r.draws(f.draws, f.draws_count).reversed() {
                drawBeads(first: Int(d.first), count: Int(d.count), lod: Int(d.lod))
            }
        }

        /// The beads of the other plates, and the light beads of the active
        /// plate (flag 2, or flag 4 while its part moves), each with its
        /// matrix, its fade, and its draws. With `ghost`: only the light
        /// beads of the active plate.
        mutating func drawPlates(ghost: zs_web_push?) {
            let all = r.draws(f.plate_draws, f.plate_draws_count)
            for p in r.plates(f) where p.draws_count > 0 {
                guard let slot = r.slots[p.slot], let buf = slot.buffer else { continue }
                let active = p.flags & 2 != 0
                let moving = p.flags & 4 != 0
                if ghost != nil && !active { continue }
                if moving {
                    // The light beads of a part that moves in the view
                    // only: the push data of the part (its matrix and its
                    // turned light).
                    setPush(f.part)
                } else if active {
                    setPush(ghost ?? f.box)
                } else {
                    // The push data of the frame, with the matrix of the
                    // plate, no highlight, and no focus.
                    var push = f.box
                    push.mvp = p.mvp
                    push.params.0 = 0
                    push.params.1 = 0
                    push.params.2 = 0
                    setPush(push)
                }
                extra.fade = p.fade
                let d0 = Int(p.draws_first)
                for d in all[d0 ..< min(all.count, d0 + Int(p.draws_count))] {
                    drawBeads(first: Int(d.first), count: Int(d.count), lod: Int(d.lod), buffer: buf, hoff: noHighlight)
                }
            }
            extra.fade = 0
            setPush(ghost ?? f.box)
        }

        /// The bed model, after the beads: blended, with a depth offset so
        /// the grid lines stay in front. Two passes, so each pixel blends
        /// once, with the nearest face of the bed model (web/app/gl.js):
        /// first the depth only, then the color where the depth is that
        /// depth. In one pass, the see-through faces (alpha 0.3) over each
        /// other added up in the order of the triangles, and the triangles
        /// of the mesh showed.
        func drawBed(mvp: (Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float)) {
            guard f.bed_vertices > 0, r.bedVertexCount > 0, let verts = r.bedVerts else { return }
            var m = mvp
            enc.setVertexBuffer(verts, offset: 0, index: 0)
            enc.setVertexBytes(&m, length: 64, index: 1)
            var push = f.bed
            enc.setFragmentBytes(&push, length: MemoryLayout<zs_web_push>.size, index: 0)
            enc.setFragmentTexture(r.bedTexture, index: 0)
            enc.setFragmentSamplerState(r.sampler, index: 0)
            enc.setDepthBias(4, slopeScale: 2, clamp: 0)
            let count = min(Int(f.bed_vertices), r.bedVertexCount)
            enc.setRenderPipelineState(r.bedDepth)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count)
            enc.setRenderPipelineState(r.bed)
            enc.setDepthStencilState(r.depthEqual)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count)
            enc.setDepthStencilState(r.depthWrite)
            enc.setDepthBias(0, slopeScale: 0, clamp: 0)
        }

        /// The extras (the bead that the replay prints, the frame of a
        /// selected part) and the see-through toolhead of a replay. They
        /// change each frame, so they go in a buffer of this frame.
        func drawExtras() {
            let ne = f.extras == nil ? 0 : Int(f.extras_count)
            let nh = f.head == nil ? 0 : Int(f.head_count)
            if ne + nh == 0 { return }
            enc.setRenderPipelineState(r.boxOpaque)
            setPush(f.box)
            if ne > 0, let b = r.buffer(f.extras, ne * instanceStride) {
                drawBeads(first: 0, count: ne, buffer: b, hoff: Float(r.instanceCount))
            }
            if nh > 0, let b = r.buffer(f.head, nh * instanceStride) {
                var see = f.box
                see.params.2 = 0
                see.params.3 = 3
                enc.setRenderPipelineState(r.boxBlend)
                enc.setDepthStencilState(r.depthRead)
                setPush(see)
                drawBeads(first: 0, count: nh, buffer: b, hoff: Float(r.instanceCount + ne))
                enc.setDepthStencilState(r.depthWrite)
            }
        }
    }
}

/// The GPU time of a frame, set on a thread of Metal.
final class GPUTime: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0
    var ms: Double { lock.withLock { value } }
    func set(_ v: Double) { lock.withLock { value = v } }
}
