import ApplicationServices
import CoreGraphics

public enum AXError: Error, Sendable {
    case apiDisabled
    case invalidElement
    case attributeUnsupported(String)
    case actionUnsupported(String)
    case notificationUnsupported
    case cannotComplete
    case failure(Int32)

    init(code: ApplicationServices.AXError) {
        switch code {
        case .apiDisabled: self = .apiDisabled
        case .invalidUIElement: self = .invalidElement
        case .attributeUnsupported: self = .attributeUnsupported("")
        case .actionUnsupported: self = .actionUnsupported("")
        case .notificationUnsupported: self = .notificationUnsupported
        case .cannotComplete: self = .cannotComplete
        default: self = .failure(code.rawValue)
        }
    }
}

public extension AXUIElement {

    func attribute<T>(_ name: String) -> T? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(self, name as CFString, &value)
        guard result == .success else { return nil }
        return value as? T
    }

    func stringAttribute(_ name: String) -> String? {
        attribute(name) as String?
    }

    func boolAttribute(_ name: String) -> Bool? {
        guard let value: AnyObject = attribute(name) else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    func intAttribute(_ name: String) -> Int? {
        guard let value: AnyObject = attribute(name) else { return nil }
        return (value as? NSNumber)?.intValue
    }

    func frameAttribute() -> CGRect? {
        var posValue: AnyObject?
        var sizeValue: AnyObject?

        guard AXUIElementCopyAttributeValue(self, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(self, kAXSizeAttribute as CFString, &sizeValue) == .success
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero

        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }

        return CGRect(origin: position, size: size)
    }

    var role: String? { stringAttribute(kAXRoleAttribute) }
    var subrole: String? { stringAttribute(kAXSubroleAttribute) }
    var title: String? { stringAttribute(kAXTitleAttribute) }
    var axDescription: String? { stringAttribute(kAXDescriptionAttribute) }
    var axValue: String? {
        let val: AnyObject? = attribute(kAXValueAttribute)
        if let s = val as? String { return s }
        if let n = val as? NSNumber { return n.stringValue }
        return nil
    }
    var roleDescription: String? { stringAttribute(kAXRoleDescriptionAttribute) }
    var isEnabled: Bool { boolAttribute(kAXEnabledAttribute) ?? true }
    var isFocused: Bool { boolAttribute(kAXFocusedAttribute) ?? false }
    var frame: CGRect? { frameAttribute() }

    /// Get the URL attribute (used for links, web areas, etc.)
    var axURL: String? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(self, "AXURL" as CFString, &value)
        guard result == .success else { return nil }
        if let url = value as? URL {
            return url.absoluteString
        }
        if let cfURL = value as! CFURL? {
            return CFURLGetString(cfURL) as String
        }
        return nil
    }

    /// Check if the value attribute is settable
    var isValueSettable: Bool {
        var settable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(self, kAXValueAttribute as CFString, &settable)
        return result == .success && settable.boolValue
    }

    var children: [AXUIElement] {
        attribute(kAXChildrenAttribute) ?? []
    }

    var parent: AXUIElement? {
        attribute(kAXParentAttribute)
    }

    var actionNames: [String] {
        var names: CFArray?
        AXUIElementCopyActionNames(self, &names)
        return (names as? [String]) ?? []
    }

    func performAction(_ action: String) throws {
        let result = AXUIElementPerformAction(self, action as CFString)
        guard result == .success else {
            throw AXError(code: result)
        }
    }

    func setValue(_ value: CFTypeRef) throws {
        let result = AXUIElementSetAttributeValue(self, kAXValueAttribute as CFString, value)
        guard result == .success else {
            throw AXError(code: result)
        }
    }

    func setAttributeValue(_ attr: String, _ value: CFTypeRef) throws {
        let result = AXUIElementSetAttributeValue(self, attr as CFString, value)
        guard result == .success else {
            throw AXError(code: result)
        }
    }

    func elementAtPosition(_ point: CGPoint) -> AXUIElement? {
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(self, Float(point.x), Float(point.y), &element)
        guard result == .success else { return nil }
        return element
    }

    var pid: pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(self, &pid)
        return pid
    }

    static func applicationElement(pid: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }

    static func systemWide() -> AXUIElement {
        AXUIElementCreateSystemWide()
    }
}
