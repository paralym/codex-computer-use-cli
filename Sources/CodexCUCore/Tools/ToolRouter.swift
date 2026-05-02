import ApplicationServices
import AppKit

/// Target for element-based operations
public enum ElementTarget: Sendable {
    case index(Int)
    case coordinates(x: Double, y: Double)
}

/// Result from a tool execution
public struct ToolResult: Sendable {
    public enum ContentItem: Sendable {
        case text(String)
        case image(base64: String, mimeType: String)
    }

    public let content: [ContentItem]
    public let isError: Bool

    public init(content: [ContentItem], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public static func text(_ text: String) -> ToolResult {
        ToolResult(content: [.text(text)])
    }

    public static func error(_ message: String) -> ToolResult {
        ToolResult(content: [.text(message)], isError: true)
    }
}

/// Central tool dispatcher with zero-activation background focus management.
///
/// Strategy (4 tiers):
/// 1. AX actions (zero activation) — AXPress, AXOpen etc.
/// 2. AX hit-test → AXPress (zero activation)
/// 3. CGEvent.postToPid (zero activation for native apps)
/// 4. SyntheticAppFocusEnforcer — makes app BELIEVE it's active via CPS-level
///    focus change, delivers events, restores. Zero visual change (<10ms cycle).
public actor ToolRouter {
    private let appManager = AppManager()
    private let skyshotCapture = SkyshotCapture()
    private let mouseController = MouseController()
    private let keyboardController = KeyboardController()
    private let focusEnforcer = FocusEnforcer()
    private let focusStealPreventer = FocusStealPreventer()
    private let syntheticFocusEnforcer = SyntheticAppFocusEnforcer()

    /// PID of the app we're currently operating on
    private var targetAppPID: pid_t?
    /// The user's frontmost app — used to restore focus
    private var userFrontmostAppPID: pid_t?

    public init() {
        ensureCGSInitialized()
    }

    // MARK: - list_apps

    public func listApps() async -> ToolResult {
        let apps = await appManager.listRunningApps()
        var lines = ["Running applications (\(apps.count)):"]
        for app in apps {
            let status = app.isActive ? " [active]" : (app.isHidden ? " [hidden]" : "")
            lines.append("  \(app.name) (\(app.bundleIdentifier ?? "unknown"))\(status)")
        }
        return .text(lines.joined(separator: "\n"))
    }

    // MARK: - launch_app

    public func launchApp(name: String) async -> ToolResult {
        do {
            let app = try await appManager.launchApp(named: name)
            return .text("Launched \(app.localizedName ?? name) (pid: \(app.processIdentifier))")
        } catch {
            return .error("Failed to launch '\(name)': \(error)")
        }
    }

    // MARK: - activate_app

    public func activateApp(name: String) async -> ToolResult {
        do {
            let app = try await appManager.activateApp(named: name)
            return .text("Activated \(app.localizedName ?? name)")
        } catch {
            return .error("Failed to activate '\(name)': \(error)")
        }
    }

    // MARK: - get_app_state (ZERO focus change)

    public func getAppState(appName: String, includeScreenshot: Bool = true) async -> ToolResult {
        guard let app = await appManager.findApp(named: appName) else {
            return .error("App '\(appName)' not found. Use list_apps to see running apps, or launch_app to start one.")
        }

        // Record user's frontmost app
        let userPID = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        if let userPID = userPID, userPID != app.processIdentifier {
            userFrontmostAppPID = userPID
        }

        focusEnforcer.enableEnhancedUI(pid: app.processIdentifier)

        if targetAppPID != app.processIdentifier {
            targetAppPID = app.processIdentifier
            await MainActor.run {
                focusStealPreventer.stop()
                focusStealPreventer.start(targetPID: app.processIdentifier)
            }
        }

        do {
            let skyshot = try await skyshotCapture.capture(
                pid: app.processIdentifier,
                appName: app.localizedName ?? appName
            )
            if includeScreenshot && !skyshot.screenshotBase64.isEmpty {
                return ToolResult(content: [
                    .text(skyshot.treeDescription),
                    .image(base64: skyshot.screenshotBase64, mimeType: "image/jpeg"),
                ])
            } else {
                var desc = skyshot.treeDescription
                if skyshot.screenshotBase64.isEmpty {
                    desc += "\n\n[Screenshot unavailable — app may be on another Space. Use activate_app to bring it to current Space.]"
                }
                return ToolResult(content: [.text(desc)])
            }
        } catch {
            return .error("Failed to capture app state: \(error). If the app is minimized, use activate_app first.")
        }
    }

    // MARK: - click

    public func click(target: ElementTarget, button: MouseButton = .left, clickCount: Int = 1) async -> ToolResult {
        // Resolve click point early for cursor animation
        let clickPoint: CGPoint
        do {
            clickPoint = try await resolvePoint(target: target)
        } catch {
            return .error("Click failed: \(error)")
        }

        // Strategy 1: AX action (zero activation) — only for single left-clicks
        if case .index(let idx) = target, button == .left, clickCount == 1 {
            let success = await skyshotCapture.tryClickAction(atIndex: idx)
            if success {
                await guardFocusAfterAXAction()
                // Virtual cursor disabled — target app is in background, cursor would appear
                // on the wrong window. Enable when fog overlay (FogCursorStyle) is implemented.
                return .text("Clicked element \(idx) via AX (background)")
            }
        }

        // Strategy 2: AX hit-test → AXPress (zero activation) — only for single left-clicks
        if button == .left, clickCount == 1, let pid = targetAppPID {
            let appElement = AXUIElement.applicationElement(pid: pid)
            if let hitElement = appElement.elementAtPosition(clickPoint) {
                var candidate: AXUIElement? = hitElement
                for _ in 0..<4 {
                    guard let el = candidate else { break }
                    for action in ["AXPress", "AXOpen", "AXConfirm"] {
                        if el.actionNames.contains(action) {
                            if (try? el.performAction(action)) != nil {
                                await guardFocusAfterAXAction()
                                // Virtual cursor disabled — target app is in background, cursor would appear
                // on the wrong window. Enable when fog overlay (FogCursorStyle) is implemented.
                                return .text("Clicked at (\(Int(clickPoint.x)), \(Int(clickPoint.y))) via AX hit-test (background)")
                            }
                        }
                    }
                    candidate = el.parent
                }
            }
        }

        // Strategy 3: CGEvent via postToPid (zero activation for native apps)
        if clickCount == 1 {
            do {
                try mouseController.click(at: clickPoint, button: button, clickCount: 1, targetPID: targetAppPID)
                // Virtual cursor disabled — target app is in background, cursor would appear
                // on the wrong window. Enable when fog overlay (FogCursorStyle) is implemented.
                return .text("Clicked at (\(Int(clickPoint.x)), \(Int(clickPoint.y))) \(button.rawValue) (background)")
            } catch {
                return .error("Click failed: \(error)")
            }
        }

        // Strategy 4: SyntheticAppFocusEnforcer — frozen overlay + CPS-level focus change.
        // Virtual cursor shown AFTER overlay removed (so it appears on the real screen).
        // Must disable FocusStealPreventer during this.
        if let pid = targetAppPID {
            await MainActor.run { focusStealPreventer.stop() }

            do {
                try syntheticFocusEnforcer.click(
                    at: clickPoint,
                    targetPID: pid,
                    windowNumber: nil,
                    button: button,
                    clickCount: clickCount,
                    mouseController: mouseController
                )
            } catch {
                await MainActor.run { focusStealPreventer.start(targetPID: pid) }
                return .error("Click failed: \(error)")
            }

            await MainActor.run { focusStealPreventer.start(targetPID: pid) }

            // Show cursor AFTER overlay is removed — user sees it on the real screen
            // Virtual cursor disabled — target app is in background, cursor would appear
                // on the wrong window. Enable when fog overlay (FogCursorStyle) is implemented.
            return .text("Clicked at (\(Int(clickPoint.x)), \(Int(clickPoint.y))) \(button.rawValue) x\(clickCount) (synthetic focus)")
        }

        // No target PID — global click
        do {
            try mouseController.click(at: clickPoint, button: button, clickCount: clickCount)
            // Virtual cursor disabled — target app is in background, cursor would appear
                // on the wrong window. Enable when fog overlay (FogCursorStyle) is implemented.
            return .text("Clicked at (\(Int(clickPoint.x)), \(Int(clickPoint.y))) \(button.rawValue) x\(clickCount)")
        } catch {
            return .error("Click failed: \(error)")
        }
    }

    /// Show virtual cursor at the click position, pulse, then hide after delay.
    /// For Strategy 4 (synthetic focus), this is called AFTER the overlay is removed
    /// so the cursor appears on the real screen, not the frozen screenshot.
    private func showCursorAt(_ point: CGPoint) async {
        await MainActor.run {
            let c = ComputerUseCursor.shared
            c.show()
            c.moveTo(point, animated: false)
            c.pulseClick()
        }
        try? await Task.sleep(for: .milliseconds(1500))
        await MainActor.run { ComputerUseCursor.shared.hide() }
    }

    // MARK: - perform_secondary_action

    public func performSecondaryAction(target: ElementTarget) async -> ToolResult {
        if case .index(let idx) = target {
            let actions = await skyshotCapture.actionNames(atIndex: idx)
            if actions.contains("AXShowMenu") {
                do {
                    try await skyshotCapture.performAction(atIndex: idx, action: "AXShowMenu")
                    await guardFocusAfterAXAction()
                    return .text("Secondary action on element \(idx) via AX (background)")
                } catch {}
            }
        }

        do {
            let point = try await resolvePoint(target: target)
            try mouseController.click(at: point, button: .right, clickCount: 1, targetPID: targetAppPID)
            return .text("Right-clicked at (\(Int(point.x)), \(Int(point.y))) (background)")
        } catch {
            return .error("Secondary action failed: \(error)")
        }
    }

    // MARK: - scroll

    public func scroll(target: ElementTarget, direction: ScrollDirection, pages: Double = 1.0) async -> ToolResult {
        if case .index(let idx) = target {
            let axAction = switch direction {
            case .up: "AXScrollUpByPage"
            case .down: "AXScrollDownByPage"
            case .left: "AXScrollLeftByPage"
            case .right: "AXScrollRightByPage"
            }
            let actions = await skyshotCapture.actionNames(atIndex: idx)
            if actions.contains(axAction) {
                let scrollCount = max(1, Int(ceil(pages)))
                for _ in 0..<scrollCount {
                    do { try await skyshotCapture.performAction(atIndex: idx, action: axAction) } catch { break }
                }
                return .text("Scrolled \(direction.rawValue) \(pages) pages on element \(idx) (background)")
            }
        }

        do {
            let point = try await resolvePoint(target: target)
            try mouseController.scroll(at: point, direction: direction, pages: pages, targetPID: targetAppPID)
            return .text("Scrolled \(direction.rawValue) \(pages) pages at (\(Int(point.x)), \(Int(point.y))) (background)")
        } catch {
            return .error("Scroll failed: \(error)")
        }
    }

    // MARK: - drag

    public func drag(startX: Double, startY: Double, endX: Double, endY: Double) async -> ToolResult {
        do {
            try await withSyntheticActivation {
                try self.mouseController.drag(
                    from: CGPoint(x: startX, y: startY),
                    to: CGPoint(x: endX, y: endY)
                )
            }
            return .text("Dragged from (\(Int(startX)), \(Int(startY))) to (\(Int(endX)), \(Int(endY))) (synthetic focus)")
        } catch {
            return .error("Drag failed: \(error)")
        }
    }

    public func drag(fromIndex: Int, toIndex: Int) async -> ToolResult {
        do {
            let startPoint = try await resolvePoint(target: .index(fromIndex))
            let endPoint = try await resolvePoint(target: .index(toIndex))
            try await withSyntheticActivation {
                try self.mouseController.drag(from: startPoint, to: endPoint)
            }
            return .text("Dragged element \(fromIndex) to \(toIndex) (synthetic focus)")
        } catch {
            return .error("Drag failed: \(error)")
        }
    }

    // MARK: - type_text

    public func typeText(_ text: String) async -> ToolResult {
        // Strategy 1: AX set_value (zero activation)
        if let pid = targetAppPID {
            let appElement = AXUIElement.applicationElement(pid: pid)
            if let focusedElement: AXUIElement = appElement.attribute(kAXFocusedUIElementAttribute) {
                let role = focusedElement.role ?? ""
                if role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox" || role == "AXSearchField" {
                    let currentValue = focusedElement.axValue ?? ""
                    let newValue = currentValue + text
                    let result = AXUIElementSetAttributeValue(
                        focusedElement,
                        kAXValueAttribute as CFString,
                        newValue as CFTypeRef
                    )
                    if result == .success {
                        return .text("Typed \(text.count) characters via AX set_value (background)")
                    }
                }
            }
        }

        // Strategy 2: CGEvent keyboard via postToPid
        do {
            try keyboardController.typeText(text, targetPID: targetAppPID)
            return .text("Typed \(text.count) characters (background)")
        } catch {
            return .error("Type failed: \(error)")
        }
    }

