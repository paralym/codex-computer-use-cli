import ApplicationServices
import CoreGraphics
import Foundation

/// Skyshot = Screenshot + AX Tree, the core data structure for computer use
public struct Skyshot: Sendable {
    public let screenshot: CGImage
    public let screenshotBase64: String
    public let tree: [AXTreeNode]
    public let flatElements: [AXTreeNode]
    public let appName: String
    public let windowTitle: String?
    public let captureTimestamp: Date

    public init(
        screenshot: CGImage,
        screenshotBase64: String,
        tree: [AXTreeNode],
        flatElements: [AXTreeNode],
        appName: String,
        windowTitle: String?,
        captureTimestamp: Date = Date()
    ) {
        self.screenshot = screenshot
        self.screenshotBase64 = screenshotBase64
        self.tree = tree
        self.flatElements = flatElements
        self.appName = appName
        self.windowTitle = windowTitle
        self.captureTimestamp = captureTimestamp
    }

    /// Text description of the AX tree for LLM consumption
    public var treeDescription: String {
        var lines = ["App: \(appName)"]
        if let wt = windowTitle { lines.append("Window: \(wt)") }
        lines.append("Elements (\(flatElements.count)):")
        lines.append("")
        for root in tree {
            lines.append(root.textRepresentation())
        }
        return lines.joined(separator: "\n")
    }
}

/// Wrapper to make AXUIElement usable across concurrency boundaries
public struct SendableAXUIElement: @unchecked Sendable {
    public let element: AXUIElement
    public init(_ element: AXUIElement) { self.element = element }
}

