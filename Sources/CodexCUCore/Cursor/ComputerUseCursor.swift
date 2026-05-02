import AppKit

/// A floating overlay window that renders the AI cursor — a visual indicator
/// showing where the AI agent is clicking/interacting.
///
/// Replicates Codex's `ComputerUseCursor` overlay:
/// - Borderless, always-on-top, click-through window
/// - Blue circle with white border (AI cursor indicator)
/// - Animated movement between positions
/// - Click pulse animation for visual feedback
/// - Level above popUpMenu so it's visible over the frozen screenshot overlay
@MainActor
public final class ComputerUseCursor {
    public static let shared = ComputerUseCursor()

    private var window: NSWindow?
    private let cursorSize: CGFloat = 24

    private init() {}

    /// Create and show the cursor window
    public func show() {
        guard window == nil else { return }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: cursorSize, height: cursorSize),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        // Level above popUpMenu (101) so cursor is visible over frozen overlay
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 1)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.hasShadow = false

        let view = NSView(frame: NSRect(x: 0, y: 0, width: cursorSize, height: cursorSize))
        view.wantsLayer = true
        view.layer?.cornerRadius = cursorSize / 2
        view.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.8).cgColor
        view.layer?.borderColor = NSColor.white.cgColor
        view.layer?.borderWidth = 2

        w.contentView = view
        self.window = w
    }

    /// Move cursor to a screen position (CG coordinates: top-left origin) with animation
    public func moveTo(_ point: CGPoint, animated: Bool = true) {
        guard let window = window else { return }

        let screenHeight = NSScreen.main?.frame.height ?? 0
        let nsPoint = NSPoint(
            x: point.x - cursorSize / 2,
            y: screenHeight - point.y - cursorSize / 2
        )

        if !window.isVisible {
            // First show — place without animation then show
            window.setFrameOrigin(nsPoint)
            window.orderFrontRegardless()
        } else if animated {
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
        pulse.toValue = 1.8
        pulse.duration = 0.15
        pulse.autoreverses = true
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        view.layer?.add(pulse, forKey: "clickPulse")
    }

    /// Hide the cursor window
    public func hide() {
        window?.orderOut(nil)
        window = nil
    }

    public var isVisible: Bool {
        window?.isVisible ?? false
    }
}
