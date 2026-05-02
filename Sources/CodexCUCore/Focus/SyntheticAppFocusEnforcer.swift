import ApplicationServices
import AppKit
import CoreGraphics

// MARK: - Private API

@_silgen_name("GetProcessForPID")
private func _getProcessForPID(_ pid: pid_t, _ psn: UnsafeMutableRawPointer) -> Int32

@_silgen_name("GetFrontProcess")
private func _getFrontProcess(_ psn: UnsafeMutableRawPointer) -> Int16

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
/// with minimal visual disruption. Replicates Codex's SyntheticAppFocusEnforcer.
///
/// ## How it works
///
/// 1. **Overlay**: Show a fullscreen transparent click-through window at
///    `kCGPopUpMenuWindowLevel` (above menu bar). Flush rendering.
/// 2. **CPS activate**: `_SLPSSetFrontProcessWithOptions` makes the target
///    the CPS-level front process. The target calls `orderFront:` on its
///    windows, but they stay behind our overlay.
/// 3. **HID click**: Events posted via `.cghidEventTap` skip the overlay
///    (`ignoresMouseEvents = true`) and reach the target window.
/// 4. **Restore**: Restore original CPS front, remove overlay.
///
/// The overlay approach matches Codex's `ComputerUseCursor` which uses
/// `setIgnoresMouseEvents:`, `orderFrontRegardless`, and a high window level
/// to mask activation changes.
public final class SyntheticAppFocusEnforcer: @unchecked Sendable {

    private var _overlayWindow: NSWindow?

    public init() {}

    // MARK: - Overlay

    @MainActor
    private func ensureOverlay() -> NSWindow {
        if let w = _overlayWindow { return w }
        let fullFrame = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        let w = NSWindow(contentRect: fullFrame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)))
        w.isOpaque = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.hasShadow = false
        let v = NSView(frame: fullFrame); v.wantsLayer = true
        w.contentView = v
        _overlayWindow = w
        return w
    }

    @MainActor
    private func showOverlay() {
        let w = ensureOverlay()
        w.orderFrontRegardless()
        // Pump run loop to ensure overlay is composited before CPS change
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    @MainActor
    private func hideOverlay() {
        _overlayWindow?.orderOut(nil)
    }

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

        // Phase 1: Show overlay (covers everything including menu bar)
        if Thread.isMainThread {
            MainActor.assumeIsolated { showOverlay() }
        } else {
            DispatchQueue.main.sync { [self] in MainActor.assumeIsolated { showOverlay() } }
        }

        // Phase 2: CPS activate — target's orderFront: goes behind overlay
        _ = slpsSetFront(&targetPSN, 0)
        usleep(50000) // 50ms for CPS notification to propagate

        defer {
            // Phase 4: Restore
            usleep(50000)
            _ = slpsSetFront(&frontPSN, 0)
            usleep(20000)
            if Thread.isMainThread {
                MainActor.assumeIsolated { hideOverlay() }
            } else {
                DispatchQueue.main.sync { [self] in MainActor.assumeIsolated { hideOverlay() } }
            }
        }

        // Phase 3: Action (HID events skip overlay via ignoresMouseEvents)
        try action()
        return true
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
        let savedPos = CGEvent(source: nil)?.location ?? .zero

        try withSyntheticFocus(targetPID: targetPID) {
            CGWarpMouseCursorPosition(point)
            CGAssociateMouseAndMouseCursorPosition(1)
            try mouseController.click(at: point, button: button, clickCount: clickCount)
        }

        CGWarpMouseCursorPosition(savedPos)
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}
