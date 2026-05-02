import AppKit

/// A floating overlay window that renders the AI cursor
@MainActor
public final class ComputerUseCursor {
    private var window: NSWindow?
    private var cursorView: NSImageView?
    private let cursorSize: CGFloat = 24

    public init() {}

    /// Create and show the cursor window
    public func show() {
        guard window == nil else { return }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: cursorSize, height: cursorSize),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        w.level = .popUpMenu
        w.isOpaque = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.hasShadow = false

        // Create cursor indicator (a colored circle)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: cursorSize, height: cursorSize))
        view.wantsLayer = true
        view.layer?.cornerRadius = cursorSize / 2
        view.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.8).cgColor
        view.layer?.borderColor = NSColor.white.cgColor
        view.layer?.borderWidth = 2

        w.contentView = view
        w.orderFrontRegardless()
        self.window = w
    }

    /// Move cursor to a screen position with optional animation
    public func moveTo(_ point: CGPoint, animated: Bool = true) {
        guard let window = window else { return }

        // Convert from top-left (CG) to bottom-left (NS) coordinates
        let screenHeight = NSScreen.main?.frame.height ?? 0
        let nsPoint = NSPoint(x: point.x - cursorSize / 2, y: screenHeight - point.y - cursorSize / 2)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrameOrigin(nsPoint)
            }
        } else {
            window.setFrameOrigin(nsPoint)
        }
    }

    /// Pulse animation to indicate a click
    public func pulseClick() {
        guard let view = window?.contentView else { return }

        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 1.0
        pulse.toValue = 1.5
        pulse.duration = 0.15
        pulse.autoreverses = true
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        view.layer?.add(pulse, forKey: "clickPulse")
    }

    /// Hide and release the cursor window
    public func hide() {
        window?.orderOut(nil)
        window = nil
    }

    public var isVisible: Bool {
        window?.isVisible ?? false
    }
}
