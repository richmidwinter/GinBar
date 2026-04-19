import Cocoa
import Combine

@MainActor
class DockManager: ObservableObject {
    static let shared = DockManager()
    /// Per-space app lists. Each bar reads its own entry so it never shows
    /// windows from a different space, even during Mission Control transitions.
    @Published var spaceApps: [UInt64: [NSRunningApplication]] = [:]
    
    /// Set by OverlayManager while a Mission Control transition is in progress.
    /// Timer ticks are suppressed so no space's cache gets polluted with bloat.
    var isInTransition = false
    
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    private var pendingPIDs: Set<pid_t>?
    
    private var isRunningInPreview: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["XCODE_RUNNING_FOR_PREVIEWS"] == "1" { return true }
        if env["SWIFTUI_RUNNING_FOR_PREVIEWS"] == "1" { return true }
        if env["XCODE_RUNNING_FOR_PREVIEWS"] == "YES" { return true }
        let processName = ProcessInfo.processInfo.processName.lowercased()
        if processName.contains("preview") { return true }
        if Bundle.main.bundlePath.contains("Previews") { return true }
        if Bundle.main.executableURL?.path.contains("Previews") == true { return true }
        let count = _dyld_image_count()
        for i in 0..<count {
            if let name = _dyld_get_image_name(i) {
                if String(cString: name).contains("__preview.dylib") { return true }
            }
        }
        return false
    }
    
    private init() {
        guard !isRunningInPreview && !isInTransition else { return }
        
        updateAppsWithWindows()
        
        NotificationCenter.default.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .sink { [weak self] _ in self?.updateAppsWithWindows() }
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .sink { [weak self] _ in self?.updateAppsWithWindows() }
            .store(in: &cancellables)
        
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.updateAppsWithWindows()
        }
    }
    
    func updateAppsWithWindows() {
        guard !isRunningInPreview else { return }
        if isInTransition {
            // log removed
            return
        }
        
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return
        }
        
        // Get current PIDs from visible windows
        var currentPIDs = Set<pid_t>()
        for windowDict in windowList {
            if let ownerPID = windowDict[kCGWindowOwnerPID as String] as? pid_t {
                currentPIDs.insert(ownerPID)
            }
        }
        
        // Get apps for these PIDs
        let currentBundleId = Bundle.main.bundleIdentifier ?? ""
        let allApps = NSWorkspace.shared.runningApplications.filter { app in
            if let bundleId = app.bundleIdentifier {
                return bundleId != currentBundleId && app.activationPolicy == .regular
            }
            return app.processIdentifier != ProcessInfo.processInfo.processIdentifier 
                && app.activationPolicy == .regular
        }
        
        // Also include apps that have minimized windows on the current space
        for app in allApps where !currentPIDs.contains(app.processIdentifier) {
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            var value: AnyObject?
            guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &value) == .success,
                  let axWindows = value as? [AXUIElement] else { continue }
            var hasMinimizedOnCurrentSpace = false
            for axWindow in axWindows {
                var minimizedRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minimizedRef)
                if let minimized = minimizedRef, CFGetTypeID(minimized) == CFBooleanGetTypeID(), CFBooleanGetValue(minimized as! CFBoolean) {
                    var titleRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)
                    let title = (titleRef as? String) ?? ""
                    
                    if let currentSpace = WindowManager.shared.currentSpaceID,
                       let cachedSpace = WindowManager.shared.spaceIDForMinimizedWindow(pid: app.processIdentifier, title: title) {
                        if cachedSpace == currentSpace {
                            hasMinimizedOnCurrentSpace = true
                            break
                        }
                    } else {
                        // Unknown space, include as fallback
                        hasMinimizedOnCurrentSpace = true
                        break
                    }
                }
            }
            if hasMinimizedOnCurrentSpace {
                currentPIDs.insert(app.processIdentifier)
            }
        }
        
        let candidateApps = allApps.filter { app in
            currentPIDs.contains(app.processIdentifier)
        }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        
        guard let currentSpace = WindowManager.shared.currentSpaceID else {
            // log removed
            return
        }
        let cachedApps = spaceApps[currentSpace] ?? []
        let cachedPIDs = Set(cachedApps.map { $0.processIdentifier })
        let candidatePIDs = Set(candidateApps.map { $0.processIdentifier })
        
        // log removed
        
        guard candidatePIDs != cachedPIDs else {
            pendingPIDs = nil
            return
        }
        
        // Bypass stability check when the cache is empty (first visit to a
        // space) so the bar populates immediately instead of waiting for a
        // second timer tick.
        if candidatePIDs == pendingPIDs || spaceApps[currentSpace] == nil {
            spaceApps[currentSpace] = candidateApps
            pendingPIDs = nil
            // log removed
        } else {
            // First time seeing this set — wait one more tick.
            pendingPIDs = candidatePIDs
            // log removed
        }
    }
    
    func activateApp(_ app: NSRunningApplication) {
        app.activate()
    }
}
