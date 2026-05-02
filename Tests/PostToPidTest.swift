import CoreGraphics
import Foundation

// Test: does moving cursor first make postToPid double-click work on Electron?
// Usage: swift Tests/PostToPidTest.swift <pid> <x> <y>

let args = CommandLine.arguments
guard args.count == 4,
      let pid = Int32(args[1]),
      let x = Double(args[2]),
      let y = Double(args[3]) else {
    print("Usage: PostToPidTest <pid> <x> <y>")
    exit(1)
}

let point = CGPoint(x: x, y: y)

print("Target: pid=\(pid), point=\(point)")
print("")

// Strategy A: Move cursor to position first, then postToPid
print("Strategy: moveCursor(global) + postToPid double-click")

// Step 1: Move cursor to target position (global HID event)
if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
    moveEvent.post(tap: .cghidEventTap)
    print("  Cursor moved to \(point)")
}
Thread.sleep(forTimeInterval: 0.05)

// Step 2: Double-click via postToPid
for i: Int64 in 1...2 {
    guard let downEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) else { continue }
    downEvent.setIntegerValueField(.mouseEventClickState, value: i)
    downEvent.postToPid(pid)

    Thread.sleep(forTimeInterval: 0.05)

    guard let upEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { continue }
    upEvent.setIntegerValueField(.mouseEventClickState, value: i)
    upEvent.postToPid(pid)

    print("  Click \(i) sent")

    if i < 2 {
        Thread.sleep(forTimeInterval: 0.02) // Short delay between clicks
    }
}

print("Done!")
