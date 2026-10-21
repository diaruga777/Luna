import AppKit
let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 4096, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
NSColor(calibratedRed: 0.035, green: 0.06, blue: 0.14, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
func polygon(_ points: [(Double, Double)], _ color: NSColor) {
    let path = NSBezierPath(); path.move(to: NSPoint(x: points[0].0, y: points[0].1)); for point in points.dropFirst() { path.line(to: NSPoint(x: point.0, y: point.1)) }; path.close(); color.setFill(); path.fill()
}
polygon([(512,920),(825,690),(780,290),(512,105),(218,300),(185,680)], NSColor(calibratedRed:0.25,green:0.31,blue:0.86,alpha:1))
polygon([(512,920),(825,690),(512,535)], NSColor(calibratedRed:0.62,green:0.61,blue:1,alpha:1))
polygon([(512,920),(185,680),(512,535)], NSColor(calibratedRed:0.36,green:0.65,blue:1,alpha:1))
polygon([(185,680),(218,300),(512,535)], NSColor(calibratedRed:0.15,green:0.39,blue:0.90,alpha:1))
polygon([(218,300),(512,105),(512,535)], NSColor(calibratedRed:0.12,green:0.22,blue:0.66,alpha:1))
polygon([(825,690),(780,290),(512,535)], NSColor(calibratedRed:0.43,green:0.30,blue:0.77,alpha:1))
let path=NSBezierPath(); path.lineWidth=42; path.lineCapStyle = .round; path.lineJoinStyle = .round
path.move(to:NSPoint(x:398,y:641));path.line(to:NSPoint(x:295,y:527));path.line(to:NSPoint(x:398,y:412))
path.move(to:NSPoint(x:626,y:641));path.line(to:NSPoint(x:729,y:527));path.line(to:NSPoint(x:626,y:412))
path.move(to:NSPoint(x:552,y:667));path.line(to:NSPoint(x:472,y:387));NSColor.white.setStroke();path.stroke()
NSGraphicsContext.restoreGraphicsState()
let data=NSBitmapImageRep(cgImage: context.makeImage()!).representation(using:.png,properties:[:])!
try data.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
