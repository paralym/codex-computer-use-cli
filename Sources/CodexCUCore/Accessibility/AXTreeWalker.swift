import ApplicationServices
import AppKit

public final class AXTreeWalker: Sendable {
    public let maxDepth: Int
    public let maxNodes: Int

    public init(maxDepth: Int = 30, maxNodes: Int = 800) {
        self.maxDepth = maxDepth
        self.maxNodes = maxNodes
    }

    /// Walk the AX tree from an application element, returning the root nodes and a flat element map.
    /// Includes the menu bar and the key window.
    public func walk(appElement: AXUIElement) -> (roots: [AXTreeNode], elementMap: [Int: AXUIElement]) {
        var counter = 0
        var elementMap: [Int: AXUIElement] = [:]
        var roots: [AXTreeNode] = []

        // Include the menu bar
        if let menuBar: AXUIElement = appElement.attribute(kAXMenuBarAttribute) {
            if let node = buildNode(element: menuBar, depth: 0, counter: &counter, elementMap: &elementMap) {
                roots.append(node)
            }
        }

        // Walk windows — only the first AXWindow (key window) to avoid duplicates
        let windows: [AXUIElement] = appElement.children
        let keyWindow = windows.first { $0.role == "AXWindow" }
        if let window = keyWindow {
            if let node = buildNode(element: window, depth: 0, counter: &counter, elementMap: &elementMap) {
                roots.append(node)
            }
        }

        return (roots, elementMap)
    }

    private func buildNode(
        element: AXUIElement,
        depth: Int,
        counter: inout Int,
        elementMap: inout [Int: AXUIElement],
        parentRole: String? = nil,
        skipOffscreenCheck: Bool = false
    ) -> AXTreeNode? {
        guard depth < maxDepth, counter < maxNodes else { return nil }
        guard let role = element.role else { return nil }

        // Skip elements that add noise without value
        if shouldSkip(role: role, element: element) { return nil }

        // Skip offscreen elements — but NOT when:
        // 1. depth == 0 (top-level windows)
        // 2. skipOffscreenCheck is true (parent window is on another Space)
        let windowOnOtherSpace: Bool
        if !skipOffscreenCheck && depth > 0, let frame = element.frame, isOffscreen(frame: frame) {
            return nil
        }
        // Detect if this window is on another Space (negative y or far off)
        if role == "AXWindow", let frame = element.frame, isOffscreen(frame: frame) {
            windowOnOtherSpace = true
        } else {
            windowOnOtherSpace = false
        }

        let index = counter
        counter += 1
        elementMap[index] = element

        // Build children (with limit on children per parent to avoid explosion)
        var childNodes: [AXTreeNode] = []
        let childElements = element.children

        // Limit visible children for list-like containers
        let maxChildren = isListContainer(role: role) ? 30 : childElements.count
        let visibleChildren = Array(childElements.prefix(maxChildren))

        // Check if this AXRow already has a TextField child (used for smart filtering)
        let rowHasTextField = (role == "AXRow") && visibleChildren.contains { $0.role == "AXTextField" }

        for child in visibleChildren {
            guard counter < maxNodes else { break }

            // Skip AXStaticText children inside AXRow when the Row has a TextField child
            if role == "AXRow" && rowHasTextField && child.role == "AXStaticText" {
                continue
            }

            if let childNode = buildNode(element: child, depth: depth + 1, counter: &counter, elementMap: &elementMap, parentRole: role, skipOffscreenCheck: skipOffscreenCheck || windowOnOtherSpace) {
                childNodes.append(childNode)
            }
        }

        // Deeper Group collapsing: collapse Group > Group > Group chains where intermediate
        // Groups have no title/value and only 1 child
        if role == "AXGroup" && element.title == nil && element.axValue == nil && childNodes.count == 1 {
            let child = childNodes[0]
            if child.role == "container" && child.title == nil && child.value == nil && child.children.count == 1 {
                return child.children[0]
            }
        }

        // If this is a "pass-through" container with no useful info, collapse it
        if shouldCollapse(role: role, element: element, children: childNodes) {
            if childNodes.count == 1 {
                return childNodes[0]
            }
            if childNodes.isEmpty {
                return nil  // Drop empty containers
            }
        }

        // Get roleDescription for display (localized role name)
        let roleDesc = element.roleDescription

        // Get URL for links and web areas
        let url: String? = {
            let linkRoles: Set<String> = ["AXLink", "AXWebArea"]
            if linkRoles.contains(role) {
                if let rawURL = element.axURL {
                    return truncateURL(rawURL)
                }
            }
            return nil
        }()

        // Check if value is settable (for text fields)
        let isSettable: Bool = {
            let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
            if textRoles.contains(role) {
                return element.isValueSettable
            }
            return false
        }()

        // Get description when it adds info beyond title
        let desc: String? = {
            let d = element.axDescription
            if let d = d, !d.isEmpty {
                // Skip if same as title
                if let t = element.title, t == d { return nil }
                return truncateLabel(d)
            }
            return nil
        }()

        // Detect dialog/modal elements
        let modalSubroles: Set<String> = ["AXDialog", "AXSheet", "AXFloatingWindow", "AXSystemDialog"]
        let isModal = element.subrole.map { modalSubroles.contains($0) } ?? false

        // Build title
        let nodeTitle: String? = {
            let base = bestLabel(element)
            if isModal {
                let tag = (element.subrole == "AXSheet") ? "[modal]" : "[dialog]"
                if let base = base { return "\(tag) \(base)" }
                return tag
            }
            return base
        }()

        // Only keep AXRaise as a secondary action; drop all other actions from display
        let actions = element.actionNames.filter { $0 == "AXRaise" }

        return AXTreeNode(
            index: index,
            role: simplifyRole(role),
            subrole: element.subrole,
            title: nodeTitle,
            value: truncateValue(element.axValue),
            axDescription: desc,
            roleDescription: roleDesc,
            url: url,
            isSettable: isSettable,
            frame: element.frame,
            isEnabled: element.isEnabled,
            isFocused: element.isFocused,
            isModal: isModal,
            actions: actions,
            children: childNodes
        )
    }

