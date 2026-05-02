import ArgumentParser
import CodexCUCore
import AppKit
import Foundation

// Initialize NSApplication on the main thread before anything else
// Required for ScreenCaptureKit and other AppKit/CoreGraphics APIs
private enum AppBootstrap {
    @MainActor static func ensureInitialized() {
        _ = NSApplication.shared
    }
}

@main
struct CodexCU: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "codex-cu",
        abstract: "Computer Use CLI — control macOS apps via Accessibility + ScreenCaptureKit",
        subcommands: [
            Permissions.self,
            ListApps.self,
            Launch.self,
            Activate.self,
            Screenshot.self,
            Click.self,
            Type.self,
            Key.self,
            Scroll.self,
            Drag.self,
            SetValue.self,
            CursorDemo.self,
        ]
    )
}

// MARK: - permissions

struct Permissions: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check and request required permissions"
    )

    @Flag(name: .long, help: "Request permissions interactively")
    var request = false

    func run() {
        let checker = PermissionChecker()
        checker.printStatus()

        if request {
            print("\nRequesting permissions...")
            if checker.accessibilityStatus() == .denied {
                checker.requestAccessibility()
                print("  Accessibility: system dialog shown")
            }
            if checker.screenRecordingStatus() == .denied {
                _ = checker.requestScreenRecording()
                print("  Screen Recording: system dialog shown")
            }
        }

        if checker.allGranted() {
            print("\nAll permissions granted. Ready to use.")
        }
    }
}

// MARK: - list-apps

struct ListApps: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-apps",
        abstract: "List running applications"
    )

    func run() async {
        let router = ToolRouter()
        let result = await router.listApps()
        printResult(result)
    }
}

// MARK: - launch

struct Launch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "launch",
        abstract: "Launch an application by name or bundle identifier"
    )

    @Argument(help: "App name or bundle identifier")
    var appName: String

    func run() async {
        guard ensurePermissions() else { return }
        let router = ToolRouter()
        let result = await router.launchApp(name: appName)
        printResult(result)
    }
}

// MARK: - activate

struct Activate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "activate",
        abstract: "Bring a running application to the foreground"
    )

    @Argument(help: "App name or bundle identifier")
    var appName: String

    func run() async {
        guard ensurePermissions() else { return }
        let router = ToolRouter()
        let result = await router.activateApp(name: appName)
        printResult(result)
    }
}

// MARK: - screenshot

struct Screenshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Capture screenshot and AX tree of an app"
    )

    @Argument(help: "App name or bundle identifier")
    var appName: String

    @Option(name: .long, help: "Output file path")
    var output: String?

    func run() async {
        guard ensurePermissions() else { return }

        let router = ToolRouter()
        let result = await router.getAppState(appName: appName)

        for item in result.content {
            switch item {
            case .text(let text):
                print(text)
            case .image(let base64, _):
                if let outputPath = output, let data = Data(base64Encoded: base64) {
                    let url = URL(fileURLWithPath: outputPath)
                    try? data.write(to: url)
                    print("\nScreenshot saved to: \(outputPath)")
                } else {
                    print("\n[Screenshot captured: \(base64.count) bytes base64]")
                    print("Use --output <path> to save the screenshot")
                }
            }
        }
    }
}

// MARK: - click

struct Click: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Click an element by index or coordinates"
    )

    @Argument(help: "App name (required for first call to build element index)")
    var appName: String

    @Argument(help: "Element index from AX tree, or 'x,y' coordinates")
    var target: String

    @Option(name: .long, help: "Mouse button: left, right, middle")
    var button: String = "left"

    @Option(name: .long, help: "Click count (1=single, 2=double, 3=triple)")
    var count: Int = 1

    @Flag(name: .long, help: "Activate app to foreground before clicking (use for frontmost-app interactions)")
    var foreground: Bool = false

    func run() async {
        guard ensurePermissions() else { return }

        let router = ToolRouter()

        if foreground {
            // Foreground mode: activate app, then direct HID click (no overlay/SLPS)
            _ = await router.activateApp(name: appName)
            try? await Task.sleep(for: .milliseconds(300))

            let elementTarget = parseTarget(target)
            let mouseButton = MouseButton(rawValue: button) ?? .left
            let result = await router.clickDirect(target: elementTarget, button: mouseButton, clickCount: count)
            printResult(result)
        } else {
            // Background mode: synthetic focus with overlay
            _ = await router.getAppState(appName: appName)
            let elementTarget = parseTarget(target)
            let mouseButton = MouseButton(rawValue: button) ?? .left
            let result = await router.click(target: elementTarget, button: mouseButton, clickCount: count)
            printResult(result)
        }
    }
}

// MARK: - type

struct Type: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "Type text into an app's focused element"
    )

    @Argument(help: "App name to type into")
    var appName: String

    @Argument(help: "Text to type")
    var text: String

    func run() async {
        guard ensurePermissions() else { return }
        let router = ToolRouter()
        // Set up target app so postToPid sends events to the correct process
        _ = await router.getAppState(appName: appName)
        let result = await router.typeText(text)
        printResult(result)
    }
}

// MARK: - key

struct Key: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Press a key combination (xdotool syntax)"
    )

    @Argument(help: "App name to send key to")
    var appName: String

    @Argument(help: "Key spec, e.g. 'super+c', 'Return', 'ctrl+shift+a'")
    var keySpec: String

    func run() async {
        guard ensurePermissions() else { return }
        let router = ToolRouter()
        // Set up target app so postToPid sends events to the correct process
        _ = await router.getAppState(appName: appName)
        let result = await router.pressKey(keySpec)
        printResult(result)
    }
}

