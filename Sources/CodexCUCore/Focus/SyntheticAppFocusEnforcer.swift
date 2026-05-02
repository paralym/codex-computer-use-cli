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
/// with zero visual disruption.
///
/// 1. Screenshot entire display → show as opaque overlay at level 101
/// 2. Hide real cursor + disconnect from mouse position
/// 3. CPS activate via `_SLPSSetFrontProcessWithOptions`
/// 4. Click (cursor hidden, overlay covers screen)
/// 5. Restore CPS, cursor, remove overlay
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

        // Phase 2: Hide cursor + disconnect
        let savedPos = CGEvent(source: nil)?.location ?? .zero
        CGDisplayHideCursor(CGMainDisplayID())
        CGAssociateMouseAndMouseCursorPosition(0)

        // Phase 3: CPS activate
        _ = slpsSetFront(&targetPSN, 0)
        usleep(50000)

        defer {
            usleep(50000)
            _ = slpsSetFront(&frontPSN, 0)
            usleep(50000)

            // Warp BEFORE reconnect to avoid 1-frame cursor jump.
            // If we reconnect first, cursor briefly appears at the HID-moved position.
            CGWarpMouseCursorPosition(savedPos)
            CGAssociateMouseAndMouseCursorPosition(1)
            CGDisplayShowCursor(CGMainDisplayID())

            hideFrozenOverlay()
        }

        try action()
        return true
    }

    // MARK: - Visual Protection (overlay only, no CPS)

    /// Show the frozen overlay to prevent visual disruption from AX actions
    /// that may trigger app activation as a side effect.
    public func showOverlay() {
        showFrozenOverlay()
    }

    /// Hide the frozen overlay after the AX action is complete.
    public func hideOverlay() {
        hideFrozenOverlay()
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
            // Use HID (.cghidEventTap) — goes through the normal event routing system
            // which Electron fully supports. The cursor is hidden during synthetic focus
            // and warped back to the saved position before being shown again, so the user
            // doesn't see any cursor movement. postToPid is insufficient for Electron apps
            // that require full HID event processing.
            try mouseController.click(at: point, button: button, clickCount: clickCount, targetPID: nil)
        }
    }

    // MARK: - Overlay

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
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    }

    @MainActor
    private func _hideFrozenOverlay() {
        _overlayWindow?.orderOut(nil)
    }
}