    // MARK: - Filtering

    /// Roles to skip entirely — decorative/layout elements
    private func shouldSkip(role: String, element: AXUIElement) -> Bool {
        let skipRoles: Set<String> = [
            "AXUnknown",
            "AXSplitter",       // Resize handles
            "AXGrowArea",       // Resize corner
            "AXMatte",          // Background matte
            "AXRuler",          // Ruler
            "AXRulerMarker",    // Ruler marker
            "AXValueIndicator", // Slider knob (slider itself is kept)
            "AXIncrementArrow", // Stepper arrows
            "AXDecrementArrow",
            "AXColumn",         // Column headers (captured via buttons)
            "AXScrollBar",      // Scroll bars
        ]

        if skipRoles.contains(role) { return true }

        // Skip disabled buttons with no title (decorative)
        if role == "AXButton" && element.title == nil && !element.isEnabled {
            return true
        }

        return false
    }

    /// Check if a frame is offscreen (likely scrolled out of view)
    private func isOffscreen(frame: CGRect) -> Bool {
        if frame.width <= 0 || frame.height <= 0 { return true }

        let totalBounds: CGRect = {
            let screens = NSScreen.screens
            guard !screens.isEmpty else {
                return CGRect(x: -10000, y: -10000, width: 30000, height: 30000)
            }
            return screens.reduce(CGRect.null) { $0.union($1.frame) }
        }()

        if !frame.intersects(totalBounds) { return true }
        return false
    }

    /// List containers that may have hundreds of items
    private func isListContainer(role: String) -> Bool {
        let listRoles: Set<String> = [
            "AXOutline", "AXTable", "AXList", "AXBrowser",
            "AXGrid",
        ]
        return listRoles.contains(role)
    }

    /// "Pass-through" containers that just wrap children without adding info
    private func shouldCollapse(role: String, element: AXUIElement, children: [AXTreeNode]) -> Bool {
        if children.isEmpty && element.axValue == nil && element.actionNames.isEmpty {
            let alwaysCollapseIfEmpty: Set<String> = [
                "AXCell", "AXGroup", "AXLayoutArea", "AXLayoutItem",
                "AXSplitGroup", "AXRow",
            ]
            if alwaysCollapseIfEmpty.contains(role) { return true }
        }

        let collapsibleRoles: Set<String> = [
            "AXCell",
            "AXLayoutArea",
            "AXLayoutItem",
        ]

        if collapsibleRoles.contains(role)
            && element.title == nil
            && element.axValue == nil
            && children.count == 1 {
            return true
        }

        // Collapse single-child Groups that are just layout wrappers (no title, no value)
        if role == "AXGroup"
            && element.title == nil
            && element.axValue == nil
            && children.count <= 1 {
            return true
        }

        // Collapse AXRow containing a single child AXRow
        if role == "AXRow" && children.count == 1 && children[0].role == "Row" {
            return true
        }

        return false
    }

    /// Simplify role names for LLM readability
    private func simplifyRole(_ role: String) -> String {
        // Remove "AX" prefix for cleaner output
        if role.hasPrefix("AX") {
            return String(role.dropFirst(2))
        }
        return role
    }

    /// Pick the best human-readable label, truncated for readability
    private func bestLabel(_ element: AXUIElement) -> String? {
        var label: String?
        if let title = element.title, !title.isEmpty { label = title }
        else if let desc = element.axDescription, !desc.isEmpty { label = desc }

        guard var text = label else { return nil }
        text = truncateLabel(text)
        // Strip newlines
        text = text.replacingOccurrences(of: "\n", with: " ")
        return text
    }

    /// Truncate labels for readability
    private func truncateLabel(_ text: String) -> String {
        if text.count > 60 {
            return String(text.prefix(57)) + "..."
        }
        return text
    }

    /// Truncate values that are too long
    private func truncateValue(_ value: String?) -> String? {
        guard let v = value, !v.isEmpty else { return nil }
        if v.count > 80 {
            return String(v.prefix(80)) + "..."
        }
        return v
    }

    /// Truncate URLs to a reasonable display length
    private func truncateURL(_ url: String) -> String {
        if url.count > 60 {
            return String(url.prefix(57)) + "…"
        }
        return url
    }
}
