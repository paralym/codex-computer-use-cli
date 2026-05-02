import ApplicationServices
import AppKit
import CoreGraphics

// MARK: - Private API

@_silgen_name("GetProcessForPID")
private func _getProcessForPID(_ pid: pid_t, _ psn: UnsafeMutableRawPointer) -> Int32

@_silgen_name("GetFrontProcess")
private func _getFrontProcess(_ psn: UnsafeMutableRawPointer) -> Int16

@_silgen_name("CGWindowListCreateImage")
private func _cgWindowListCreateImage(_ rect: CGRect, _ opts: UInt32, _ wid: UInt32, _ imgOpts: UInt32) -> CGImage?

private struct PSN {
    var highLongOfPSN: UInt32 = 0
    var lowLongOfPSN: UInt32 = 0
}

private let _slpsSetFrontProcessWithOptions: (@convention(c) (UnsafeMutableRawPointer, UInt32) -> Int32)? = {
    guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
          let sym = dlsym(handle, "_SLPSSetFrontProcessWithOptions") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (UnsafeMutableRawPointer, UInt32) -> Int32).self)
}()

// MARK: - SyntheticAppFocusEnforcer

/// Makes a target app process HID events (including Electron double-click)
/// with zero visual disruption. Replicates Codex's SyntheticAppFocusEnforcer.
///
/// ## How it works (frozen-screen overlay)
///
/// 1. **Freeze**: Screenshot the entire display, show it as an opaque overlay
///    at `kCGPopUpMenuWindowLevel` (101). The user sees a frozen screen.
/// 2. **Hide cursor**: `CGDisplayHideCursor` so cursor warp is invisible.
/// 3. **CPS activate**: `_SLPSSetFrontProcessWithOptions` makes the target
///    the CPS-level front process. Window ordering changes happen BEHIND
///    the frozen screenshot — completely invisible.
/// 4. **Click**: Warp cursor to target position, deliver HID events.
///    Cursor is hidden so movement is invisible.
/// 5. **Restore**: Restore cursor position, show cursor, restore CPS front,
///    remove overlay. Total cycle: ~200ms.
public final class SyntheticAppFocusEnforcer: @unchecked Sendable {

    private var _overlayWindow: NSWindow?

    public init() {}

    // MARK: - Core

    @discardableResult
    public func withSyntheticFocus(targetPID: pid_t, action: () throws -> Void) rethrows -> Bool {
        guard let slpsSetFront = _slpsSetFrontProcessWithOptions else {
            try action()
            return false
        }

        var targetPSN = PSN()
        var frontPSN = PSN()
        guard _getProcessForPID(targetPID, &targetPSN) == 0 else { try action(); return false }
        guard _getFrontProcess(&frontPSN) == 0 else { try action(); return false }

        if targetPSN.highLongOfPSN == frontPSN.highLongOfPSN
            && targetPSN.lowLongOfPSN == frontPSN.lowLongOfPSN {
            try action()
            return true
        }

        // Phase 1: Frozen screenshot overlay
        showFrozenOverlay()

        // Phase 2: Hide cursor + disconnect cursor from mouse position
        let savedPos = CGEvent(source: nil)?.location ?? .zero
        CGDisplayHideCursor(CGMainDisplayID())
        CGAssociateMouseAndMouseCursorPosition(0) // HID events won't move visible cursor

        // Phase 3: CPS activate (changes invisible behind frozen overlay)
        _ = slpsSetFront(&targetPSN, 0)
        usleep(50000) // 50ms for CPS notification

        defer {
            // Phase 5: Restore
            usleep(50000)

            // Restore CPS front FIRST (before showing cursor)
            _ = slpsSetFront(&frontPSN, 0)
            usleep(50000)

            // Reconnect cursor, warp back to saved position, show
            CGAssociateMouseAndMouseCursorPosition(1)
            CGWarpMouseCursorPosition(savedPos)
            CGDisplayShowCursor(CGMainDisplayID())

            // Remove overlay
            hideFrozenOverlay()
        }

        // Phase 4: Execute action (cursor hidden + disconnected, overlay covers screen)
        try action()
        return true
    }

    // MARK: - Frozen Overlay

    private func showFrozenOverlay() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { _showFrozenOverlay() }
        } else {
            DispatchQueue.main.sync { [self] in
                MainActor.assumeIsolated { _showFrozenOverlay() }
            }
        }
    }

    private func hideFrozenOverlay() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { _hideFrozenOverlay() }
        } else {
            DispatchQueue.main.sync { [self] in
                MainActor.assumeIsolated { _hideFrozenOverlay() }
            }
        }
    }

    @MainActor
    private func _showFrozenOverlay() {
        // Capture current screen
        // CGWindowListCreateImage: opts=1 (onScreenOnly), imgOpts=1 (bestResolution)
        guard let screenshot = _cgWindowListCreateImage(.null, 1, 0, 1),
              let screen = NSScreen.main else { return }

        let w: NSWindow
        if let existing = _overlayWindow {
            w = existing
        } else {
            w = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)))
            w.isOpaque = true
            w.ignoresMouseEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            w.hasShadow = false
            _overlayWindow = w
        }

        let imageView = NSImageView(frame: screen.frame)
        imageView.image = NSImage(cgImage: screenshot, size: screen.frame.size)
        imageView.imageScaling = .scaleAxesIndependently
        w.contentView = imageView

        w.orderFrontRegardless()

        // Ensure compositor renders the frozen frame before we proceed
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    }

    @MainActor
    private func _hideFrozenOverlay() {
        _overlayWindow?.orderOut(nil)
    }

    // MARK: - Convenience

    public func click(
        at point: CGPoint,
        targetPID: pid_t,
        windowNumber: CGWindowID?,
        button: MouseButton = .left,
        clickCount: Int = 1,
        mouseController: MouseController
    ) throws {
        try withSyntheticFocus(targetPID: targetPID) {
            // Warp cursor (hidden) and click
            CGWarpMouseCursorPosition(point)
            CGAssociateMouseAndMouseCursorPosition(1)
            try mouseController.click(at: point, button: button, clickCount: clickCount)
        }
    }
}