// MARK: - scroll

struct Scroll: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Scroll at a position"
    )

    @Argument(help: "App name")
    var appName: String

    @Argument(help: "Element index or 'x,y' coordinates")
    var target: String

    @Argument(help: "Direction: up, down, left, right")
    var direction: String

    @Option(name: .long, help: "Number of pages to scroll")
    var pages: Double = 1.0

    func run() async {
        guard ensurePermissions() else { return }
        let router = ToolRouter()
        _ = await router.getAppState(appName: appName)

        let elementTarget = parseTarget(target)
        let dir = ScrollDirection(rawValue: direction) ?? .down
        let result = await router.scroll(target: elementTarget, direction: dir, pages: pages)
        printResult(result)
    }
}

// MARK: - drag

struct Drag: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Drag from one point to another"
    )

    @Argument(help: "App name")
    var appName: String

    @Argument(help: "Start coordinates 'x,y'")
    var from: String

    @Argument(help: "End coordinates 'x,y'")
    var to: String

    @Flag(name: .long, help: "Activate app to foreground before dragging")
    var foreground: Bool = false

    func run() async {
        guard ensurePermissions() else { return }
        let (sx, sy) = parseCoordinates(from)
        let (ex, ey) = parseCoordinates(to)
        let router = ToolRouter()

        if foreground {
            _ = await router.activateApp(name: appName)
            try? await Task.sleep(for: .milliseconds(300))
            let result = await router.dragDirect(startX: sx, startY: sy, endX: ex, endY: ey)
            printResult(result)
        } else {
            _ = await router.getAppState(appName: appName)
            let result = await router.drag(startX: sx, startY: sy, endX: ex, endY: ey)
            printResult(result)
        }
    }
}

// MARK: - set-value

struct SetValue: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-value",
        abstract: "Set the value of an element"
    )

    @Argument(help: "App name")
    var appName: String

    @Argument(help: "Element index")
    var index: Int

    @Argument(help: "Value to set")
    var value: String

    func run() async {
        guard ensurePermissions() else { return }
        let router = ToolRouter()
        _ = await router.getAppState(appName: appName)
        let result = await router.setValue(index: index, value: value)
        printResult(result)
    }
}

// MARK: - cursor-demo

struct CursorDemo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cursor-demo",
        abstract: "Demo the AI cursor S-curve motion animation"
    )

    @Option(name: .long, help: "Number of random waypoints (default: 5)")
    var points: Int = 5

    @Option(name: .long, help: "Arc size 0..1 (default: 0.35)")
    var arc: Double = 0.35

    @Option(name: .long, help: "Animation duration per segment in seconds (default: 0.4)")
    var duration: Double = 0.4

    func run() async {
        guard ensurePermissions() else { return }

        await MainActor.run {
            let motion = CursorMotion.shared
            motion.arcSize = CGFloat(arc)
            motion.duration = duration

            let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let margin: CGFloat = 100

            // Generate random waypoints within screen bounds
            var waypoints: [CGPoint] = []
            for _ in 0...points {
                let x = CGFloat.random(in: margin...(screen.width - margin))
                let y = CGFloat.random(in: margin...(screen.height - margin))
                waypoints.append(CGPoint(x: x, y: y))
            }

            // Show cursor at first point
            let cursor = ComputerUseCursor.shared
            cursor.show()
            cursor.moveTo(waypoints[0], animated: false)

            print("Cursor motion demo: \(points) waypoints, arc=\(arc), duration=\(duration)s")
            print("Press Ctrl+C to stop")

            // Animate through waypoints
            var delay: TimeInterval = 0.3
            for i in 1..<waypoints.count {
                let from = waypoints[i - 1]
                let to = waypoints[i]
                let segDelay = delay

                DispatchQueue.main.asyncAfter(deadline: .now() + segDelay) {
                    motion.animate(from: from, to: to) {
                        cursor.pulseClick()
                    }
                }
                delay += duration + 0.5
            }

            // Hide cursor after all animations
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 1.0) {
                cursor.hide()
            }
        }

        // Keep process alive for animation to complete
        let totalWait = duration * Double(points) + Double(points) * 0.5 + 2.0
        try? await Task.sleep(for: .seconds(totalWait))
        print("Demo complete")
    }
}

// MARK: - Helpers

@MainActor
func ensureReady() -> Bool {
    AppBootstrap.ensureInitialized()
    let checker = PermissionChecker()
    if !checker.allGranted() {
        checker.printStatus()
        print("\nPlease grant the required permissions first.")
        print("Run: codex-cu permissions --request")
        return false
    }
    return true
}

func ensurePermissions() -> Bool {
    let checker = PermissionChecker()
    if !checker.allGranted() {
        checker.printStatus()
        print("\nPlease grant the required permissions first.")
        print("Run: codex-cu permissions --request")
        return false
    }
    return true
}

func parseTarget(_ target: String) -> ElementTarget {
    if target.contains(",") {
        let parts = target.split(separator: ",")
        if parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) {
            return .coordinates(x: x, y: y)
        }
    }
    if let index = Int(target) {
        return .index(index)
    }
    return .coordinates(x: 0, y: 0)
}

func parseCoordinates(_ coord: String) -> (Double, Double) {
    let parts = coord.split(separator: ",")
    if parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) {
        return (x, y)
    }
    return (0, 0)
}

func printResult(_ result: ToolResult) {
    for item in result.content {
        switch item {
        case .text(let text):
            if result.isError {
                print("Error: \(text)")
            } else {
                print(text)
            }
        case .image:
            break // Don't print images to terminal
        }
    }
}
