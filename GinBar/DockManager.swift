import Cocoa
import Combine

@MainActor
class DockManager: ObservableObject {
    static let shared = DockManager()
    @Published var spaceApps: [UInt64: [BarAppItem]] = [:]

    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    private let sls = SkyLightAPIs.shared

    private var pinnedAppsInfo: [PinnedAppInfo] = {
        if let data = UserDefaults.standard.data(forKey: "GinBar.pinnedApps"),
           let apps = try? JSONDecoder().decode([PinnedAppInfo].self, from: data) {
            return apps
        }
        return []
    }()

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

    // MARK: - Pinning

    func pinApp(bundleID: String, name: String, url: URL) {
        guard !pinnedAppsInfo.contains(where: { $0.bundleID == bundleID }) else { return }
        pinnedAppsInfo.append(PinnedAppInfo(bundleID: bundleID, name: name, url: url))
        savePinnedApps()
        updateAppsWithWindows()
    }

    func unpinApp(bundleID: String) {
        pinnedAppsInfo.removeAll { $0.bundleID == bundleID }
        savePinnedApps()
        updateAppsWithWindows()
    }

    func reorderPinnedApp(from: Int, to: Int) {
        guard from != to,
              from >= 0, from < pinnedAppsInfo.count,
              to >= 0, to < pinnedAppsInfo.count else { return }
        let item = pinnedAppsInfo.remove(at: from)
        pinnedAppsInfo.insert(item, at: to)
        savePinnedApps()

        // Re-sort pinned apps in every cached space entry so all bars show
        // the new order immediately (updateAppsWithWindows() only updates
        // spaceApps[currentSpace], so other bars would stay stale).
        var newSpaceApps = spaceApps
        for (spaceID, apps) in newSpaceApps {
            var updated = apps
            updated.sort { a, b in
                if a.isPinned != b.isPinned { return a.isPinned && !b.isPinned }
                if a.isPinned && b.isPinned {
                    let indexA = pinnedAppsInfo.firstIndex(where: { $0.bundleID == a.bundleIdentifier }) ?? Int.max
                    let indexB = pinnedAppsInfo.firstIndex(where: { $0.bundleID == b.bundleIdentifier }) ?? Int.max
                    return indexA < indexB
                }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            newSpaceApps[spaceID] = updated
        }
        spaceApps = newSpaceApps

        NotificationCenter.default.post(name: .init("GinBar.PinnedAppsReordered"), object: nil)
    }

    func isPinned(bundleID: String) -> Bool {
        pinnedAppsInfo.contains(where: { $0.bundleID == bundleID })
    }

    var pinnedBundleIDs: [String] {
        pinnedAppsInfo.map { $0.bundleID }
    }

    private func savePinnedApps() {
        if let data = try? JSONEncoder().encode(pinnedAppsInfo) {
            UserDefaults.standard.set(data, forKey: "GinBar.pinnedApps")
        }
    }

    // MARK: - App actions

    func activateApp(_ item: BarAppItem) {
        if item.processIdentifier > 0,
           let app = NSRunningApplication(processIdentifier: item.processIdentifier) {
            app.activate()
        } else if let url = item.url {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func closeApp(_ item: BarAppItem) {
        if item.processIdentifier > 0,
           let app = NSRunningApplication(processIdentifier: item.processIdentifier) {
            app.terminate()
        }
    }

    // MARK: - Space window tracking

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

        // Build the visible-apps list as BarAppItems
        var result: [BarAppItem] = allApps
            .filter { currentPIDs.contains($0.processIdentifier) }
            .map { BarAppItem(from: $0, isPinned: false) }

        // Add running pinned apps (always show pinned icon, even if the app
        // also has visible windows and appears as a regular chip).
        for app in allApps {
            if let bundleID = app.bundleIdentifier,
               isPinned(bundleID: bundleID) {
                result.append(BarAppItem(from: app, isPinned: true))
            }
        }

        // Add non-running pinned apps
        for info in pinnedAppsInfo {
            if !result.contains(where: { $0.bundleIdentifier == info.bundleID }) {
                result.append(BarAppItem(pinnedBundleID: info.bundleID, name: info.name, url: info.url))
            }
        }

        // Sort: pinned apps in pinnedAppsInfo order, then non-pinned apps alphabetically
        result.sort { a, b in
            if a.isPinned != b.isPinned { return a.isPinned && !b.isPinned }
            if a.isPinned && b.isPinned {
                let indexA = pinnedAppsInfo.firstIndex(where: { $0.bundleID == a.bundleIdentifier }) ?? Int.max
                let indexB = pinnedAppsInfo.firstIndex(where: { $0.bundleID == b.bundleIdentifier }) ?? Int.max
                return indexA < indexB
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }

        let cacheKey = currentSpace ?? 0
        let cachedItems = spaceApps[cacheKey] ?? []
        // Include isPinned in the cache key so that a pinned app gaining or
        // losing visible windows (which changes its representation count) still
        // triggers a UI update.
        let cachedIDs = Set(cachedItems.map { "\($0.id):\($0.isPinned)" })
        let resultIDs = Set(result.map { "\($0.id):\($0.isPinned)" })

        guard resultIDs != cachedIDs else { return }
        spaceApps[cacheKey] = result
    }
}
