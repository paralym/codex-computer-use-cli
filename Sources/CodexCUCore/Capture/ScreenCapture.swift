import ScreenCaptureKit
import CoreGraphics
import AppKit

public enum CaptureError: Error, Sendable {
    case noContent
    case windowNotFound(String)
    case captureFailed(String)
    case encodingFailed
}

public struct ScreenCapture: Sendable {
    public init() {}

    /// Capture a screenshot of a specific window by PID
    public func captureWindow(pid: pid_t, windowTitle: String? = nil) async throws -> CGImage {
        // Include offscreen windows (minimized, other spaces) — we'll pick the best one
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let appWindows = content.windows.filter { $0.owningApplication?.processID == pid }

        guard let window = selectWindow(from: appWindows, title: windowTitle) else {
            throw CaptureError.windowNotFound("No on-screen window found for PID \(pid). The app may be minimized or hidden — try clicking on it first.")
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.scalesToFit = false
        config.showsCursor = false
        config.captureResolution = .best
        config.width = Int(window.frame.width) * 2  // Retina
        config.height = Int(window.frame.height) * 2

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private func selectWindow(from windows: [SCWindow], title: String?) -> SCWindow? {
        // Filter to real content windows (not menu bar items, tooltips, etc.)
        let realWindows = windows.filter { w in
            w.frame.width >= 200 && w.frame.height >= 200
            && (w.title != nil && !w.title!.isEmpty || w.frame.width >= 400)
        }

        // Try title match first
        if let title = title {
            if let match = realWindows.first(where: { $0.title == title }) {
                return match
            }
        }

        // Prefer on-screen windows, then fall back to off-screen (minimized)
        let onScreen = realWindows.filter { $0.isOnScreen }
        if let best = onScreen.sorted(by: { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }).first {
            return best
        }

        // Fall back to largest off-screen window
        return realWindows
            .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
            .first
    }
}

public extension CGImage {
    func pngData() -> Data? {
        let rep = NSBitmapImageRep(cgImage: self)
        return rep.representation(using: .png, properties: [:])
    }

    func base64PNG() -> String? {
        pngData()?.base64EncodedString()
    }

    func jpegData(quality: Double = 0.8) -> Data? {
        let rep = NSBitmapImageRep(cgImage: self)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    func base64JPEG(quality: Double = 0.8) -> String? {
        jpegData(quality: quality)?.base64EncodedString()
    }
}
