import CoreGraphics
import ApplicationServices
import Foundation
import AppKit

// Comprehensive test of different double-click strategies for Electron apps
// Usage: swift Tests/DoubleClickTest.swift <pid> <x> <y> <strategy>
// Strategies:
//   1 = postToPid only
//   2 = moveCursor + postToPid
//   3 = cghidEventTap (global, cursor must be over target)
//   4 = CGEventSource + postToPid
//   5 = postToPid with CGWarpMouseCursorPosition
//   6 = Check AX actions on element at position

_ = NSApplication.shared

let args = CommandLine.arguments
guard args.count >= 4,
      let pid = Int32(args[1]),
      let x = Double(args[2]),
      let y = Double(args[3]) else {
    print("Usage: DoubleClickTest <pid> <x> <y> [strategy]")
    exit(1)
}

let strategy = args.count > 4 ? Int(args[4]) ?? 0 : 0
let point = CGPoint(x: x, y: y)

print("Target: pid=\(pid), point=\(point), strategy=\(strategy)")

// Enable AXEnhancedUserInterface
let appElement = AXUIElementCreateApplication(pid)
AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
print("AXEnhancedUserInterface enabled")

if strategy == 0 || strategy == 6 {
    // Check AX actions available at this position
    print("\n--- Strategy 6: Check AX element at position ---")
    var elementRef: AXUIElement?
    let result = AXUIElementCopyElementAtPosition(appElement, Float(x), Float(y), &elementRef)
    if result == .success, let element = elementRef {
        var actionsRef: CFArray?
        AXUIElementCopyActionNames(element, &actionsRef)
        let actions = actionsRef as? [String] ?? []
        print("  Element at (\(x), \(y)): actions = \(actions)")

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? "unknown"

        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
        let title = titleRef as? String ?? ""

        var valueRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
        let value = valueRef as? String ?? ""

        var descRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descRef)
        let desc = descRef as? String ?? ""

        print("  Role: \(role), Title: \(title), Value: \(value), Desc: \(desc)")

        // Try all possible actions
        for action in actions {
            print("  Trying action: \(action)...")
            let r = AXUIElementPerformAction(element, action as CFString)
            print("    Result: \(r == .success ? "SUCCESS" : "failed (\(r.rawValue))")")
        }

        // Check parent element too
        var parentRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentRef)
        if let parent = parentRef {
            let parentElement = parent as! AXUIElement
            var parentActionsRef: CFArray?
            AXUIElementCopyActionNames(parentElement, &parentActionsRef)
            let parentActions = parentActionsRef as? [String] ?? []

            var parentRoleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(parentElement, kAXRoleAttribute as CFString, &parentRoleRef)
            let parentRole = parentRoleRef as? String ?? "unknown"

            var parentValueRef: CFTypeRef?
            AXUIElementCopyAttributeValue(parentElement, kAXValueAttribute as CFString, &parentValueRef)
            let parentValue = parentValueRef as? String ?? ""

            print("  Parent: Role=\(parentRole), Value=\(parentValue), Actions=\(parentActions)")
        }
    } else {
        print("  No element found at position (result: \(result.rawValue))")
    }
}

if strategy == 0 || strategy == 5 {
    print("\n--- Strategy 5: CGWarpMouseCursorPosition + postToPid ---")
    // Warp cursor to position (bypasses event system)
    CGWarpMouseCursorPosition(point)
    Thread.sleep(forTimeInterval: 0.1)

    // Associate mouse and cursor position
    CGAssociateMouseAndMouseCursorPosition(1)
    Thread.sleep(forTimeInterval: 0.05)

    for i: Int64 in 1...2 {
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) else { continue }
        down.setIntegerValueField(.mouseEventClickState, value: i)
        down.postToPid(pid)
        Thread.sleep(forTimeInterval: 0.03)

        guard let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { continue }
        up.setIntegerValueField(.mouseEventClickState, value: i)
        up.postToPid(pid)

        if i < 2 { Thread.sleep(forTimeInterval: 0.02) }
    }
    print("  Sent double-click via CGWarp + postToPid")
}

if strategy == 4 {
    print("\n--- Strategy 4: CGEventSource + postToPid ---")
    let source = CGEventSource(stateID: .hidSystemState)

    for i: Int64 in 1...2 {
        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) else { continue }
        down.setIntegerValueField(.mouseEventClickState, value: i)
        down.postToPid(pid)
        Thread.sleep(forTimeInterval: 0.03)

        guard let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { continue }
        up.setIntegerValueField(.mouseEventClickState, value: i)
        up.postToPid(pid)

        if i < 2 { Thread.sleep(forTimeInterval: 0.02) }
    }
    print("  Sent double-click with CGEventSource")
}

Thread.sleep(forTimeInterval: 0.5)

// Check what's playing now
print("\nChecking current song...")
var windowRef: CFTypeRef?
AXUIElementCopyAttributeValue(appElement, "AXWindows" as CFString, &windowRef)
// Just report done - caller will check via screenshot
print("Done. Check with: swift run codex-cu screenshot '网易云音乐' | grep '标题.*Value: 3'")
