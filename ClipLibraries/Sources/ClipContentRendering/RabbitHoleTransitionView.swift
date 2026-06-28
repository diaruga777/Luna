//
//  RabbitHoleTransitionView.swift
//  ClipContentRendering
//
//  A self-contained, GPU two-phase transition between two screen snapshots, used by
//  the RabbitHole reader for dive / pop / overscroll. Driven by a single `progress`
//  (0 = the existing view, 1 = the final view): phase 1 dissolves the existing view
//  into a pixelated version of the final view one mosaic cell at a time, phase 2
//  sharpens that back to the final view — see RabbitHoleTransition.metal. All per-frame
//  work is the GPU draw; only the one-time snapshots happen on the main thread. The
//  expensive Metal device/queue/pipeline are built once and shared, so a transition
//  view can be made (and the overlay prewarmed) without recompiling the shader. The
//  shipping HalftoneEffectView is untouched.
//

import Metal
import UIKit
import simd

/// Visual parameters for the transition's mosaic.
public struct RabbitHoleTransitionStyle {
    public var pixelSize: CGFloat   // points — size of one mosaic block
    /// Phase-1 per-cell start spread: 0 = all cells flip together, 1 = fully sequential.
    public var stagger: CGFloat
    public var monochrome: Bool

    public init(pixelSize: CGFloat = 24, stagger: CGFloat = 0.6, monochrome: Bool = false) {
        self.pixelSize = pixelSize
        self.stagger = stagger
        self.monochrome = monochrome
    }
}

public final class RabbitHoleTransitionView: UIView {

    // Must match RHTransitionUniforms in RabbitHoleTransition.metal exactly
    // (float2 + 6 floats = 32 bytes).
    private struct Uniforms {
        var resolution = SIMD2<Float>(0, 0)
        var cellSize: Float = 24
        var progress: Float = 0
        var phaseSplit: Float = 0.5
        var stagger: Float = 0.6
        var flipV: Float = 0
        var monochrome: Float = 0
    }

    /// The shared, lazily-built Metal context. Compiling the pipeline is the costly
    /// part of `make()`; doing it once means prewarming/reusing overlay views is cheap.
    private struct GPU { let device: MTLDevice; let queue: MTLCommandQueue; let pipeline: MTLRenderPipelineState }
    private static let gpu: GPU? = makeGPU()

    public var style = RabbitHoleTransitionStyle() { didSet { renderFrame() } }
    /// Progress value where phase 1 (dissolve to pixels) ends and phase 2 (sharpen)
    /// begins. Set from the relative phase durations before animating.
    public var phaseSplit: CGFloat = 0.5 { didSet { renderFrame() } }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var texA: MTLTexture?
    private var texB: MTLTexture?

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
    /// to an instant cut). Cheap after the first call — the GPU context is shared.
    public static func make() -> RabbitHoleTransitionView? {
        guard let gpu else { return nil }
        return RabbitHoleTransitionView(device: gpu.device, queue: gpu.queue, pipeline: gpu.pipeline)
    }

    private static func makeGPU() -> GPU? {
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
        return GPU(device: device, queue: queue, pipeline: pipeline)
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

    /// Load the before/after snapshots.
    public func configure(before: UIImage, after: UIImage) {
        texA = makeTexture(before)
        texB = makeTexture(after)
        setProgress(progress)
    }

    /// Load only the `before` snapshot, using it for BOTH textures so the overlay can
    /// mask the screen at progress 0 (showing exactly the before frame) before the
    /// `after` image exists. Pair with `setAfterImage` once it's ready.
    public func configure(before: UIImage) {
        let tex = makeTexture(before)
        texA = tex
        texB = tex
        setProgress(progress)
    }

    /// Swap in the `after` snapshot mid-flight (after `configure(before:)`). Cheap
    /// enough to call a frame or two into the dissolve — at low progress the after
    /// image is barely mixed in, so the swap is imperceptible.
    public func setAfterImage(_ after: UIImage) {
        texB = makeTexture(after)
        renderFrame()
    }

    /// Release the snapshot textures (call when the overlay is parked offscreen between
    /// transitions, so two full-screen textures aren't held idle).
    public func clearTextures() {
        texA = nil
        texB = nil
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
        setProgress(animFrom + (animTo - animFrom) * CGFloat(t))   // linear; cells self-stagger
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

    /// Rasterise the snapshot into an RGBA8 texture. MTKTextureLoader rejects some
    /// UIGraphicsImageRenderer color spaces, so do it by hand; the shader's `flipV`
    /// handles the row-order origin.
    private func makeTexture(_ image: UIImage) -> MTLTexture? {
        guard let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        let bytesPerRow = w * 4
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
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

    private func renderFrame() {
        guard let texA, let texB, metalLayer.drawableSize.width > 1,
              let drawable = metalLayer.nextDrawable() else { return }

        var u = Uniforms()
        u.resolution = SIMD2(Float(metalLayer.drawableSize.width), Float(metalLayer.drawableSize.height))
        u.cellSize = Float(max(style.pixelSize * drawableScale, 1))
        u.progress = Float(progress)
        u.phaseSplit = Float(min(max(phaseSplit, 0.01), 0.99))
        u.stagger = Float(min(max(style.stagger, 0), 1))
        u.flipV = 0   // CGContext-drawn texture is already top-left origin
        u.monochrome = style.monochrome ? 1 : 0

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
}
