//! LayerRenderer: draws the 2D view of one layer with Metal, as
//! web/app/gl.js (draw2d) does with WebGL2 and linux/src/ui/layer-draw.c
//! with cairo.
//!
//! The picture: the bed and its 10 mm grid, the outline of the layer in
//! gray, and each bead as a stroke with round ends in its feature color.
//! The beads are the instances of the 3D view on the GPU (the buffer of
//! FrameRenderer), so a new layer only changes the range of a draw. The
//! outlines go to the GPU once for each slice, as fans of triangles; the
//! stencil buffer fills them by the nonzero rule (an outer ring goes
//! counterclockwise and adds 1, a hole goes clockwise and takes 1 away).
//!
//! The camera maps mm to pixels: a point (x, y) is at
//! (ox + x * scale, oy + y * scale) from the bottom left of the view. The
//! y axis goes up, as on the bed.
//!
//! Reference: the Metal documentation of Apple (see REFERENCES.md).
//!
//! SPDX-License-Identifier: AGPL-3.0-or-later

import CZslice
@preconcurrency import Metal
import QuartzCore
import simd

/// The uniforms of line_vertex (Line2D in Shaders.swift).
private struct Line2D {
    var xf: SIMD4<Float>
    var solid: SIMD3<Float> = .zero
    var px: Float = 0
    var grow: Float = 1
    var kind: Float = 0
    var mask: Float = 0
    var dim: Float = 0
}

/// The uniforms of flat_vertex (Flat2D in Shaders.swift).
private struct Flat2D {
    var xf: SIMD4<Float>
    var color: SIMD4<Float>
    var size = SIMD2<Float>(1, 1)
    var stride: UInt32 = 2
}

/// What to draw: the camera, the layer, and the bead ranges.
struct LayerFrame {
    var width = 1, height = 1
    var scale: Double = 1, ox: Double = 0, oy: Double = 0
    var layer = 0
    var beads: (UInt32, UInt32) = (0, 0)
    var marks: (UInt32, UInt32) = (0, 0)
    /// The beads of the selected path, or (0, 0), and the bead of the
    /// selected segment.
    var selection: (UInt32, UInt32) = (0, 0)
    var segment: Int = -1
    var mask: UInt32 = 0
    var dim = false
    var dark = false
}

@MainActor
final class LayerRenderer {
    private let r: FrameRenderer
    private let line: MTLRenderPipelineState
    private let flat: MTLRenderPipelineState
    private let flatStencil: MTLRenderPipelineState
    private let noStencil: MTLDepthStencilState
    private let countTurns: MTLDepthStencilState
    private let fillTurns: MTLDepthStencilState
    private var outlinePoints: MTLBuffer?
    private var outlineIndex: MTLBuffer?
    private var outlineLayerEnd: [Int] = []
    private var quad: MTLBuffer?
    private var msaa: MTLTexture?
    private var stencil: MTLTexture?
    /// The bed size, from the grid of the 3D view.
    private(set) var bed = SIMD2<Float>(220, 220)

    // The bits of the marks in a focus mask (ZS_MARK_SEAM and on).
    private static let markBits: UInt32 = (1 << 11) | (1 << 12) | (1 << 13)

