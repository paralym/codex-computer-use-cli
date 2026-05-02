import AppKit

public struct AppInfo: Codable, Sendable {
    public let name: String
    public let bundleIdentifier: String?
    public let pid: Int32
    public let isActive: Bool
    public let isHidden: Bool

    public init(name: String, bundleIdentifier: String?, pid: Int32, isActive: Bool, isHidden: Bool) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.pid = pid
        self.isActive = isActive
        self.isHidden = isHidden
    }
}

public enum AppManagerError: Error, Sendable {
    case appNotFound(String)
    case launchFailed(String)
}

public struct AppManager: Sendable {
    public init() {}

    @MainActor
    public func listRunningApps() -> [AppInfo] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> AppInfo? in
                guard let name = app.localizedName else { return nil }
                return AppInfo(
                    name: name,
                    bundleIdentifier: app.bundleIdentifier,
                    pid: app.processIdentifier,
                    isActive: app.isActive,
                    isHidden: app.isHidden
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @MainActor
    public func findApp(named name: String) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }

        // Exact name match
        if let app = apps.first(where: { $0.localizedName?.lowercased() == name.lowercased() }) {
            return app
        }

        // Bundle identifier match
        if let app = apps.first(where: { $0.bundleIdentifier?.lowercased() == name.lowercased() }) {
            return app
        }

        // Prefix match
        if let app = apps.first(where: { $0.localizedName?.lowercased().hasPrefix(name.lowercased()) == true }) {
            return app
        }

        return nil
    }

    @MainActor
    public func launchApp(named name: String) throws -> NSRunningApplication {
        let workspace = NSWorkspace.shared

        // If it looks like a bundle ID (contains dots), try opening by bundle ID
        if name.contains(".") {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-b", name]
            try process.run()
            process.waitUntilExit()
        } else {
            // Try opening by application name
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", name]
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                throw AppManagerError.launchFailed("'open -a \(name)' failed with exit code \(process.terminationStatus)")
            }
        }

        // Poll for the app to appear in running apps (up to 3 seconds)
        let lowerName = name.lowercased()
        for _ in 0..<30 {
            Thread.sleep(forTimeInterval: 0.1)
            let apps = workspace.runningApplications.filter { $0.activationPolicy == .regular }
            if let app = apps.first(where: {
                $0.bundleIdentifier?.lowercased() == lowerName ||
                $0.localizedName?.lowercased() == lowerName ||
                $0.localizedName?.lowercased().hasPrefix(lowerName) == true ||
                // Match English app names to localized names (e.g., "TextEdit" -> "文本编辑器")
                $0.bundleIdentifier?.lowercased().hasSuffix(".\(lowerName)") == true
            }) {
                return app
            }
        }

        // Last resort: return the most recently launched app
        if let newest = workspace.runningApplications
            .filter({ $0.activationPolicy == .regular && $0.isActive })
            .first {
            return newest
        }

        throw AppManagerError.launchFailed(name)
    }

    @MainActor
    public func activateApp(named name: String) throws -> NSRunningApplication {
        guard let app = findApp(named: name) else {
            throw AppManagerError.appNotFound(name)
        }
        app.activate()
        return app
    }

    @MainActor
    public func getWindowNumber(for app: NSRunningApplication) -> CGWindowID? {
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

        let appWindows = windowList.filter { info in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int32 else { return false }
            return ownerPID == app.processIdentifier
        }

        // Return the first on-screen window (typically the key window)
        return appWindows.first?[kCGWindowNumber as String] as? CGWindowID
    }
}
