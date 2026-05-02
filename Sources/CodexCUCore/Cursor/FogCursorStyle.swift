import AppKit

/// Full-screen fog overlay with a circular cutout around the AI cursor position
@MainActor
public final class FogCursorOverlay {
    private var window: NSWindow?
    private var maskLayer: CAShapeLayer?
    private let cutoutRadius: CGFloat = 60

    public init() {}

    public func show() {
        guard window == nil, let screen = NSScreen.main else { return }

        let w = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        w.level = .floating
        w.isOpaque = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.hasShadow = false

        let view = NSView(frame: screen.frame)
        view.wantsLayer = true

        // Semi-transparent overlay
        let overlayLayer = CALayer()
        overlayLayer.frame = view.bounds
        overlayLayer.backgroundColor = NSColor.black.withAlphaComponent(0.15).cgColor

        // Mask to create cutout
        let mask = CAShapeLayer()
        mask.frame = view.bounds
        mask.fillRule = .evenOdd
        self.maskLayer = mask
        overlayLayer.mask = mask

        view.layer?.addSublayer(overlayLayer)
        w.contentView = view
        w.orderFrontRegardless()
        self.window = w
    }

    /// Update the cutout position (in CG/screen coordinates)
    public func updateCutout(at point: CGPoint) {
        guard let maskLayer = maskLayer, let screen = NSScreen.main else { return }

        let screenHeight = screen.frame.height
        let nsPoint = NSPoint(x: point.x, y: screenHeight - point.y)

        let fullPath = NSBezierPath(rect: screen.frame)
        let cutoutRect = NSRect(
            x: nsPoint.x - cutoutRadius,
            y: nsPoint.y - cutoutRadius,
            width: cutoutRadius * 2,
            height: cutoutRadius * 2
        )
        let cutout = NSBezierPath(ovalIn: cutoutRect)
        fullPath.append(cutout)

        maskLayer.path = fullPath.cgPath
    }

    public func hide() {
        window?.orderOut(nil)
        window = nil
        maskLayer = nil
    }
}

// NSBezierPath → CGPath conversion
extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [NSPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            let type = element(at: i, associatedPoints: &points)
            switch type {
            case .moveTo: path.move(to: points[0])
            case .lineTo: path.addLine(to: points[0])
            case .curveTo: path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closePath: path.closeSubpath()
            case .cubicCurveTo: path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo: path.addQuadCurve(to: points[1], control: points[0])
            @unknown default: break
            }
        }
        return path
    }
}
