//
//  RabbitHoleTransitionView.swift
//  ClipContentRendering
//
//  A self-contained, GPU halftone transition between two screen snapshots, used by
//  the RabbitHole reader for dive / pop / overscroll. Driven by a single `progress`
//  (0 = before, 1 = after); see RabbitHoleTransition.metal for the phase mapping.
//  Knows nothing about the reader — the app wires it to the reader's transition
//  protocol. The shipping HalftoneEffectView is untouched.
//

import Metal
import MetalKit
import UIKit
import simd

/// Visual parameters for the transition's dots (supplied by the app from the
/// halftone settings so the look matches the rest of the app).
public struct RabbitHoleTransitionStyle {
    public var cellSize: CGFloat       // points
    public var dotScale: CGFloat
    public var cornerRadius: CGFloat   // 0 square … 1 circle
    public var edgeSoftness: CGFloat   // px
    public var gapColor: UIColor
    public var monochrome: Bool

    public init(cellSize: CGFloat = 14, dotScale: CGFloat = 0.82, cornerRadius: CGFloat = 1.0,
                edgeSoftness: CGFloat = 1.0, gapColor: UIColor = .black, monochrome: Bool = false) {
        self.cellSize = cellSize
        self.dotScale = dotScale
        self.cornerRadius = cornerRadius
        self.edgeSoftness = edgeSoftness
        self.gapColor = gapColor
        self.monochrome = monochrome
    }
}

public final class RabbitHoleTransitionView: UIView {

    // Must match RHTransitionUniforms in RabbitHoleTransition.metal exactly.
    private struct Uniforms {
        var resolution = SIMD2<Float>(0, 0)
        var revealCenter = SIMD2<Float>(0, 0)
        var gapColor = SIMD4<Float>(0, 0, 0, 1)
        var cellSize: Float = 14
        var dotScale: Float = 0.82
        var cornerRadius: Float = 1
        var edgeSoftness: Float = 1
        var revealRadius: Float = 0
        var revealEdge: Float = 1
        var abMix: Float = 0
        var monochrome: Float = 0
    }

    public var style = RabbitHoleTransitionStyle() { didSet { renderFrame() } }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var texA: MTLTexture?
    private var texB: MTLTexture?
    private var uniforms = Uniforms()

    private var origin: CGPoint = .zero      // points, container space
    private var progress: CGFloat = 0
    private let drawableScale: CGFloat

    private var link: CADisplayLink?
    private var animFrom: CGFloat = 0
    private var animTo: CGFloat = 0
    private var animStart: CFTimeInterval = 0
    private var animDuration: TimeInterval = 0
    private var animCompletion: (() -> Void)?

