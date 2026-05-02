import AppKit
import CoreGraphics

/// Full-screen fog overlay with a circular cutout showing the target app's content
/// around the AI cursor position. Replicates Codex's FogCursorStyle.
///
/// The overlay shows:
/// - Target app's screenshot as background (dimmed with semi-transparent black)
/// - A circular clear cutout around the click position (spotlight effect)
/// - Virtual cursor (blue dot) at the center of the cutout
///
/// This gives the user visual context: they can see WHAT the AI is clicking on
/// through the cutout, even though the target app is in the background.
@MainActor
public final class FogCursorOverlay {
    public static let shared = FogCursorOverlay()

    private var window: NSWindow?
    private var fogView: FogView?
    private let cutoutRadius: CGFloat = 80

    private init() {}

    /// Show the fog overlay with a target app screenshot and cutout at the click position.
    ///
    /// - Parameters:
    ///   - targetScreenshot: Screenshot of the target app (or full screen)
    ///   - clickPoint: CG coordinates (top-left origin) of the click position
    public func show(targetScreenshot: CGImage, clickPoint: CGPoint) {
        guard let screen = NSScreen.main else { return }

        let w: NSWindow
        if let existing = window {
            w = existing
        } else {
            w = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            // Above popUpMenu (101) — above the frozen screenshot overlay
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 2)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.ignoresMouseEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            w.hasShadow = false
            window = w
        }

        let view = FogView(
            frame: screen.frame,
            screenshot: targetScreenshot,
            clickPoint: clickPoint,
            cutoutRadius: cutoutRadius
        )
        fogView = view
        w.contentView = view

        w.orderFrontRegardless()
    }

    /// Update the cutout position (for animated cursor movement)
    public func updateCutout(at point: CGPoint) {
        fogView?.updateClickPoint(point)
    }

    /// Hide and remove the fog overlay
    public func hide() {
        window?.orderOut(nil)
        fogView = nil
    }

    public var isVisible: Bool {
        window?.isVisible ?? false
    }
}

// MARK: - FogView

/// Custom NSView that renders the fog overlay:
/// - Target app screenshot as background
/// - Semi-transparent dark overlay (fog)
/// - Circular cutout (clear area) showing the screenshot through
/// - Blue cursor dot at the center
private class FogView: NSView {
    private let screenshot: CGImage
    private var clickPoint: CGPoint // CG coordinates (top-left origin)
    private let cutoutRadius: CGFloat
    private let cursorSize: CGFloat = 24

    init(frame: NSRect, screenshot: CGImage, clickPoint: CGPoint, cutoutRadius: CGFloat) {
        self.screenshot = screenshot
        self.clickPoint = clickPoint
        self.cutoutRadius = cutoutRadius
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func updateClickPoint(_ point: CGPoint) {
        clickPoint = point
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let screenHeight = bounds.height

        // Convert CG coordinates (top-left) to NS coordinates (bottom-left)
        let nsClickY = screenHeight - clickPoint.y

        // 1. Draw target app screenshot (fills entire view)
        ctx.saveGState()
        // Flip context for CGImage drawing (CGImage is top-left origin)
        ctx.translateBy(x: 0, y: screenHeight)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(screenshot, in: CGRect(
            x: 0, y: 0,
            width: bounds.width,
            height: bounds.height
        ))
        ctx.restoreGState()

        // 2. Draw semi-transparent fog with cutout
        ctx.saveGState()

        // Full-screen fog path
        let fullPath = CGMutablePath()
        fullPath.addRect(bounds)

        // Circular cutout (even-odd rule will make this clear)
        let cutoutRect = CGRect(
            x: clickPoint.x - cutoutRadius,
            y: nsClickY - cutoutRadius,
            width: cutoutRadius * 2,
            height: cutoutRadius * 2
        )
        fullPath.addEllipse(in: cutoutRect)

        ctx.addPath(fullPath)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.fillPath(using: .evenOdd) // Fog everywhere EXCEPT the cutout

        ctx.restoreGState()

        // 3. Draw cutout border (subtle ring)
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.3).cgColor)
        ctx.setLineWidth(2)
        ctx.addEllipse(in: cutoutRect)
        ctx.strokePath()
        ctx.restoreGState()

        // 4. Draw virtual cursor (blue dot at center)
        let cursorRect = CGRect(
            x: clickPoint.x - cursorSize / 2,
            y: nsClickY - cursorSize / 2,
            width: cursorSize,
            height: cursorSize
        )
        ctx.saveGState()
        ctx.setFillColor(NSColor.systemBlue.withAlphaComponent(0.85).cgColor)
        ctx.fillEllipse(in: cursorRect)
        // White border on cursor
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(2.5)
        ctx.strokeEllipse(in: cursorRect)
        ctx.restoreGState()
    }
}