/// Actor that captures and caches Skyshots, mapping element indices to live AXUIElements
public actor SkyshotCapture {
    private let screenCapture = ScreenCapture()
    private let treeWalker = AXTreeWalker()
    private var lastElementMap: [Int: SendableAXUIElement] = [:]
    private var lastSkyshot: Skyshot?
    /// The CGWindowID of the captured window, for targeted event delivery
    private var lastWindowNumber: CGWindowID?
    /// Y offset to correct element coordinates (currently unused — AX coordinates are accurate)
    private var electronYOffset: CGFloat = 0

    public init() {}

    /// Capture a fresh Skyshot for the given app.
    /// Screenshot may fail (e.g., app on another Space) — in that case we still return the AX tree.
    public func capture(pid: pid_t, appName: String) async throws -> Skyshot {
        let appElement = AXUIElement.applicationElement(pid: pid)

        // Always get AX tree (works in background regardless of Space)
        let (roots, elementMap) = treeWalker.walk(appElement: appElement)

        // Try screenshot — may fail for apps on other Spaces or minimized
        var image: CGImage? = nil
        var base64: String = ""
        do {
            let captured = try await screenCapture.captureWindow(pid: pid)
            image = captured
            base64 = captured.base64JPEG(quality: 0.7) ?? ""
        } catch {
            // Screenshot failed but AX tree is still usable
            NSLog("[SkyshotCapture] Screenshot failed (app may be on another Space): \(error)")
        }

        // Flatten tree
        var flat: [AXTreeNode] = []
        for root in roots {
            flat.append(contentsOf: root.flatten())
        }

        // Get window title
        let windowTitle: String? = {
            let windows: [AXUIElement] = appElement.children
            return windows.first?.title
        }()

        let skyshot = Skyshot(
            screenshot: image ?? createPlaceholderImage(),
            screenshotBase64: base64,
            tree: roots,
            flatElements: flat,
            appName: appName,
            windowTitle: windowTitle
        )

        self.lastSkyshot = skyshot
        self.lastElementMap = elementMap.mapValues { SendableAXUIElement($0) }

        // Store windowNumber for targeted CGEvent delivery
        self.lastWindowNumber = Self.lookupWindowNumber(pid: pid)

        // Detect Electron Y offset: compare window frame with HTML content frame
        self.electronYOffset = Self.detectElectronYOffset(appElement: appElement)

        return skyshot
    }

    /// Create a tiny placeholder image when screenshot is unavailable
    private func createPlaceholderImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                           bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    /// Get the live AXUIElement for a given index from the last capture
    public func element(atIndex index: Int) -> SendableAXUIElement? {
        lastElementMap[index]
    }

    /// Check if the last capture is older than the given threshold
    public func isStale(threshold: TimeInterval = 30) -> Bool {
        guard let skyshot = lastSkyshot else { return true }
        return Date().timeIntervalSince(skyshot.captureTimestamp) > threshold
    }

    /// Get the center point of an element by index, using AX frame coordinates.
    /// For Electron apps, automatically corrects the Y coordinate offset caused by
    /// Electron's AX implementation reporting positions with an extra title bar offset.
    public func elementCenter(atIndex index: Int) -> CGPoint? {
        if isStale(threshold: 30) {
            NSLog("[SkyshotCapture] Warning: element map is stale (>30s old). Consider re-capturing before interacting.")
        }

        guard let wrapper = lastElementMap[index],
              let frame = wrapper.element.frame else { return nil }

        return CGPoint(x: frame.midX, y: frame.midY - electronYOffset)
    }

    /// Perform an AX action on an element by index (inside actor to avoid Sendable issues)
    public func performAction(atIndex index: Int, action: String) throws {
        guard let wrapper = lastElementMap[index] else {
            throw ToolError.elementNotFound(index)
        }
        try wrapper.element.performAction(action)
    }

    /// Try to perform a click-like AX action on an element or its children.
    /// Tries AXPress, AXOpen, AXConfirm in order. Returns true if successful.
    public func tryClickAction(atIndex index: Int) -> Bool {
        guard let wrapper = lastElementMap[index] else { return false }
        let element = wrapper.element
        let clickActions = ["AXPress", "AXOpen", "AXConfirm"]

        // Try on the element itself
        for action in clickActions {
            if element.actionNames.contains(action) {
                if (try? element.performAction(action)) != nil {
                    return true
                }
            }
        }

        // Try on immediate children (e.g., Row > Cell that has AXOpen)
        for child in element.children {
            for action in clickActions {
                if child.actionNames.contains(action) {
                    if (try? child.performAction(action)) != nil {
                        return true
                    }
                }
            }
        }

        // NOTE: Do NOT try parent elements — in Electron apps, the parent's AXPress
        // often selects the wrong item (it selects the container, not the specific child).

        return false
    }

    /// Set value on an element by index
    public func setValue(atIndex index: Int, value: String) throws {
        guard let wrapper = lastElementMap[index] else {
            throw ToolError.elementNotFound(index)
        }
        try wrapper.element.setValue(value as CFTypeRef)
    }

    /// Get action names for an element
    public func actionNames(atIndex index: Int) -> [String] {
        lastElementMap[index]?.element.actionNames ?? []
    }

    /// Get the AX value of an element by index (for re-scanning after scroll)
    public func elementValue(atIndex index: Int) -> String? {
        lastElementMap[index]?.element.axValue
    }

    /// Number of elements in the last capture
    public func elementCount() -> Int {
        lastElementMap.count
    }

    /// Get the last captured Skyshot
    public func lastCapture() -> Skyshot? {
        lastSkyshot
    }

    /// Clear cached state
    public func invalidate() {
        lastSkyshot = nil
        lastElementMap = [:]
        lastWindowNumber = nil
    }

    /// Scroll an element into visible area via AXScrollToVisible
    public func scrollToVisible(atIndex index: Int) {
        guard let wrapper = lastElementMap[index] else { return }
        _ = try? wrapper.element.performAction("AXScrollToVisible")
    }

    /// Get the stored window number for targeted CGEvent delivery
    public func windowNumber() -> CGWindowID? {
        lastWindowNumber
    }

    /// Detect Y coordinate offset for element positions. Currently returns 0 —
    /// AX frame coordinates are accurate when using HID events via synthetic focus.
    private static func detectElectronYOffset(appElement: AXUIElement) -> CGFloat {
        return 0
    }

    /// Look up the CGWindowID for a given PID from CGWindowListCopyWindowInfo
    private static func lookupWindowNumber(pid: pid_t) -> CGWindowID? {
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

        let appWindows = windowList.filter { info in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int32 else { return false }
            return ownerPID == pid
        }

        // Return the first on-screen window (typically the key window)
        return appWindows.first?[kCGWindowNumber as String] as? CGWindowID
    }
}
