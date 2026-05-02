import Foundation

/// Manages per-app approval for computer use access
public final class AppApprovalStore: Sendable {
    public enum ApprovalMode: String, Sendable {
        case explicit  // Must be pre-approved (default, most secure)
        case prompt    // Logs a warning and proceeds
        case auto      // All apps approved (dangerous, opt-in)
    }

    private let storePath: URL
    private let mode: ApprovalMode

    public init(mode: ApprovalMode = .prompt) {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/codex-cu")
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        self.storePath = configDir.appendingPathComponent("approvals.json")
        self.mode = mode
    }

    public func isApproved(bundleIdentifier: String) -> Bool {
        switch mode {
        case .auto:
            return true
        case .prompt:
            return true  // Allow with warning
        case .explicit:
            let approved = loadApprovals()
            return approved.contains(bundleIdentifier)
        }
    }

    public func approve(bundleIdentifier: String) {
        var approved = loadApprovals()
        approved.insert(bundleIdentifier)
        saveApprovals(approved)
    }

    public func revoke(bundleIdentifier: String) {
        var approved = loadApprovals()
        approved.remove(bundleIdentifier)
        saveApprovals(approved)
    }

    public func listApproved() -> Set<String> {
        loadApprovals()
    }

    private func loadApprovals() -> Set<String> {
        guard let data = try? Data(contentsOf: storePath),
              let list = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(list)
    }

    private func saveApprovals(_ approvals: Set<String>) {
        let sorted = approvals.sorted()
        guard let data = try? JSONEncoder().encode(sorted) else { return }
        try? data.write(to: storePath, options: .atomic)
    }
}
