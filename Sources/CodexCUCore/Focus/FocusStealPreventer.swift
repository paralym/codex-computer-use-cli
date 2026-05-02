import AppKit

/// Monitors app activation and reverts focus theft caused by AX actions.
/// When we perform an AX action (like AXPress) on a background app, the app
/// may activate itself as a side effect. This class catches that and immediately
/// restores focus to the user's original frontmost app.
public final class FocusStealPreventer: @unchecked Sendable {
    private var isActive = false
    private var userFrontmostApp: NSRunningApplication?
    private var savedMousePosition: CGPoint?
    private var targetAppPID: pid_t?
    private var observer: NSObjectProtocol?
    private let lock = NSLock()

    public init() {}

    /// Start monitoring. Records the current frontmost app and mouse position as "user's state".
    @MainActor
    public func start(targetPID: pid_t) {
        lock.lock()
        defer { lock.unlock() }

        guard !isActive else {
            // Update target PID if already active
            targetAppPID = targetPID
            return
        }
        isActive = true
        targetAppPID = targetPID

        // Record user's current frontmost app and mouse position
        userFrontmostApp = NSWorkspace.shared.frontmostApplication
        savedMousePosition = CGEvent(source: nil)?.location

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleActivation(notification)
        }
    }

    /// Stop monitoring
    public func stop() {
        lock.lock()
        defer { lock.unlock() }

        isActive = false
        if let observer = observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
        targetAppPID = nil
        userFrontmostApp = nil
        savedMousePosition = nil
    }

    /// Update the recorded user frontmost app (call when user switches apps themselves)
    @MainActor
    public func updateUserApp() {
        lock.lock()
        defer { lock.unlock() }
        guard isActive else { return }
        userFrontmostApp = NSWorkspace.shared.frontmostApplication
        savedMousePosition = CGEvent(source: nil)?.location
    }

    private func handleActivation(_ notification: Notification) {
        lock.lock()
        guard isActive,
              let activatedApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let targetPID = targetAppPID,
              activatedApp.processIdentifier == targetPID,
              let userApp = userFrontmostApp,
              userApp.processIdentifier != targetPID
        else {
            lock.unlock()
            return
        }
        let mousePos = savedMousePosition
        lock.unlock()

        // Target app stole focus — restore user's app immediately
        // Use asyncAfter with minimal delay to let the activation settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            userApp.activate()

            // Restore mouse position if saved
            if let pos = mousePos {
                if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: pos, mouseButton: .left) {
                    moveEvent.post(tap: .cghidEventTap)
                }
            }
        }
    }

    deinit {
        if let observer = observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}
