import Cocoa

struct PinnedAppInfo: Codable {
    let bundleID: String
    let name: String
    let url: URL
}

struct BarAppItem: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: NSImage?
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let url: URL?
    let isPinned: Bool

    /// Queries `NSWorkspace.shared.frontmostApplication` directly instead of
    /// caching `NSRunningApplication.isActive`, which can be stale when our
    /// app is backgrounded.
    var isActive: Bool {
        guard let bundleID = bundleIdentifier else { return false }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    init(from app: NSRunningApplication, isPinned: Bool = false) {
        self.id = app.bundleIdentifier ?? "\(app.processIdentifier)"
        self.name = app.localizedName ?? "Unknown"
        self.icon = app.icon
        self.processIdentifier = app.processIdentifier
        self.bundleIdentifier = app.bundleIdentifier
        self.url = app.bundleURL
        self.isPinned = isPinned
    }

    init(pinnedBundleID: String, name: String, url: URL) {
        self.id = pinnedBundleID
        self.name = name
        self.icon = NSWorkspace.shared.icon(forFile: url.path)
        self.processIdentifier = 0
        self.bundleIdentifier = pinnedBundleID
        self.url = url
        self.isPinned = true
    }
}
