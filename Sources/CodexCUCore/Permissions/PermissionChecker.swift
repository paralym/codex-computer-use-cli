import AppKit
import ScreenCaptureKit

public enum PermissionStatus: String, Sendable {
    case granted
    case denied
    case unknown
}

public struct PermissionChecker: Sendable {
    public init() {}

    public func accessibilityStatus() -> PermissionStatus {
        AXIsProcessTrusted() ? .granted : .denied
    }

    public func screenRecordingStatus() -> PermissionStatus {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    public func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public func requestAccessibility() {
        // Work around Swift 6 strict concurrency for C global
        let prompt: CFString = "AXTrustedCheckOptionPrompt" as CFString
        let options = [prompt: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    public func allGranted() -> Bool {
        accessibilityStatus() == .granted && screenRecordingStatus() == .granted
    }

    public func printStatus() {
        let ax = accessibilityStatus()
        let sr = screenRecordingStatus()
        print("Permission Status:")
        print("  Accessibility:    \(ax.rawValue) \(ax == .granted ? "[OK]" : "[REQUIRED]")")
        print("  Screen Recording: \(sr.rawValue) \(sr == .granted ? "[OK]" : "[REQUIRED]")")

        if ax == .denied {
            print("")
            print("To grant Accessibility permission:")
            print("  System Settings > Privacy & Security > Accessibility")
            print("  Add this terminal app or codex-cu to the list")
        }
        if sr == .denied {
            print("")
            print("To grant Screen Recording permission:")
            print("  System Settings > Privacy & Security > Screen Recording")
            print("  Add this terminal app or codex-cu to the list")
        }
    }
}
