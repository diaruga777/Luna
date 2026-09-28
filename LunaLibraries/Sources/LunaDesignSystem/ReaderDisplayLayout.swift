import UIKit

/// Keeps floating reader controls reachable without displacing scrolling text.
public enum ReaderDisplayLayout {
    /// The SDK guard keeps stable-Xcode release builds working. The module
    /// version is from the UIKit interface shipped with Xcode 27.1 beta.
    @MainActor
    public static func reservedControlRegions(in view: UIView) -> [CGRect] {
        #if canImport(UIKit, _version: 9127.0.85) && !targetEnvironment(macCatalyst)
        if #available(iOS 27.1, *) {
            return (view.reservedRegions(kind: .division)
                + view.reservedRegions(kind: .occlusion)).map(\.frame)
        }
        #endif
        return []
    }

    /// Pick the closest legal seat, preserving a control's size when possible.
    /// Reserved frames already include the system's interactive margins.
    public static func controlFrame(_ preferred: CGRect, in safeBounds: CGRect,
                                    avoiding regions: [CGRect]) -> CGRect {
        guard safeBounds.width > 0, safeBounds.height > 0 else { return preferred }
        let size = CGSize(width: min(preferred.width, safeBounds.width),
                          height: min(preferred.height, safeBounds.height))
        func clamped(_ origin: CGPoint) -> CGRect {
            CGRect(x: min(max(origin.x, safeBounds.minX), safeBounds.maxX - size.width),
                   y: min(max(origin.y, safeBounds.minY), safeBounds.maxY - size.height),
                   width: size.width, height: size.height)
        }
        let base = clamped(preferred.origin)
        let obstacles = regions.filter { !$0.isEmpty && $0.intersects(safeBounds) }
        var xs = [base.minX, safeBounds.minX, safeBounds.maxX - size.width]
        var ys = [base.minY, safeBounds.minY, safeBounds.maxY - size.height]
        for region in obstacles {
            xs += [region.minX - size.width, region.maxX]
            ys += [region.minY - size.height, region.maxY]
        }
        let candidates = xs.flatMap { x in ys.map { clamped(CGPoint(x: x, y: $0)) } }
            .filter { candidate in !obstacles.contains { $0.intersects(candidate.insetBy(dx: 0.01, dy: 0.01)) } }
        return candidates.min {
            let a = hypot($0.midX - base.midX, $0.midY - base.midY)
            let b = hypot($1.midX - base.midX, $1.midY - base.midY)
            return a == b ? $0.midX > $1.midX : a < b
        } ?? base
    }
}