    // MARK: - press_key

    public func pressKey(_ keySpec: String) async -> ToolResult {
        if let pid = targetAppPID, keySpec.lowercased().hasPrefix("super+") {
            let menuResult = await tryMenuShortcut(pid: pid, keySpec: keySpec)
            if let result = menuResult { return result }
        }

        do {
            try keyboardController.pressKey(keySpec, targetPID: targetAppPID)
            return .text("Pressed key: \(keySpec) (background)")
        } catch {
            return .error("Key press failed: \(error)")
        }
    }

    private func tryMenuShortcut(pid: pid_t, keySpec: String) async -> ToolResult? {
        let appElement = AXUIElement.applicationElement(pid: pid)
        guard let menuBar: AXUIElement = appElement.attribute(kAXMenuBarAttribute) else { return nil }

        let shortcutToMenu: [String: [String]] = [
            "super+s": ["保存", "Save", "存储"],
            "super+shift+s": ["另存为", "Save As", "存储为"],
            "super+z": ["撤销", "Undo", "还原"],
            "super+shift+z": ["重做", "Redo"],
            "super+c": ["拷贝", "Copy", "复制"],
            "super+v": ["粘贴", "Paste"],
            "super+x": ["剪切", "Cut"],
            "super+a": ["全选", "Select All", "全部选定"],
            "super+n": ["新建", "New", "新建文稿", "新建窗口"],
            "super+o": ["打开", "Open"],
            "super+w": ["关闭", "Close", "关闭窗口"],
            "super+p": ["打印", "Print"],
            "super+f": ["查找", "Find", "搜索"],
        ]

        guard let menuTitles = shortcutToMenu[keySpec.lowercased()] else { return nil }

        if let menuItem = findMenuItem(in: menuBar, titles: menuTitles) {
            do {
                try menuItem.performAction("AXPress")
                return .text("Pressed \(keySpec) via menu item (background)")
            } catch {}
        }
        return nil
    }

