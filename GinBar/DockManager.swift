import Cocoa
import Combine

@MainActor
class DockManager: ObservableObject {
    static let shared = DockManager()
    @Published var spaceApps: [UInt64: [NSRunningApplication]] = [:]
    
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    private let sls = SkyLightAPIs.shared
    
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
        
        if sls.copySpacesForWindows == nil {
            print("[GinBar] SLSCopySpacesForWindows not found, falling back to kCGWindowWorkspace")
        } else {
            print("[GinBar] SLSCopySpacesForWindows loaded")
        }
        
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
    
    /// Ask SkyLight which Mission Control spaces a window belongs to.
    /// Tries multiple return formats since the private API structure varies by macOS version.
    private func spacesForWindow(windowNumber: Int) -> [UInt64] {
        guard let copyFn = sls.copySpacesForWindows,
              let cid = sls.mainConnectionID?() else { return [] }
        
        let arr = NSMutableArray()
        arr.add(windowNumber)
        guard let raw = copyFn(cid, 7, arr as CFArray)?.takeRetainedValue() else { return [] }
        
        // Format 1: flat array of NSDictionary with "id64" key
        if let dicts = raw as? [NSDictionary] {
            return dicts.compactMap { $0["id64"] as? UInt64 }
        }
        
        // Format 2: flat array of NSNumber (space IDs directly)
        if let numbers = raw as? [NSNumber] {
            return numbers.map { $0.uint64Value }
        }
        
        // Format 3: array of arrays (one per window), each inner array contains NSDictionary
        if let outer = raw as? [NSArray], let inner = outer.first as? [NSDictionary] {
            return inner.compactMap { $0["id64"] as? UInt64 }
        }
        
        // Format 4: array of arrays of NSNumber
        if let outer = raw as? [NSArray], let inner = outer.first as? [NSNumber] {
            return inner.map { $0.uint64Value }
        }
        
        return []
    }
    
    func updateAppsWithWindows() {
        guard !isRunningInPreview else { return }
        
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return
        }
        
        let currentSpace = WindowManager.shared.currentSpaceID
        
        var currentPIDs = Set<pid_t>()
        
        // Collect visible PIDs.  Start with the old reliable baseline (all
        // visible windows).  Then if we know the current space, try to refine
        // the list with SkyLight or kCGWindowWorkspace.  If those fail we still
        // have the baseline so the bar never goes blank.
        for windowDict in windowList {
            if let ownerPID = windowDict[kCGWindowOwnerPID as String] as? pid_t {
                currentPIDs.insert(ownerPID)
            }
        }
        
        if let space = currentSpace {
            let skyLightAvailable = sls.copySpacesForWindows != nil
            var filteredPIDs = Set<pid_t>()
            var skyLightFoundAny = false
            
            if skyLightAvailable {
                for windowDict in windowList {
                    guard let windowNumber = windowDict[kCGWindowNumber as String] as? Int,
                          let ownerPID = windowDict[kCGWindowOwnerPID as String] as? pid_t else { continue }
                    let spaces = spacesForWindow(windowNumber: windowNumber)
                    if spaces.contains(space) {
                        filteredPIDs.insert(ownerPID)
                    }
                }
                if !filteredPIDs.isEmpty {
                    currentPIDs = filteredPIDs
                    skyLightFoundAny = true
                }
            }
            
            if !skyLightFoundAny {
                var workspaceCounts: [Int: Int] = [:]
                var pidToWorkspace: [pid_t: Int] = [:]
                for windowDict in windowList {
                    if let ownerPID = windowDict[kCGWindowOwnerPID as String] as? pid_t,
                       let ws = windowDict["kCGWindowWorkspace" as String] as? Int {
                        workspaceCounts[ws, default: 0] += 1
                        pidToWorkspace[ownerPID] = ws
                    }
                }
                if let dominantWS = workspaceCounts.max(by: { $0.value < $1.value })?.key {
                    let wsPIDs = Set(pidToWorkspace.filter { $0.value == dominantWS }.map { $0.key })
                    if !wsPIDs.isEmpty {
                        currentPIDs = wsPIDs
                    }
                }
            }
        }
        
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
                    
                    if let cachedSpace = WindowManager.shared.spaceIDForMinimizedWindow(pid: app.processIdentifier, title: title),
                       cachedSpace == currentSpace {
                        hasMinimizedOnCurrentSpace = true
                        break
                    } else if WindowManager.shared.spaceIDForMinimizedWindow(pid: app.processIdentifier, title: title) == nil {
                        hasMinimizedOnCurrentSpace = true
                        break
                    }
                }
            }
            if hasMinimizedOnCurrentSpace {
                currentPIDs.insert(app.processIdentifier)
            }
        }
        
        let candidateApps = allApps.filter { currentPIDs.contains($0.processIdentifier) }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        
        let cacheKey = currentSpace ?? 0
        let cachedApps = spaceApps[cacheKey] ?? []
        let cachedPIDs = Set(cachedApps.map { $0.processIdentifier })
        let candidatePIDs = Set(candidateApps.map { $0.processIdentifier })
        
        guard candidatePIDs != cachedPIDs else { return }
        spaceApps[cacheKey] = candidateApps
    }
    
    func activateApp(_ app: NSRunningApplication) {
        app.activate()
    }
}
