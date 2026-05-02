import CoreGraphics
import AppKit
import Foundation

public enum MouseButton: String, Sendable {
    case left, right, middle
}

public enum ScrollDirection: String, Sendable {
    case up, down, left, right
}

public struct MouseController: Sendable {
    public init() {}

    /// Click at a screen coordinate, delivering events directly to the target process
    public func click(at point: CGPoint, button: MouseButton = .left, clickCount: Int = 1, targetPID: pid_t? = nil) throws {
        let (downType, upType, cgButton) = eventTypes(for: button, clickCount: clickCount)

        for i in 1...clickCount {
            guard let downEvent = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: point, mouseButton: cgButton) else {
                throw InputError.eventCreationFailed
            }
            downEvent.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            postEvent(downEvent, to: targetPID)

            Thread.sleep(forTimeInterval: 0.05)

            guard let upEvent = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: point, mouseButton: cgButton) else {
                throw InputError.eventCreationFailed
            }
            upEvent.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            postEvent(upEvent, to: targetPID)
        }

        Thread.sleep(forTimeInterval: 0.1)
    }

    /// Scroll at a point, delivering events directly to the target process
    public func scroll(at point: CGPoint, direction: ScrollDirection, pages: Double = 1.0, targetPID: pid_t? = nil) throws {
        // Move cursor to position first (global, needed for scroll targeting)
        try moveCursor(to: point)

        let scrollUnits = Int32(pages * 10)

        let (deltaY, deltaX): (Int32, Int32) = switch direction {
        case .up: (-scrollUnits, 0)
        case .down: (scrollUnits, 0)
        case .left: (0, -scrollUnits)
        case .right: (0, scrollUnits)
        }

        guard let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: deltaY, wheel2: deltaX, wheel3: 0) else {
            throw InputError.eventCreationFailed
        }
        postEvent(scrollEvent, to: targetPID)
    }

    /// Drag from one point to another, delivering events directly to the target process
    public func drag(from start: CGPoint, to end: CGPoint, button: MouseButton = .left, targetPID: pid_t? = nil) throws {
        let (downType, upType, cgButton) = eventTypes(for: button, clickCount: 1)
        let dragType: CGEventType = button == .left ? .leftMouseDragged : .rightMouseDragged

        // Mouse down at start
        guard let downEvent = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: start, mouseButton: cgButton) else {
            throw InputError.eventCreationFailed
        }
        postEvent(downEvent, to: targetPID)

        // Interpolate drag path
        let steps = 20
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let x = start.x + (end.x - start.x) * t
            let y = start.y + (end.y - start.y) * t
            let pt = CGPoint(x: x, y: y)

            guard let dragEvent = CGEvent(mouseEventSource: nil, mouseType: dragType, mouseCursorPosition: pt, mouseButton: cgButton) else {
                continue
            }
            postEvent(dragEvent, to: targetPID)
            Thread.sleep(forTimeInterval: 0.01)
        }

        // Mouse up at end
        guard let upEvent = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: end, mouseButton: cgButton) else {
            throw InputError.eventCreationFailed
        }
        postEvent(upEvent, to: targetPID)
    }

    /// Send a single mouseDown+mouseUp via NSEvent with windowNumber, posted to HID.
    /// The NSEvent carries windowNumber (CGEvent field 51), making it a trusted event
    /// that Chromium/Electron accepts. `clickState` should be 1 for first click, 2 for
    /// the second click of a double-click, etc.
    public func singleClickHID(at point: CGPoint, button: MouseButton = .left, clickState: Int, windowNumber: Int) throws {
        let (downType, upType, _) = eventTypes(for: button, clickCount: clickState)
        let nsDownType: NSEvent.EventType = switch downType {
        case .leftMouseDown: .leftMouseDown
        case .rightMouseDown: .rightMouseDown
        default: .otherMouseDown
        }
        let nsUpType: NSEvent.EventType = switch upType {
        case .leftMouseUp: .leftMouseUp
        case .rightMouseUp: .rightMouseUp
        default: .otherMouseUp
        }

        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let nsDown = NSEvent.mouseEvent(
            with: nsDownType, location: point, modifierFlags: [],
            timestamp: timestamp, windowNumber: windowNumber, context: nil,
            eventNumber: 0, clickCount: clickState, pressure: 1.0
        ), let cgDown = nsDown.cgEvent else {
            throw InputError.eventCreationFailed
        }
        cgDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.03)

        guard let nsUp = NSEvent.mouseEvent(
            with: nsUpType, location: point, modifierFlags: [],
            timestamp: timestamp + 0.02, windowNumber: windowNumber, context: nil,
            eventNumber: 0, clickCount: clickState, pressure: 0.0
        ), let cgUp = nsUp.cgEvent else {
            throw InputError.eventCreationFailed
        }
        cgUp.post(tap: .cghidEventTap)
    }

    /// Move cursor to a position without clicking (always global)
    public func moveCursor(to point: CGPoint) throws {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
            throw InputError.eventCreationFailed
        }
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Private

    /// Post an event either to a specific process or globally
    private func postEvent(_ event: CGEvent, to pid: pid_t?) {
        if let pid = pid {
            event.postToPid(pid)
        } else {
            event.post(tap: .cghidEventTap)
        }
    }

    private func eventTypes(for button: MouseButton, clickCount: Int) -> (down: CGEventType, up: CGEventType, button: CGMouseButton) {
        switch button {
        case .left:
            return (.leftMouseDown, .leftMouseUp, .left)
        case .right:
            return (.rightMouseDown, .rightMouseUp, .right)
        case .middle:
            return (.otherMouseDown, .otherMouseUp, .center)
        }
    }
}
