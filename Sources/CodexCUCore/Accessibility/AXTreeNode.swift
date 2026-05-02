import CoreGraphics

public struct AXTreeNode: Sendable {
    public let index: Int
    public let role: String
    public let subrole: String?
    public let title: String?
    public let value: String?
    public let axDescription: String?
    public let roleDescription: String?
    public let url: String?
    public let isSettable: Bool
    public let frame: CGRect?
    public let isEnabled: Bool
    public let isFocused: Bool
    public let isModal: Bool
    public let actions: [String]
    public let children: [AXTreeNode]

    public init(
        index: Int, role: String, subrole: String? = nil, title: String? = nil,
        value: String? = nil, axDescription: String? = nil, roleDescription: String? = nil,
        url: String? = nil, isSettable: Bool = false,
        frame: CGRect? = nil, isEnabled: Bool = true, isFocused: Bool = false,
        isModal: Bool = false,
        actions: [String] = [], children: [AXTreeNode] = []
    ) {
        self.index = index
        self.role = role
        self.subrole = subrole
        self.title = title
        self.value = value
        self.axDescription = axDescription
        self.roleDescription = roleDescription
        self.url = url
        self.isSettable = isSettable
        self.frame = frame
        self.isEnabled = isEnabled
        self.isFocused = isFocused
        self.isModal = isModal
        self.actions = actions
        self.children = children
    }

    /// Label for LLM consumption: picks the best human-readable text
    public var label: String? {
        title ?? axDescription ?? roleDescription
    }

    /// Display role: prefer roleDescription (localized), fall back to simplified role
    public var displayRole: String {
        if let rd = roleDescription, !rd.isEmpty {
            return rd
        }
        return role
    }

    /// Compact one-line description for tree output (Codex format)
    public var shortDescription: String {
        // Format: index displayRole (settable, string) title, Description: desc, URL: url, Value: value, Secondary Actions: Raise
        var parts: [String] = []

        // Role with settable marker for text fields
        var roleStr = displayRole
        if isSettable {
            roleStr += " (settable, string)"
        }
        parts.append("\(index) \(roleStr)")

        // Title/label inline (not quoted)
        if let t = title, !t.isEmpty {
            parts.append(t)
        }

        // Trailing metadata
        var meta: [String] = []
        if let desc = axDescription, !desc.isEmpty, desc != title {
            meta.append("Description: \(desc)")
        }
        if let u = url, !u.isEmpty {
            meta.append("URL: \(u)")
        }
        if let v = value, !v.isEmpty, v != title {
            meta.append("Value: \(v)")
        }
        if !isEnabled {
            meta.append("disabled")
        }
        // Only show "Secondary Actions: Raise" for windows that have AXRaise
        if actions.contains("AXRaise") {
            meta.append("Secondary Actions: Raise")
        }

        if !meta.isEmpty {
            parts.append(meta.joined(separator: ", "))
        }

        return parts.joined(separator: " ")
    }

    /// Recursive text representation with indentation (4-space indent like Codex)
    public func textRepresentation(indent: Int = 0) -> String {
        let prefix = String(repeating: "    ", count: indent)
        var lines = [prefix + shortDescription]
        for child in children {
            lines.append(child.textRepresentation(indent: indent + 1))
        }
        return lines.joined(separator: "\n")
    }

    /// Total count of this node plus all descendants
    public var totalNodeCount: Int {
        1 + children.reduce(0) { $0 + $1.totalNodeCount }
    }
}

extension AXTreeNode {
    /// Flatten tree into array ordered by index
    public func flatten() -> [AXTreeNode] {
        var result = [self]
        for child in children {
            result.append(contentsOf: child.flatten())
        }
        return result
    }
}
