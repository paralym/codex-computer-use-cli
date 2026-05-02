import AppKit
import Foundation

/// Initialize the CGS connection. Must be called before any CoreGraphics/ScreenCaptureKit use.
/// Safe to call multiple times.
public func ensureCGSInitialized() {
    // NSApplication.shared triggers CGSDefaultConnection initialization
    // This must happen on the main thread
    if Thread.isMainThread {
        _ = NSApplication.shared
    } else {
        DispatchQueue.main.sync {
            _ = NSApplication.shared
        }
    }
}

private final class RunLoopBox: @unchecked Sendable {
    var result: Any?
    var error: Error?
}

/// Runs an async closure in a blocking manner, allowing ScreenCaptureKit and other async APIs to work.
public func withRunLoop<T: Sendable>(_ body: @Sendable @escaping () async throws -> T) throws -> T {
    ensureCGSInitialized()

    let box = RunLoopBox()
    let semaphore = DispatchSemaphore(value: 0)

    // Run on a background queue (not main thread) to avoid blocking the main RunLoop
    DispatchQueue.global(qos: .userInitiated).async {
        let task = Task {
            try await body()
        }
        Task {
            do {
                box.result = try await task.value
            } catch {
                box.error = error
            }
            semaphore.signal()
        }
    }

    // Wait for completion
    semaphore.wait()

    if let error = box.error { throw error }
    return box.result as! T
}
