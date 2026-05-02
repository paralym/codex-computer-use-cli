import ApplicationServices
import AppKit
import CoreGraphics

// MARK: - Private API

@_silgen_name("GetProcessForPID")
private func _getProcessForPID(_ pid: pid_t, _ psn: UnsafeMutableRawPointer) -> Int32

@_silgen_name("GetFrontProcess")
private func _getFrontProcess(_ psn: UnsafeMutableRawPointer) -> Int16

/// ProcessSerialNumber layout — matches Carbon's PSN struct.
private struct PSN {
    var highLongOfPSN: UInt32 = 0
    var lowLongOfPSN: UInt32 = 0
}

/// Private SkyLight API — changes the CPS-level front process.
/// Sends kCPSNotifyNewFront to the target app, making its AppKit layer
/// set NSApp.isActive = true. Unlike NSRunningApplication.activate(),
/// this does NOT change window ordering or the menu bar.
private let _slpsSetFrontProcessWithOptions: (@convention(c) (UnsafeMutableRawPointer, UInt32) -> Int32)? = {
    guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
          let sym = dlsym(handle, "_SLPSSetFrontProcessWithOptions") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (UnsafeMutableRawPointer, UInt32) -> Int32).self)
}()

// MARK: - SyntheticAppFocusEnforcer

/// Makes a target app process HID events (including Electron double-click)
/// with zero visual disruption. Replicates Codex's SyntheticAppFocusEnforcer.
///
/// ## How it works
///
/// Uses the private SkyLight API `_SLPSSetFrontProcessWithOptions` to change
/// the CPS (Core Policy Server) level front process. This makes the target
/// app believe it's active (`NSApp.isActive = true`) WITHOUT:
/// - Changing window ordering (no z-order change)
/// - Changing the menu bar
/// - Any visual disruption whatsoever
///
/// Flow:
/// 1. Save current front process PSN
/// 2. `_SLPSSetFrontProcessWithOptions(&targetPSN, 0)` — target thinks it's active
/// 3. Wait 20ms for CPS notification to propagate to Electron's event loop
/// 4. Deliver HID mouse events via `CGEvent.post(tap: .cghidEventTap)`
/// 5. Wait 50ms for events to be processed
/// 6. `_SLPSSetFrontProcessWithOptions(&frontPSN, 0)` — restore original front
///
/// Total cycle: ~120ms. Zero visual change. Zero flicker.
///
/// ## Key finding
///
/// `_SLPSSetFrontProcessWithOptions` with 20ms+ wait DOES make Electron
/// process HID events. Earlier tests with 5ms failed because the CPS
/// notification hadn't propagated to Electron's Chromium event loop yet.
/// 20ms is the minimum reliable wait time.
public final class SyntheticAppFocusEnforcer: @unchecked Sendable {

    public init() {}

    // MARK: - Core: Synthetic Focus

    /// Temporarily make the target app the CPS-level front process,
    /// perform an action, then restore the original front process.
    ///
    /// Zero visual disruption — no window movement, no menu bar change.
    @discardableResult
    public func withSyntheticFocus(targetPID: pid_t, action: () throws -> Void) rethrows -> Bool {
        guard let slpsSetFront = _slpsSetFrontProcessWithOptions else {
            // Private API not available — run action without synthetic focus
            try action()
            return false
        }

        var targetPSN = PSN()
        var frontPSN = PSN()

        guard _getProcessForPID(targetPID, &targetPSN) == 0 else {
            try action()
            return false
        }
        guard _getFrontProcess(&frontPSN) == 0 else {
            try action()
            return false
        }

        // Already front — just run action
        if targetPSN.highLongOfPSN == frontPSN.highLongOfPSN
            && targetPSN.lowLongOfPSN == frontPSN.lowLongOfPSN {
            try action()
            return true
        }

        // --- Phase 1: CPS-level activate ---
        // Target receives kCPSNotifyNewFront → NSApp.isActive = true
        // No window ordering change, no menu bar change.
        _ = slpsSetFront(&targetPSN, 0)

        // 20ms for CPS notification to propagate through:
        // WindowServer → Mach IPC → Chromium browser process → renderer
        usleep(20000)

        // --- Phase 2: Execute action ---
        defer {
            // --- Phase 3: Restore ---
            usleep(50000) // 50ms for events to be fully processed

            _ = slpsSetFront(&frontPSN, 0)
        }

        try action()
        return true
    }

    // MARK: - Convenience: Click

    /// Perform a click on a target app using CPS-level synthetic focus.
    /// Zero visual disruption — no flicker, no window movement.
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
