import Cocoa
import Combine

@MainActor
class DockManager: ObservableObject {
    static let shared = DockManager()
    @Published var spaceApps: [UInt64: [BarAppItem]] = [:]

    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    private let sls = SkyLightAPIs.shared
    
    // Cache window-to-space mappings so we don't hammer SkyLight on every tick.
    private var windowSpaceCache: [Int: [UInt64]] = [:]
    private var lastWindowSignature: [Int] = []

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

        NotificationCenter.default.publisher(for: NSWorkspace.didActivateApplicationNotification)
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

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let currentSpace = WindowManager.shared.currentSpaceID
        let skyLightAvailable = sls.copySpacesForWindows != nil

        let allApps = NSWorkspace.shared.runningApplications.filter { app in
            if let bundleId = app.bundleIdentifier {
                return bundleId != (Bundle.main.bundleIdentifier ?? "") && app.activationPolicy == .regular
            }
            return app.processIdentifier != currentPID && app.activationPolicy == .regular
        }

        // Collect all known Mission Control spaces.
        var allSpaceIDs = Set<UInt64>()
        if let copyFn = sls.copyManagedDisplaySpaces,
           let displays = copyFn(sls.mainConnectionID?() ?? 0)?.takeRetainedValue() as? [NSDictionary] {
            for display in displays {
                if let spacesArray = display["Spaces"] as? [NSDictionary] {
                    for space in spacesArray {
                        if let id64 = space["id64"] as? UInt64 {
                            allSpaceIDs.insert(id64)
                        }
                    }
                }
            }
        }

        var spacePIDMap: [UInt64: Set<pid_t>] = [:]

        if skyLightAvailable {
            // Use .optionAll so we see windows from *every* Mission Control space,
            // then ask SkyLight which space each window belongs to.
            let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
            guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
                return
            }

            var validWindows: [(windowNumber: Int, pid: pid_t)] = []
            for windowDict in windowList {
                guard let ownerPID = windowDict[kCGWindowOwnerPID as String] as? pid_t,
                      let layer = windowDict[kCGWindowLayer as String] as? Int32,
                      let bounds = windowDict[kCGWindowBounds as String] as? [String: CGFloat],
                      let windowNumber = windowDict[kCGWindowNumber as String] as? Int else { continue }

                guard ownerPID != currentPID else { continue }

                let frame = CGRect(
                    x: bounds["X"] ?? 0,
                    y: bounds["Y"] ?? 0,
                    width: bounds["Width"] ?? 0,
                    height: bounds["Height"] ?? 0
                )
                guard frame.width >= 20, frame.height >= 20, layer < 100 else { continue }
                guard allApps.contains(where: { $0.processIdentifier == ownerPID }) else { continue }

                validWindows.append((windowNumber: windowNumber, pid: ownerPID))
            }

            // Cache SkyLight results per window so we don't call it every 0.1 s.
            let windowListSignature = validWindows.map { $0.windowNumber }.sorted()
            if windowListSignature != lastWindowSignature {
                windowSpaceCache.removeAll()
                lastWindowSignature = windowListSignature
            }

            for (windowNumber, pid) in validWindows {
                let spaces: [UInt64]
                if let cached = windowSpaceCache[windowNumber] {
                    spaces = cached
                } else {
                    spaces = spacesForWindow(windowNumber: windowNumber)
                    windowSpaceCache[windowNumber] = spaces
                }
                for spaceID in spaces where allSpaceIDs.contains(spaceID) {
                    spacePIDMap[spaceID, default: Set<pid_t>()].insert(pid)
                }
            }
        } else {
            // Fallback when SkyLight isn't available: current space only.
            let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
            guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
                return
            }

            var currentPIDs = Set<pid_t>()
            for windowDict in windowList {
                if let ownerPID = windowDict[kCGWindowOwnerPID as String] as? pid_t {
                    currentPIDs.insert(ownerPID)
                }
            }

            if let space = currentSpace {
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

            if let space = currentSpace {
                spacePIDMap[space] = currentPIDs
            }
        }

        // Add minimized windows via Accessibility (they don't appear in CGWindowList).
        for app in allApps {
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            var value: AnyObject?
            guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &value) == .success,
                  let axWindows = value as? [AXUIElement] else { continue }

            for axWindow in axWindows {
                var minimizedRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minimizedRef)
                guard let minimized = minimizedRef,
                      CFGetTypeID(minimized) == CFBooleanGetTypeID(),
                      CFBooleanGetValue(minimized as! CFBoolean) else { continue }

                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)
                let title = (titleRef as? String) ?? ""

                if let cachedSpace = WindowManager.shared.spaceIDForMinimizedWindow(pid: app.processIdentifier, title: title),
                   allSpaceIDs.contains(cachedSpace) {
                    spacePIDMap[cachedSpace, default: Set<pid_t>()].insert(app.processIdentifier)
                } else if let space = currentSpace, allSpaceIDs.contains(space) {
                    // If not cached, assume current space as fallback.
                    spacePIDMap[space, default: Set<pid_t>()].insert(app.processIdentifier)
                }
            }
        }

        // Build spaceApps for every known space.
        var newSpaceApps = spaceApps
        var anyChanged = false

        for spaceID in allSpaceIDs {
            let pids = spacePIDMap[spaceID] ?? Set<pid_t>()

            var result: [BarAppItem] = allApps
                .filter { pids.contains($0.processIdentifier) }
                .map { BarAppItem(from: $0, isPinned: false) }

            // Running pinned apps (always show pinned icon).
            for app in allApps {
                if let bundleID = app.bundleIdentifier, isPinned(bundleID: bundleID) {
                    result.append(BarAppItem(from: app, isPinned: true))
                }
            }

            // Non-running pinned apps.
            for info in pinnedAppsInfo {
                if !result.contains(where: { $0.bundleIdentifier == info.bundleID }) {
                    result.append(BarAppItem(pinnedBundleID: info.bundleID, name: info.name, url: info.url))
                }
            }

            // Sort: pinned first, then alphabetical.
            result.sort { a, b in
                if a.isPinned != b.isPinned { return a.isPinned && !b.isPinned }
                if a.isPinned && b.isPinned {
                    let indexA = pinnedAppsInfo.firstIndex(where: { $0.bundleID == a.bundleIdentifier }) ?? Int.max
                    let indexB = pinnedAppsInfo.firstIndex(where: { $0.bundleID == b.bundleIdentifier }) ?? Int.max
                    return indexA < indexB
                }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }

            let cachedItems = newSpaceApps[spaceID] ?? []
            let cachedIDs = Set(cachedItems.map { "\($0.id):\($0.isPinned):\($0.isActive)" })
            let resultIDs = Set(result.map { "\($0.id):\($0.isPinned):\($0.isActive)" })

            if resultIDs != cachedIDs {
                newSpaceApps[spaceID] = result
                anyChanged = true
                NotificationCenter.default.post(name: .init("GinBar.SpaceAppsUpdated"), object: nil, userInfo: ["spaceID": spaceID])
            }
        }

        spaceApps = newSpaceApps
    }
}
