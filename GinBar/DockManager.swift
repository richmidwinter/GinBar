import Cocoa
import Combine

@MainActor
class DockManager: ObservableObject {
    static let shared = DockManager()
    @Published var appsWithWindows: [NSRunningApplication] = []
    
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    
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
        guard !isRunningInPreview else { return }
        
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
    
    @objc private func updateAppsWithWindows() {
        guard !isRunningInPreview else { return }
        
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return
        }
        
        // Get current PIDs
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
        
        let candidateApps = allApps.filter { app in
            currentPIDs.contains(app.processIdentifier)
        }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        
        let currentAppPIDs = Set(appsWithWindows.map { $0.processIdentifier })
        let candidatePIDs = Set(candidateApps.map { $0.processIdentifier })
        
        // CRITICAL: Reject "bloated" lists during space transitions
        // Space transitions add MULTIPLE apps at once, while opening a single app adds just 1
        let addedCount = candidateApps.count - appsWithWindows.count
        if !appsWithWindows.isEmpty && addedCount > 1 {
            // Multiple apps appeared at once - space transition bloat, ignore
            return
        }
        
        // List is same size or smaller - safe to update
        if candidatePIDs != currentAppPIDs {
            appsWithWindows = candidateApps
        }
    }
    
    func activateApp(_ app: NSRunningApplication) {
        app.activate()
    }
}