    private func findMenuItem(in element: AXUIElement, titles: [String], depth: Int = 0) -> AXUIElement? {
        guard depth < 4 else { return nil }
        for child in element.children {
            let childRole = child.role ?? ""
            let childTitle = child.title ?? ""
            if childRole == "AXMenuItem" || childRole == "AXMenuBarItem" {
                for title in titles {
                    if childTitle.contains(title) && child.actionNames.contains("AXPress") {
                        return child
                    }
                }
            }
            if let found = findMenuItem(in: child, titles: titles, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    // MARK: - set_value (pure AX)

    public func setValue(index: Int, value: String) async -> ToolResult {
        do {
            try await skyshotCapture.setValue(atIndex: index, value: value)
            return .text("Set value of element \(index) to \"\(value)\" (background)")
        } catch {
            return .error("Set value failed: \(error)")
        }
    }

    // MARK: - Synthetic Focus Activation

    /// Execute an action with synthetic focus on the target app.
    /// Uses CPS-level focus change — zero visual disruption.
    private func withSyntheticActivation(_ action: @Sendable () throws -> Void) async throws {
        guard let pid = targetAppPID else {
            try action()
            return
        }
        try syntheticFocusEnforcer.withSyntheticFocus(targetPID: pid, action: action)
    }

    // MARK: - Focus Guard

    private func guardFocusAfterAXAction() async {
        guard let targetPID = targetAppPID,
              let userPID = userFrontmostAppPID,
              userPID != targetPID else { return }

        try? await Task.sleep(for: .milliseconds(150))

        let needsRestore = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID
        }

        if needsRestore {
            await MainActor.run {
                NSWorkspace.shared.runningApplications
                    .first { $0.processIdentifier == userPID }?
                    .activate()
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - Helpers

    private func resolvePoint(target: ElementTarget) async throws -> CGPoint {
        switch target {
        case .index(let idx):
            guard let center = await skyshotCapture.elementCenter(atIndex: idx) else {
                let stale = await skyshotCapture.isStale()
                let count = await skyshotCapture.elementCount()
                var parts: [String] = ["Element at index \(idx) not found."]
                parts.append("Current capture has \(count) elements (indices 0..\(max(0, count - 1))).")
                if stale {
                    parts.append("The captured state is stale — call get_app_state again to refresh.")
                } else {
                    parts.append("Call get_app_state to refresh the element tree.")
                }
                throw ToolError.elementNotFound(idx, hint: parts.joined(separator: " "), lastCapturedElementCount: count)
            }
            return center
        case .coordinates(let x, let y):
            return CGPoint(x: x, y: y)
        }
    }

    public func shutdown() {
        focusEnforcer.disableAll()
        focusStealPreventer.stop()
    }
}

public enum ToolError: Error, Sendable {
    case elementNotFound(Int, hint: String = "", lastCapturedElementCount: Int = 0)
    case appNotFound(String)
    case permissionDenied
}

extension ToolError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .elementNotFound(let idx, let hint, _):
            return hint.isEmpty ? "Element at index \(idx) not found. Call get_app_state first." : hint
        case .appNotFound(let name):
            return "App '\(name)' not found."
        case .permissionDenied:
            return "Permission denied. Grant Accessibility and Screen Recording permissions."
        }
    }
}
