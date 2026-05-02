import ApplicationServices
import AppKit
import CoreGraphics

// MARK: - Private CGS API

private let _cgsSetWindowLevel: (@convention(c) (Int32, UInt32, Int32) -> Int32)? = {
    guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
          let s = dlsym(h, "CGSSetWindowLevel") else { return nil }
    return unsafeBitCast(s, to: (@convention(c) (Int32, UInt32, Int32) -> Int32).self)
}()

private let _cgsMainConnectionID: (@convention(c) () -> Int32)? = {
    guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
          let s = dlsym(h, "CGSMainConnectionID") else { return nil }
    return unsafeBitCast(s, to: (@convention(c) () -> Int32).self)
}()

// MARK: - SyntheticAppFocusEnforcer

/// Makes a target app process HID events (including Electron double-click)
/// with minimal visual disruption. Inspired by Codex's SyntheticAppFocusEnforcer.
///
/// ## How it works
///
/// Electron/Chromium apps require real NSApp activation to process HID events.
/// This class performs ultra-fast activation with visual masking:
///
/// 1. **Mask**: Raise ALL user windows to `kCGPopUpMenuWindowLevel` (25).
///    This is above the menu bar (24), so user's windows cover EVERYTHING.
/// 2. **Activate**: `NSRunningApplication.activate()` on the target app.
///    The target window goes behind the user's raised windows — invisible.
/// 3. **Act**: Deliver mouse/keyboard events. The target processes them
///    because it's truly active at the AppKit level.
/// 4. **Restore**: Re-activate user's app, lower windows to normal level.
///    Total target-active time: ~50ms.
///
/// ## Why real activation is needed
///
/// Tested alternatives that DON'T work for Electron double-click:
/// - `_SLPSSetFrontProcessWithOptions` (changes CPS front but Electron still ignores events)
/// - `kAXFrontmostAttribute = true` (causes actual activation with no restore)
/// - `postToPid` without activation (Electron ignores background events)
/// - NSEvent(windowNumber:) without activation (Electron checks NSApp.isActive)
///
/// Only real `NSRunningApplication.activate()` makes Electron accept HID events.
///
/// ## Codex's approach
///
/// The Codex binary uses `SyntheticAppFocusEnforcer` with:
/// - An overlay window (ComputerUseCursor) at a high level that covers everything
/// - `setIgnoresMouseEvents:true` so events pass through the overlay
/// - `orderFrontRegardless` to keep the overlay on top during activation changes
/// This overlay hides the activation/restore cycle completely.
///
/// Our approach uses the same principle but raises the user's existing windows
/// instead of an overlay, achieving a similar visual masking effect.
public final class SyntheticAppFocusEnforcer: @unchecked Sendable {

    public init() {}

    /// Perform an action on a target app with visual masking.
    ///
    /// The target app is briefly activated (~50ms), during which the user's
    /// windows are raised above everything to hide the change.
    ///
    /// - Parameters:
    ///   - targetPID: The target app's process ID
    ///   - action: Closure executed while target is active
    @discardableResult
    public func withSyntheticFocus(targetPID: pid_t, action: () throws -> Void) rethrows -> Bool {
        // Get user's frontmost app
        let userApp = NSWorkspace.shared.frontmostApplication
        guard let userApp = userApp, userApp.processIdentifier != targetPID else {
            // Target is already frontmost — just run action
            try action()
            return true
        }

        let targetApp = NSWorkspace.shared.runningApplications
            .first { $0.processIdentifier == targetPID }
        guard let targetApp = targetApp else {
            try action()
            return false
        }

        // Collect user's on-screen windows
        let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []

        let userWindowIDs = windowList
            .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == userApp.processIdentifier }
            .compactMap { $0[kCGWindowNumber as String] as? UInt32 }

        let connID = _cgsMainConnectionID?() ?? 0

        // --- Phase 1: MASK — raise user windows above everything ---
        if connID != 0, let setLevel = _cgsSetWindowLevel {
            for wid in userWindowIDs {
                // kCGPopUpMenuWindowLevel (25) is above the menu bar (24)
                _ = setLevel(connID, wid, 25)
            }
        }

        // --- Phase 2: ACTIVATE target ---
        targetApp.activate()
        usleep(10000) // 10ms — minimum for activation to take effect

        // --- Phase 3: ACT ---
        defer {
            // --- Phase 4: RESTORE ---
            usleep(20000) // 20ms for events to be processed

            userApp.activate()
            usleep(50000) // 50ms for restoration to take effect

            // Restore user window levels
            if connID != 0, let setLevel = _cgsSetWindowLevel {
                for wid in userWindowIDs {
                    _ = setLevel(connID, wid, 0) // kCGNormalWindowLevel
                }
            }
        }

        try action()
        return true
    }

    /// Perform a click on a target app using synthetic focus with visual masking.
    /// Handles cursor save/restore and event delivery.
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

            // Use plain CGEvent for clicks (works when app is active)
            try mouseController.click(at: point, button: button, clickCount: clickCount)
        }

        // Restore cursor
        CGWarpMouseCursorPosition(savedPos)
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}
