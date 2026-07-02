//
//  RabbitHoleTransitionView.swift
//  LunaContentRendering
//
//  A self-contained, GPU two-phase transition between two screen snapshots, used by
//  the RabbitHole reader for dive / pop / overscroll. Driven by a single `progress`
//  (0 = the existing view, 1 = the final view): phase 1 dissolves the existing view
//  into a pixelated version of the final view one mosaic cell at a time, phase 2
//  sharpens that back to the final view — see RabbitHoleTransition.metal. All per-frame
//  work is the GPU draw; only the one-time snapshots happen on the main thread. The
//  expensive Metal device/queue/pipeline are built once and shared, so a transition
//  view can be made (and the overlay prewarmed) without recompiling the shader.
//

import Metal
import UIKit
import simd

/// Which way the two wavefronts sweep across the screen. Random reveals cells in a
/// hashed order (a fade); the directional cases mirror the base UIKit motion (e.g. a
/// nav push sweeps right-to-left). Both waves travel the same way for directional modes.
public enum DotMatrixWavefrontDirection: Int {
    case random = 0
    case leftToRight = 1
    case rightToLeft = 2
    case topToBottom = 3
    case bottomToTop = 4
}

/// Visual parameters for the transition's mosaic. Defaults match the global "pixel
/// wipe" look: 6 pt rounded dots with a 2 pt gap.
public struct RabbitHoleTransitionStyle {
    public var pixelSize: CGFloat      // points — pitch of one mosaic cell
    public var cornerRadius: CGFloat   // points — dot corner radius
    public var spacing: CGFloat        // points — gap between dots
    /// Pixelated-state gap fill (opaque). White in light mode, black in dark mode;
    /// resolved from the trait collection by the caller.
    public var gapColor: SIMD4<Float>
    /// Spread of the wavefront across the screen (first-cell → last-cell arrival), as a
    /// fraction of the timeline. MUST be substantial (~0.5+) or every cell flips together
    /// and the transition degenerates into a flat full-screen fade.
    public var sweep: CGFloat
    /// How far wave 2 (sharpen) trails wave 1 (pixelate). Keep `lag` < `sweep` so the
    /// second front starts while the first is still mid-sweep.
    public var lag: CGFloat
    /// Per-cell crossfade width — how long one cell takes to fade. Smaller = a crisper
    /// front.
    public var win: CGFloat
    public var monochrome: Bool

    public init(pixelSize: CGFloat = 6,
                cornerRadius: CGFloat = 2,
                spacing: CGFloat = 2,
                gapColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1),
                sweep: CGFloat = 0.6,
                lag: CGFloat = 0.25,
                win: CGFloat = 0.18,
                monochrome: Bool = false) {
        self.pixelSize = pixelSize
        self.cornerRadius = cornerRadius
        self.spacing = spacing
        self.gapColor = gapColor
        self.sweep = sweep
        self.lag = lag
        self.win = win
        self.monochrome = monochrome
    }
}

public final class RabbitHoleTransitionView: UIView {

    // Must match RHTransitionUniforms in RabbitHoleTransition.metal exactly — keep
    // field order identical. `gapColor` (SIMD4) is first so its 16-byte alignment
    // can't introduce hidden padding before a leading SIMD2.
    private struct Uniforms {
        var gapColor = SIMD4<Float>(1, 1, 1, 1)
        var resolution = SIMD2<Float>(0, 0)
        var cellSize: Float = 12
        var cornerRadius: Float = 4
        var spacing: Float = 4
        var progress: Float = 0
        var sweep: Float = 0.6
        var lag: Float = 0.25
        var win: Float = 0.18
        var direction: Float = 0
        var flipV: Float = 0
        var monochrome: Float = 0
        var dissolveOut: Float = 0
        // MSL rounds RHTransitionUniforms up to its 16-byte alignment (80 bytes);
        // these pads make the Swift size match so `setFragmentBytes` covers the
        // full length Metal's argument validation requires.
        var pad0: Float = 0
        var pad1: Float = 0
        var pad2: Float = 0
    }

    /// The shared, lazily-built Metal context. Compiling the pipeline is the costly
    /// part of `make()`; doing it once means prewarming/reusing overlay views is cheap.
    private struct GPU { let device: MTLDevice; let queue: MTLCommandQueue; let pipeline: MTLRenderPipelineState }
    private static let gpu: GPU? = makeGPU()

    public var style = RabbitHoleTransitionStyle() { didSet { renderFrame() } }
    /// Which way the wavefronts sweep. Set per call (push, pop, fade…) before animating.
    public var direction: DotMatrixWavefrontDirection = .random { didSet { renderFrame() } }
    /// Dissolve-out mode: the BEFORE texture pixelates into dots over TRANSPARENT gaps
    /// and fades away, revealing whatever LIVE content sits beneath the view — for
    /// content that can't be snapshotted (the keyboard). The after texture is unused
    /// (pass the before image to `configure` for both). Reset when the overlay is
    /// returned to the transition centre.
    public var dissolvesOut: Bool = false {
        didSet {
            metalLayer.isOpaque = !dissolvesOut
            renderFrame()
        }
    }

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

    /// Whether the GPU context (device + shader pipeline) is available. Cheap — the
    /// context is built once and shared; this just checks it succeeded.
    public static var isSupported: Bool { gpu != nil }

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
        // Premultiplied-alpha blending for the dissolve-out mode; a no-op for the
        // opaque wipes (their fragments always come back with alpha 1).
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .one
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
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
        u.gapColor = style.gapColor
        u.resolution = SIMD2(Float(metalLayer.drawableSize.width), Float(metalLayer.drawableSize.height))
        u.cellSize = Float(max(style.pixelSize * drawableScale, 1))
        u.cornerRadius = Float(max(style.cornerRadius * drawableScale, 0))
        u.spacing = Float(max(style.spacing * drawableScale, 0))
        u.progress = Float(progress)
        u.sweep = Float(min(max(style.sweep, 0), 1))
        u.lag = Float(min(max(style.lag, 0), 1))
        u.win = Float(min(max(style.win, 0.001), 1))
        u.direction = Float(direction.rawValue)
        u.flipV = 0   // CGContext-drawn texture is already top-left origin
        u.monochrome = style.monochrome ? 1 : 0
        u.dissolveOut = dissolvesOut ? 1 : 0

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: 0, green: 0, blue: 0, alpha: dissolvesOut ? 0 : 1)

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