    public override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    /// Returns nil when Metal or the shader library is unavailable (caller falls back
    /// to an instant cut).
    public static func make() -> RabbitHoleTransitionView? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        let library = (try? device.makeDefaultLibrary(bundle: .module))
            ?? (try? device.makeDefaultLibrary(bundle: Bundle(for: RabbitHoleTransitionView.self)))
        guard let lib = library,
              let vfn = lib.makeFunction(name: "rh_transition_vertex"),
              let ffn = lib.makeFunction(name: "rh_transition_fragment") else { return nil }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        return RabbitHoleTransitionView(device: device, queue: queue, pipeline: pipeline)
    }

    private init(device: MTLDevice, queue: MTLCommandQueue, pipeline: MTLRenderPipelineState) {
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.drawableScale = min(UIScreen.main.scale, 2)
        super.init(frame: .zero)
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        isUserInteractionEnabled = false
    }

    public required init?(coder: NSCoder) { fatalError("not used") }
    deinit { link?.invalidate() }

    // MARK: - Public driving API

    /// Load the before/after snapshots and the radiating origin (container points).
    public func configure(before: UIImage, after: UIImage, origin: CGPoint) {
        self.origin = origin
        texA = makeTexture(before)
        texB = makeTexture(after)
        setProgress(progress)
    }

    /// 0 = before, 1 = after.
    public func setProgress(_ p: CGFloat) {
        progress = min(max(p, 0), 1)
        renderFrame()
    }

    /// Animate `progress` to a target over `duration`, then call `completion`.
    public func animateProgress(to target: CGFloat, duration: TimeInterval,
                                completion: @escaping () -> Void) {
        link?.invalidate()
        animFrom = progress
        animTo = min(max(target, 0), 1)
        animDuration = max(duration, 0.001)
        animStart = CACurrentMediaTime()
        animCompletion = completion
        let dl = CADisplayLink(target: self, selector: #selector(tick))
        dl.add(to: .main, forMode: .common)
        link = dl
    }

    @objc private func tick() {
        let t = min((CACurrentMediaTime() - animStart) / animDuration, 1)
        // Ease-in-out for a smoother settle.
        let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        setProgress(animFrom + (animTo - animFrom) * CGFloat(eased))
        if t >= 1 {
            link?.invalidate(); link = nil
            let done = animCompletion; animCompletion = nil
            done?()
        }
    }

    // MARK: - Rendering

    public override func layoutSubviews() {
        super.layoutSubviews()
        metalLayer.contentsScale = drawableScale
        let size = CGSize(width: max(bounds.width * drawableScale, 1),
                          height: max(bounds.height * drawableScale, 1))
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
        renderFrame()
    }

    /// Rasterise the snapshot into a top-left-origin RGBA8 texture by hand —
    /// MTKTextureLoader rejects some UIGraphicsImageRenderer color spaces, and this
    /// path is format-agnostic and orientation-correct for our top-left UVs.
    private func makeTexture(_ image: UIImage) -> MTLTexture? {
        guard let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        let bytesPerRow = w * 4
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Flip so memory row 0 is the TOP of the image (matches the shader's UVs).
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                    withBytes: data, bytesPerRow: bytesPerRow)
        return tex
    }

    /// `progress` → (revealRadius, abMix) across the three phases.
    private func phaseValues() -> (radius: CGFloat, abMix: CGFloat) {
        let p = progress
        let maxR = maxRevealRadius()
        if p < 0.33 {
            return (maxR * (p / 0.33), 0)
        } else if p < 0.66 {
            return (maxR, (p - 0.33) / 0.33)
        } else {
            return (maxR * (1 - (p - 0.66) / 0.34), 1)
        }
    }

    private func maxRevealRadius() -> CGFloat {
        let c = CGPoint(x: origin.x * drawableScale, y: origin.y * drawableScale)
        let w = metalLayer.drawableSize.width, h = metalLayer.drawableSize.height
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0),
                       CGPoint(x: 0, y: h), CGPoint(x: w, y: h)]
        return corners.map { hypot($0.x - c.x, $0.y - c.y) }.max() ?? max(w, h)
    }

    private func renderFrame() {
        guard let texA, let texB, metalLayer.drawableSize.width > 1,
              let drawable = metalLayer.nextDrawable() else { return }

        let (radius, abMix) = phaseValues()
        var u = uniforms
        u.resolution = SIMD2(Float(metalLayer.drawableSize.width), Float(metalLayer.drawableSize.height))
        u.revealCenter = SIMD2(Float(origin.x * drawableScale), Float(origin.y * drawableScale))
        u.gapColor = colorVector(style.gapColor)
        u.cellSize = Float(max(style.cellSize * drawableScale, 1))
        u.dotScale = Float(style.dotScale)
        u.cornerRadius = Float(style.cornerRadius)
        u.edgeSoftness = Float(max(style.edgeSoftness, 0.5))
        u.revealRadius = Float(radius)
        u.revealEdge = Float(max(style.cellSize * drawableScale * 0.6, 1))
        u.abMix = Float(abMix)
        u.monochrome = style.monochrome ? 1 : 0
        uniforms = u

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(texA, index: 0)
        enc.setFragmentTexture(texB, index: 1)
        withUnsafeBytes(of: u) { raw in
            enc.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 0)
        }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    private func colorVector(_ color: UIColor) -> SIMD4<Float> {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        color.resolvedColor(with: traitCollection).getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD4(Float(r), Float(g), Float(b), Float(a))
    }
}
