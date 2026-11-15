// Đổi toạ độ giữa pixel của frame camera và điểm trên màn hình (preview vẽ kiểu aspect-fit).
import AVFoundation
import CoreGraphics
import SafeGapCore

struct FrameMapping {
    let frameWidth: Double
    let frameHeight: Double
    let viewSize: CGSize

    var rect: CGRect {
        AVMakeRect(aspectRatio: CGSize(width: frameWidth, height: frameHeight), insideRect: CGRect(origin: .zero, size: viewSize))
    }

    var scale: Double { Double(rect.width) / frameWidth }

    func toView(_ x: Double, _ y: Double) -> CGPoint {
        let r = rect
        return CGPoint(x: r.minX + CGFloat(x * scale), y: r.minY + CGFloat(y * scale))
    }

    func toView(norm p: Point) -> CGPoint { toView(p.x * frameWidth, p.y * frameHeight) }

    func toView(_ b: Box) -> CGRect {
        let a = toView(b.x1, b.y1), c = toView(b.x2, b.y2)
        return CGRect(x: a.x, y: a.y, width: c.x - a.x, height: c.y - a.y)
    }

    func toFrame(_ p: CGPoint) -> (x: Double, y: Double) {
        let r = rect
        return (Double(p.x - r.minX) / scale, Double(p.y - r.minY) / scale)
    }

    func toNorm(_ p: CGPoint) -> Point {
        let f = toFrame(p)
        return Point(min(max(f.x / frameWidth, 0), 1), min(max(f.y / frameHeight, 0), 1))
    }
}
