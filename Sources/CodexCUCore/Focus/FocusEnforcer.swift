import ApplicationServices
import AppKit

/// Manages app focus to allow background interaction without stealing user focus.
/// Uses AXEnhancedUserInterface to make apps respond to AX actions in the background.
public final class FocusEnforcer: @unchecked Sendable {
    private var enhancedApps: Set<pid_t> = []
    private let lock = NSLock()

    public init() {}

    /// Enable enhanced UI for an app, allowing AX actions in the background
    public func enableEnhancedUI(pid: pid_t) {
        lock.lock()
        defer { lock.unlock() }

        guard !enhancedApps.contains(pid) else { return }

        let appElement = AXUIElement.applicationElement(pid: pid)
        let result = AXUIElementSetAttributeValue(
            appElement,
            "AXEnhancedUserInterface" as CFString,
            kCFBooleanTrue
        )

        if result == .success || result == .attributeUnsupported {
            enhancedApps.insert(pid)
        }
    }

    /// Disable enhanced UI for an app
    public func disableEnhancedUI(pid: pid_t) {
        lock.lock()
        defer { lock.unlock() }

        let appElement = AXUIElement.applicationElement(pid: pid)
        AXUIElementSetAttributeValue(
            appElement,
            "AXEnhancedUserInterface" as CFString,
            kCFBooleanFalse
        )
        enhancedApps.remove(pid)
    }

    /// Clean up all enhanced apps
    public func disableAll() {
        lock.lock()
        let pids = enhancedApps
        lock.unlock()

        for pid in pids {
            disableEnhancedUI(pid: pid)
        }
    }

    deinit {
        // Best-effort cleanup
        for pid in enhancedApps {
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(
                appElement,
                "AXEnhancedUserInterface" as CFString,
                kCFBooleanFalse
            )
        }
    }
}