    init?(_ r: FrameRenderer) {
        self.r = r
        let device = r.device
        let lib = r.library
        func pipeline(_ v: String, _ f: String, color: Bool) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: v)
            d.fragmentFunction = lib.makeFunction(name: f)
            d.rasterSampleCount = FrameRenderer.sampleCount
            d.colorAttachments[0].pixelFormat = FrameRenderer.colorFormat
            if !color { d.colorAttachments[0].writeMask = [] }
            d.stencilAttachmentPixelFormat = .stencil8
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let line = pipeline("line_vertex", "line_fragment", color: true),
              let flat = pipeline("flat_vertex", "flat_fragment", color: true),
              let flatStencil = pipeline("flat_vertex", "flat_fragment", color: false) else { return nil }
        self.line = line
        self.flat = flat
        self.flatStencil = flatStencil
        noStencil = device.makeDepthStencilState(descriptor: MTLDepthStencilDescriptor())!
        let count = MTLDepthStencilDescriptor()
        let front = MTLStencilDescriptor(), back = MTLStencilDescriptor()
        front.depthStencilPassOperation = .incrementWrap
        back.depthStencilPassOperation = .decrementWrap
        count.frontFaceStencil = front
        count.backFaceStencil = back
        countTurns = device.makeDepthStencilState(descriptor: count)!
        let fill = MTLDepthStencilDescriptor()
        let test = MTLStencilDescriptor()
        test.stencilCompareFunction = .notEqual
        test.stencilFailureOperation = .zero
        test.depthStencilPassOperation = .zero
        fill.frontFaceStencil = test
        fill.backFaceStencil = test
        fillTurns = device.makeDepthStencilState(descriptor: fill)!
        let corners: [Float] = [0, 0, 1, 0, 0, 1, 1, 1]
        quad = device.makeBuffer(bytes: corners, length: corners.count * 4, options: .storageModeShared)
    }

    /// The outlines of all layers (zs_view_outlines), after a load: the
    /// fan of each ring, and the index range of each layer.
    func setOutlines(from view: OpaquePointer) {
        var pts: UnsafePointer<Float>?
        var nPoints = 0
        var ringEnds: UnsafePointer<UInt32>?
        var nRings = 0
        var layerEnds: UnsafePointer<UInt32>?
        var nLayers = 0
        outlineLayerEnd = []
        outlinePoints = nil
        outlineIndex = nil
        guard zs_view_outlines(view, &pts, &nPoints, &ringEnds, &nRings, &layerEnds, &nLayers) == 0,
              let pts, let ringEnds, let layerEnds, nPoints > 0 else { return }
        var index: [UInt32] = []
        var ring = 0
        for l in 0 ..< nLayers {
            while ring < Int(layerEnds[l]) {
                let a = ring > 0 ? ringEnds[ring - 1] : 0
                let b = ringEnds[ring]
                var k = a + 1
                while k + 1 < b {
                    index += [a, k, k + 1]
                    k += 1
                }
                ring += 1
            }
            outlineLayerEnd.append(index.count)
        }
        outlinePoints = r.buffer(pts, nPoints * 8)
        outlineIndex = index.withUnsafeBytes { r.buffer($0.baseAddress, $0.count) }
    }

    /// Takes the bed size from the grid points of the 3D view (vec3): the
    /// largest x and y.
    func setBed(from frame: zs_web_frame) {
        guard let p = frame.grid_points, frame.grid_vertices > 0 else { return }
        var bx: Float = 0, by: Float = 0
        for i in 0 ..< Int(frame.grid_vertices) {
            bx = max(bx, p[3 * i])
            by = max(by, p[3 * i + 1])
        }
        bed = SIMD2(bx > 0 ? bx : 220, by > 0 ? by : 220)
    }

    private func targets(_ w: Int, _ h: Int) {
        if let msaa, msaa.width == w, msaa.height == h { return }
        let c = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: FrameRenderer.colorFormat, width: w, height: h, mipmapped: false)
        c.textureType = .type2DMultisample
        c.sampleCount = FrameRenderer.sampleCount
        c.usage = .renderTarget
        c.storageMode = .private
        msaa = r.device.makeTexture(descriptor: c)
        let s = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .stencil8, width: w, height: h, mipmapped: false)
        s.textureType = .type2DMultisample
        s.sampleCount = FrameRenderer.sampleCount
        s.usage = .renderTarget
        s.storageMode = .memoryless
        stencil = r.device.makeTexture(descriptor: s)
    }

    func draw(_ s: LayerFrame, in layer: CAMetalLayer, snapshot: (@Sendable (CGImage) -> Void)? = nil) {
        guard let drawable = layer.nextDrawable(), let cmd = r.queue.makeCommandBuffer() else { return }
        targets(max(1, s.width), max(1, s.height))
        let desc = MTLRenderPassDescriptor()
        let back: SIMD3<Double> = s.dark ? [0.114, 0.114, 0.125] : [0.965, 0.969, 0.973]
        desc.colorAttachments[0].texture = msaa
        desc.colorAttachments[0].resolveTexture = drawable.texture
        desc.colorAttachments[0].loadAction = .clear
        desc.colorAttachments[0].storeAction = .multisampleResolve
        desc.colorAttachments[0].clearColor = MTLClearColor(red: back.x, green: back.y, blue: back.z, alpha: 1)
        desc.stencilAttachment.texture = stencil
        desc.stencilAttachment.loadAction = .clear
        desc.stencilAttachment.storeAction = .dontCare
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: desc) else { return }
        enc.setCullMode(.none)
        enc.setFrontFacing(.counterClockwise)
        let xf = SIMD4<Float>(Float(2 * s.scale / Double(s.width)), Float(2 * s.scale / Double(s.height)),
                              Float(2 * s.ox / Double(s.width) - 1), Float(2 * s.oy / Double(s.height) - 1))

        // The bed and its grid.
        enc.setRenderPipelineState(flat)
        enc.setDepthStencilState(noStencil)
        var u = Flat2D(xf: xf, color: s.dark ? [0.16, 0.16, 0.18, 1] : [0.906, 0.914, 0.925, 1], size: bed)
        enc.setVertexBuffer(quad, offset: 0, index: 0)
        setFlat(enc, &u)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        if let grid = r.gridPoints, r.gridVertices > 0 {
            u = Flat2D(xf: xf, color: s.dark ? [0.25, 0.26, 0.28, 1] : [0.82, 0.84, 0.86, 1], stride: 3)
            setFlat(enc, &u)
            enc.setVertexBuffer(grid, offset: 0, index: 0)
            enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: r.gridVertices)
        }

        // The outline: the stencil counts the turns of the fans, then the
        // area with a count other than 0 gets the color (and a count of 0).
        if s.layer < outlineLayerEnd.count, let pts = outlinePoints, let index = outlineIndex {
            let i0 = s.layer > 0 ? outlineLayerEnd[s.layer - 1] : 0
            let i1 = outlineLayerEnd[s.layer]
            if i1 > i0 {
                u = Flat2D(xf: xf, color: s.dark ? [0.30, 0.31, 0.34, 1] : [0.80, 0.83, 0.86, 1])
                setFlat(enc, &u)
                enc.setVertexBuffer(pts, offset: 0, index: 0)
                enc.setRenderPipelineState(flatStencil)
                enc.setDepthStencilState(countTurns)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: i1 - i0, indexType: .uint32, indexBuffer: index, indexBufferOffset: i0 * 4)
                enc.setRenderPipelineState(flat)
                enc.setDepthStencilState(fillTurns)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: i1 - i0, indexType: .uint32, indexBuffer: index, indexBufferOffset: i0 * 4)
                enc.setDepthStencilState(noStencil)
            }
        }

        // The beads.
        if let inst = r.instances {
            enc.setRenderPipelineState(line)
            enc.setVertexBuffer(inst, offset: 0, index: 1)
            // Half a pixel in mm: a thin line stays visible far out.
            let base = Line2D(xf: xf, px: Float(0.5 / s.scale), mask: Float(s.mask), dim: s.dim ? 1 : 0)
            func lines(_ first: UInt32, _ end: UInt32, kind: Float, grow: Float = 1, color: SIMD3<Float> = .zero) {
                guard end > first else { return }
                var l = base
                l.kind = kind
                l.grow = grow
                l.solid = color
                enc.setVertexBytes(&l, length: MemoryLayout<Line2D>.stride, index: 2)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: Int(end - first), baseInstance: Int(first))
            }
            let sel = s.selection
            // The selected path: a wide yellow line under the paths.
            if sel.1 > sel.0 { lines(sel.0, sel.1, kind: 1, grow: 2.5, color: [1.0, 0.82, 0.1]) }
            lines(s.beads.0, s.beads.1, kind: 0)
            // The marks of a focus on them (seams, travel moves, retractions).
            if s.mask & Self.markBits != 0 { lines(s.marks.0, s.marks.1, kind: 2) }
            // The selected path again, on top, and its segment in orange.
            if sel.1 > sel.0 {
                lines(sel.0, sel.1, kind: 1, color: [1.0, 0.78, 0.05])
                if s.segment >= 0 { lines(UInt32(s.segment), UInt32(s.segment + 1), kind: 1, grow: 1.6, color: [1.0, 0.35, 0.0]) }
            }
        }
        enc.endEncoding()
        if let snapshot { r.copyOut(drawable.texture, in: cmd, then: snapshot) }
        cmd.present(drawable)
        cmd.commit()
    }

    private func setFlat(_ enc: MTLRenderCommandEncoder, _ u: inout Flat2D) {
        enc.setVertexBytes(&u, length: MemoryLayout<Flat2D>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<Flat2D>.stride, index: 0)
    }
}
