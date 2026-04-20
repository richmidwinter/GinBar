import Cocoa
import Combine
import ScreenCaptureKit
import ApplicationServices

struct WindowInfo: Identifiable {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String
    let frame: CGRect
    let isOnScreen: Bool
    let layer: Int32
    let alpha: Float
    
    var idValue: UInt32 { id }
}

enum CapturePermissionStatus: Equatable {
    case unknown
    case granted
    case denied
}

@MainActor
class WindowManager: ObservableObject {
    static let shared = WindowManager()
    @Published var windows: [WindowInfo] = []
    @Published var selectedApp: NSRunningApplication?
    @Published var hoveredWindow: WindowInfo?
    @Published var thumbnails: [CGWindowID: NSImage] = [:]
    @Published var permissionStatus: CapturePermissionStatus = .unknown
    @Published var isPopupHovered: Bool = false
    @Published var currentSpaceID: UInt64?
    
    var onSwitchToSpace: ((UInt64) -> Void)?
    
    private var timer: Timer?
    private var hidePopupTimer: Timer?
    private var adjustTimer: Timer?
    private var hasPromptedForAccessibility = false
    private var barHeight: CGFloat = 0
    private var cancellables = Set<AnyCancellable>()
    private var nextSyntheticID: CGWindowID = 0xFFFF0000
    private var syntheticWindows: [String: WindowInfo] = [:]
    private var windowSpaceCache: [String: UInt64] = [:]
    private var thumbnailCaptureTime: [CGWindowID: Date] = [:]
    private let sls = SkyLightAPIs.shared
    
    var isRunningInPreview: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["XCODE_RUNNING_FOR_PREVIEWS"] == "1" { return true }
        if env["SWIFTUI_RUNNING_FOR_PREVIEWS"] == "1" { return true }
        if env["XCODE_RUNNING_FOR_PREVIEWS"] == "YES" { return true }
        let processName = ProcessInfo.processInfo.processName.lowercased()
        if processName.contains("preview") { return true }
        if Bundle.main.bundlePath.contains("Previews") { return true }
        if Bundle.main.executableURL?.path.contains("Previews") == true { return true }
        return false
    }
    
    var effectivePermissionStatus: CapturePermissionStatus {
        isRunningInPreview ? .granted : permissionStatus
    }
    
    init() {
        // Clear stale cached thumbnails from old aspect-ratio bugs
        thumbnails.removeAll()
        
        if isRunningInPreview {
            permissionStatus = .granted
        } else {
            startMonitoring()
        }
        
        $selectedApp
            .sink { [weak self] app in
                guard let self = self, let app = app else { return }
                for window in self.windows(for: app) {
                    _ = self.captureThumbnail(for: window.id)
                }
            }
            .store(in: &cancellables)
    }
    
    deinit {
        timer?.invalidate()
        hidePopupTimer?.invalidate()
        axCleanupTimer?.invalidate()
        for (_, obs) in axObservers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        axObservers.removeAll()
    }
    
    func scheduleHidePopup() {
        hidePopupTimer?.invalidate()
        hidePopupTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if !self.isPopupHovered && self.hoveredWindow == nil {
                    self.selectedApp = nil
                }
            }
        }
    }
    
    func cancelHidePopupTimer() {
        hidePopupTimer?.invalidate()
        hidePopupTimer = nil
    }
    
    private func startMonitoring() {
        updateWindows()
        
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateWindows()
            }
        }
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(spaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }
    
    @objc private func spaceDidChange() {
        // log removed
        selectedApp = nil // hide popup when switching spaces
        // Defer so OverlayManager has a chance to update currentSpaceID
        // before we cache visible windows against the wrong space.
        DispatchQueue.main.async { [weak self] in
            self?.updateWindows()
        }
    }
    
    func switchToSpace(_ spaceID: UInt64) {
        onSwitchToSpace?(spaceID)
    }
    
    /// Ask SkyLight which Mission Control spaces a window belongs to.
    /// Tries multiple return formats since the private API structure varies by macOS version.
    private func spacesForWindow(windowNumber: Int) -> [UInt64] {
        guard let copyFn = sls.copySpacesForWindows,
              let cid = sls.mainConnectionID?() else { return [] }
        
        let arr = NSMutableArray()
        arr.add(windowNumber)
        guard let raw = copyFn(cid, 7, arr as CFArray)?.takeRetainedValue() else { return [] }
        
        if let dicts = raw as? [NSDictionary] {
            return dicts.compactMap { $0["id64"] as? UInt64 }
        }
        if let numbers = raw as? [NSNumber] {
            return numbers.map { $0.uint64Value }
        }
        if let outer = raw as? [NSArray], let inner = outer.first as? [NSDictionary] {
            return inner.compactMap { $0["id64"] as? UInt64 }
        }
        if let outer = raw as? [NSArray], let inner = outer.first as? [NSNumber] {
            return inner.map { $0.uint64Value }
        }
        return []
    }
    
    func updateWindows() {
        guard !isRunningInPreview else { return }
        
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return
        }
        
        let runningApps = NSWorkspace.shared.runningApplications
        let currentPID = ProcessInfo.processInfo.processIdentifier
        
        var newWindows: [WindowInfo] = []
        var titledWindowIDs = Set<CGWindowID>()
        
        for windowDict in windowList {
            guard let windowNumber = windowDict[kCGWindowNumber as String] as? CGWindowID,
                  let ownerPID = windowDict[kCGWindowOwnerPID as String] as? pid_t,
                  let ownerName = windowDict[kCGWindowOwnerName as String] as? String,
                  let layer = windowDict[kCGWindowLayer as String] as? Int32,
                  let bounds = windowDict[kCGWindowBounds as String] as? [String: CGFloat],
                  let alpha = windowDict[kCGWindowAlpha as String] as? Float else {
                continue
            }
            
            guard ownerPID != currentPID else { continue }
            
            guard let app = runningApps.first(where: { $0.processIdentifier == ownerPID }),
                  app.activationPolicy == .regular else {
                continue
            }
            
            let cgTitle = windowDict[kCGWindowName as String] as? String
            let title = cgTitle?.isEmpty == false ? cgTitle! : (app.localizedName ?? "")
            
            let frame = CGRect(
                x: bounds["X"] ?? 0,
                y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0,
                height: bounds["Height"] ?? 0
            )
            
            let isOnScreen = windowDict[kCGWindowIsOnscreen as String] as? Bool ?? false
            
            let info = WindowInfo(
                id: windowNumber,
                pid: ownerPID,
                appName: ownerName,
                title: title,
                frame: frame,
                isOnScreen: isOnScreen,
                layer: layer,
                alpha: alpha
            )
            
            // Filter out internal/transient windows (typeahead popups, hover bubbles, 1×1 helpers)
            guard info.frame.width >= 20, info.frame.height >= 20, info.layer < 100 else {
                continue
            }
            
            if cgTitle?.isEmpty == false {
                titledWindowIDs.insert(windowNumber)
            }
            
            newWindows.append(info)
        }
        
        // Filter out untitled windows for apps that also have titled windows
        // (untitled windows in a multi-window app are almost always internal/transient)
        let pidsWithTitledWindows = Set(newWindows.compactMap { titledWindowIDs.contains($0.id) ? $0.pid : nil })
        newWindows = newWindows.filter {
            titledWindowIDs.contains($0.id) || !pidsWithTitledWindows.contains($0.pid)
        }
        
        // Filter to current space so swipe previews don't inflate window counts.
        // Same approach as DockManager: SkyLight first, then kCGWindowWorkspace,
        // then fall back to the baseline (all visible windows).
        if let space = currentSpaceID {
            let skyLightAvailable = sls.copySpacesForWindows != nil
            var filtered = [WindowInfo]()
            var skyLightFoundAny = false
            
            if skyLightAvailable {
                for window in newWindows {
                    let spaces = spacesForWindow(windowNumber: Int(window.id))
                    if spaces.contains(space) {
                        filtered.append(window)
                    }
                }
                if !filtered.isEmpty {
                    newWindows = filtered
                    skyLightFoundAny = true
                }
            }
            
            if !skyLightFoundAny {
                var workspaceCounts: [Int: Int] = [:]
                var windowToWorkspace: [CGWindowID: Int] = [:]
                for windowDict in windowList {
                    if let num = windowDict[kCGWindowNumber as String] as? Int,
                       let ws = windowDict["kCGWindowWorkspace" as String] as? Int {
                        workspaceCounts[ws, default: 0] += 1
                        windowToWorkspace[CGWindowID(num)] = ws
                    }
                }
                if let dominantWS = workspaceCounts.max(by: { $0.value < $1.value })?.key {
                    let wsWindows = newWindows.filter { windowToWorkspace[$0.id] == dominantWS }
                    if !wsWindows.isEmpty {
                        newWindows = wsWindows
                    }
                }
            }
        }
        
        self.windows = newWindows.sorted { $0.layer < $1.layer }
        
        // Cache visible windows to current space for minimized window tracking
        if let spaceID = currentSpaceID {
            for window in windows {
                let key = "\(window.pid):\(window.title)"
                windowSpaceCache[key] = spaceID
            }
        }
    }
    
    func windows(for app: NSRunningApplication) -> [WindowInfo] {
        var result = windows.filter { $0.pid == app.processIdentifier }
        
        // Also include minimized windows via Accessibility API
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let axWindows = value as? [AXUIElement] else {
            return result
        }
        
        for axWindow in axWindows {
            var minimizedRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minimizedRef)
            guard let minimized = minimizedRef, CFGetTypeID(minimized) == CFBooleanGetTypeID(), CFBooleanGetValue(minimized as! CFBoolean) else { continue }
            
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)
            let title = (titleRef as? String) ?? ""
            
            // Filter minimized windows by current space
            if let currentSpace = currentSpaceID {
                let key = "\(app.processIdentifier):\(title)"
                if let cachedSpace = windowSpaceCache[key], cachedSpace != currentSpace {
                    continue
                }
                // If not in cache, include as fallback
            }
            
            // Skip if already in the visible list
            if result.contains(where: { $0.title == title }) { continue }
            
            let key = "\(app.processIdentifier):\(title)"
            if let cached = syntheticWindows[key] {
                result.append(cached)
            } else {
                let id = nextSyntheticID
                nextSyntheticID += 1
                let info = WindowInfo(
                    id: id,
                    pid: app.processIdentifier,
                    appName: app.localizedName ?? "",
                    title: title,
                    frame: .zero,
                    isOnScreen: false,
                    layer: 0,
                    alpha: 1.0
                )
                syntheticWindows[key] = info
                result.append(info)
            }
        }
        
        return result
    }
    
    func spaceIDForMinimizedWindow(pid: pid_t, title: String) -> UInt64? {
        return windowSpaceCache["\(pid):\(title)"]
    }
    
    func thumbnailStatus(for windowID: CGWindowID) -> String {
        switch effectivePermissionStatus {
        case .unknown:
            return "Loading..."
        case .denied:
            return "No permission"
        case .granted:
            return thumbnails[windowID] != nil ? "" : "Loading..."
        }
    }
    
    func captureThumbnail(for windowID: CGWindowID) -> NSImage? {
        guard !isRunningInPreview else { return nil }
        
        let isFresh = thumbnailCaptureTime[windowID].map { Date().timeIntervalSince($0) < 10 } ?? false
        if let cached = thumbnails[windowID], isFresh {
            return cached
        }
        
        Task {
            await captureThumbnailAsync(for: windowID)
        }
        return nil
    }
    
    private func captureThumbnailAsync(for windowID: CGWindowID) async {
        do {
            let content = try await SCShareableContent.current
            
            await MainActor.run {
                self.permissionStatus = .granted
            }
            
            guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
                return
            }
            
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let scFrame = scWindow.frame
            let aspectRatio = scFrame.width / max(scFrame.height, 1)
            let captureWidth: CGFloat = 320
            let captureHeight = captureWidth / aspectRatio
            
            let config = SCStreamConfiguration()
            config.width = Int(captureWidth)
            config.height = Int(captureHeight)
            config.scalesToFit = true
            config.backgroundColor = .clear
            
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            
            let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            
            await MainActor.run {
                self.thumbnails[windowID] = nsImage
                self.thumbnailCaptureTime[windowID] = Date()
            }
        } catch {
            await MainActor.run {
                let nsError = error as NSError
                if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && nsError.code == -3801 {
                    self.permissionStatus = .denied
                } else if nsError.domain == "com.apple.ReplayKit.RPRecordingErrorDomain" {
                    self.permissionStatus = .denied
                }
            }
        }
    }
    
    func refreshPermission() {
        permissionStatus = .unknown
        let current = selectedApp
        selectedApp = nil
        selectedApp = current
    }
    
    // MARK: - Bar spacing via AX observers
    
    private var axObservers: [pid_t: AXObserver] = [:]
    private var axCleanupTimer: Timer?
    private var originalDockAutohide: Bool?
    
    func startAdjustingWindowsForBar(barHeight: CGFloat) {
        guard !isRunningInPreview else { return }
        self.barHeight = barHeight
        hideSystemDock()
        setupAXObservers()
        adjustWindowsForBar()
        
        axCleanupTimer?.invalidate()
        axCleanupTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.adjustWindowsForBar()
            }
        }
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appLaunchedForAdjust(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appTerminatedForAdjust(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(willTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }
    
    private var originalDockAutohideDelay: Float?
    
    private func hideSystemDock() {
        let autohide = dockAutohide()
        let delay = dockAutohideDelay()
        originalDockAutohide = autohide
        originalDockAutohideDelay = delay
        
        // Write crash-recovery state
        let fm = FileManager.default
        let supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("GinBar", isDirectory: true)
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let state = [
            "autohide": autohide,
            "autohideDelay": delay
        ] as [String: Any]
        let stateURL = supportDir.appendingPathComponent("dockRestore.plist")
        try? (state as NSDictionary).write(to: stateURL)
        
        // Install LaunchAgent for crash recovery
        installDockRestoreAgent()
        
        setDockAutohide(true)
        setDockAutohideDelay(1000)
        restartDock()
    }
    
    private func restoreSystemDock() {
        if let state = originalDockAutohide {
            setDockAutohide(state)
            originalDockAutohide = nil
        }
        if let delay = originalDockAutohideDelay {
            setDockAutohideDelay(delay)
            originalDockAutohideDelay = nil
        } else {
            let task = Process()
            task.launchPath = "/usr/bin/defaults"
            task.arguments = ["delete", "com.apple.dock", "autohide-delay"]
            try? task.run()
            task.waitUntilExit()
        }
        restartDock()
        
        // Remove crash-recovery agent
        removeDockRestoreAgent()
    }
    
    private func installDockRestoreAgent() {
        let label = "annotate.GinBar.DockRestore"
        let plistPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
        
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [
                "/bin/sh",
                "-c",
                """
                sleep 5
                if ! pgrep -x "GinBar" > /dev/null; then
                    defaults write com.apple.dock autohide-delay -float 0
                    defaults write com.apple.dock autohide -bool false
                    killall Dock
                    launchctl unload ~/Library/LaunchAgents/\(label).plist
                    rm ~/Library/LaunchAgents/\(label).plist
                fi
                """
            ],
            "StartInterval": 10,
            "RunAtLoad": true
        ]
        
        (plist as NSDictionary).write(to: plistPath, atomically: true)
        
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = ["load", plistPath.path]
        try? task.run()
    }
    
    private func removeDockRestoreAgent() {
        let label = "annotate.GinBar.DockRestore"
        let plistPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
        
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = ["unload", plistPath.path]
        try? task.run()
        task.waitUntilExit()
        try? FileManager.default.removeItem(at: plistPath)
        
        let stateURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("GinBar/dockRestore.plist")
        try? FileManager.default.removeItem(at: stateURL)
    }
    
    private func dockAutohide() -> Bool {
        guard let val = CFPreferencesCopyAppValue("autohide" as CFString, "com.apple.dock" as CFString) as? Int else {
            return false
        }
        return val != 0
    }
    
    private func dockAutohideDelay() -> Float {
        guard let val = CFPreferencesCopyAppValue("autohide-delay" as CFString, "com.apple.dock" as CFString) as? NSNumber else {
            return 0
        }
        return val.floatValue
    }
    
    private func setDockAutohide(_ value: Bool) {
        CFPreferencesSetAppValue("autohide" as CFString, value ? 1 as CFNumber : 0 as CFNumber, "com.apple.dock" as CFString)
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
    }
    
    private func setDockAutohideDelay(_ value: Float) {
        let num = NSNumber(value: value)
        CFPreferencesSetAppValue("autohide-delay" as CFString, num, "com.apple.dock" as CFString)
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
    }
    
    private func restartDock() {
        let task = Process()
        task.launchPath = "/usr/bin/killall"
        task.arguments = ["Dock"]
        try? task.run()
    }
    
    @objc private func willTerminate() {
        restoreSystemDock()
        for (_, obs) in axObservers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        axObservers.removeAll()
        axCleanupTimer?.invalidate()
    }
    
    @objc private func appLaunchedForAdjust(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.activationPolicy == .regular else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.addObserver(pid: app.processIdentifier)
            self?.adjustWindowsForBar()
        }
    }
    
    @objc private func appTerminatedForAdjust(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        removeObserver(pid: app.processIdentifier)
    }
    
    private func setupAXObservers() {
        let ourPID = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard app.processIdentifier != ourPID else { continue }
            addObserver(pid: app.processIdentifier)
        }
    }
    
    private func addObserver(pid: pid_t) {
        guard axObservers[pid] == nil else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        guard AXIsProcessTrustedWithOptions(options as CFDictionary) else { return }
        
        var observer: AXObserver?
        let refcon = Unmanaged.passUnretained(WindowManager.shared).toOpaque()
        let err = AXObserverCreate(pid, windowManagerAXCallback, &observer)
        guard err == .success, let obs = observer else { return }
        
        let appRef = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(obs, appRef, kAXWindowCreatedNotification as CFString, refcon)
        AXObserverAddNotification(obs, appRef, kAXWindowResizedNotification as CFString, refcon)
        AXObserverAddNotification(obs, appRef, kAXWindowMovedNotification as CFString, refcon)
        
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        axObservers[pid] = obs
    }
    
    private func removeObserver(pid: pid_t) {
        guard let obs = axObservers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
    }
    
    func adjustWindowsForBar() {
        guard barHeight > 0 else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        guard AXIsProcessTrustedWithOptions(options as CFDictionary) else { return }
        
        let ourPID = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard app.processIdentifier != ourPID else { continue }
            let appRef = AXUIElementCreateApplication(app.processIdentifier)
            var value: AnyObject?
            guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { continue }
            for window in windows {
                adjustAXWindow(window)
            }
        }
    }
    
    fileprivate func adjustAXWindow(_ window: AXUIElement) {
        var minimizedRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedRef)
        if let minimized = minimizedRef,
           CFGetTypeID(minimized) == CFBooleanGetTypeID(),
           CFBooleanGetValue((minimized as! CFBoolean)) {
            return
        }
        
        // Only resize windows that belong to the current Mission Control space.
        // windowSpaceCache is populated by updateWindows() from CGWindowList,
        // so it only contains windows that were visible on the current space.
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success else { return }
        
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        let title = (titleRef as? String) ?? ""
        
        let cacheKey = "\(pid):\(title)"
        if let cachedSpace = windowSpaceCache[cacheKey],
           let currentSpace = currentSpaceID,
           cachedSpace != currentSpace {
            return
        }
        
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        let posResult = AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue)
        let sizeResult = AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue)
        guard posResult == .success, sizeResult == .success,
              let posValue = posValue, let sizeValue = sizeValue else { return }
        
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        
        let windowBottom = pos.y + size.height
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        
        for screen in NSScreen.screens {
            let boundsTL = topLeftBounds(for: screen, primaryHeight: primaryHeight)
            let barTopY = boundsTL.maxY - barHeight
            
            guard pos.x < boundsTL.maxX,
                  pos.x + size.width > boundsTL.minX,
                  pos.y < boundsTL.maxY,
                  windowBottom > barTopY else { continue }
            
            // The window server draws resize cursors in a ~3-5 px border
            // outside the window frame, so we need a small safety margin.
            let buffer: CGFloat = 1
            let desiredBottom = barTopY - buffer
            let overlap = windowBottom - desiredBottom
            guard overlap > 1 else { continue }
            
            // Tall enough to shrink from the bottom?
            let newHeight = size.height - overlap
            if newHeight >= 50 {
                var newSize = size
                newSize.height = newHeight
                if let v = AXValueCreate(.cgSize, &newSize) {
                    AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, v)
                }
            } else {
                // Too short to shrink — slide the window up instead.
                var newPos = pos
                newPos.y -= overlap
                if let v = AXValueCreate(.cgPoint, &newPos) {
                    AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v)
                }
            }
            break
        }
    }
    
    private func topLeftBounds(for screen: NSScreen, primaryHeight: CGFloat) -> CGRect {
        let y = primaryHeight - screen.frame.maxY
        return CGRect(x: screen.frame.minX, y: y, width: screen.frame.width, height: screen.frame.height)
    }
    
    func focusWindow(_ window: WindowInfo) {
        guard !isRunningInPreview else { return }
        guard let app = NSRunningApplication(processIdentifier: window.pid) else { return }
        app.activate(options: .activateIgnoringOtherApps)
        
        // Try to raise the specific window via Accessibility API
        let appElement = AXUIElementCreateApplication(window.pid)
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        
        guard result == .success, let axWindows = value as? [AXUIElement] else {
            return
        }
        
        // Synthetic IDs (>= 0xFFFF0000) are minimized windows — find by title
        if window.id >= 0xFFFF0000 {
            for axWindow in axWindows {
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)
                let title = (titleRef as? String) ?? ""
                if title == window.title {
                    AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
                    return
                }
            }
            return
        }
        
        for axWindow in axWindows {
            var positionRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionRef)
            AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef)
            
            if let positionRef = positionRef, let sizeRef = sizeRef {
                var position = CGPoint.zero
                var size = CGSize.zero
                AXValueGetValue(positionRef as! AXValue, .cgPoint, &position)
                AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
                let axFrame = CGRect(origin: position, size: size)
                
                if abs(axFrame.minX - window.frame.minX) < 5 &&
                   abs(axFrame.minY - window.frame.minY) < 5 &&
                   abs(axFrame.width - window.frame.width) < 5 &&
                   abs(axFrame.height - window.frame.height) < 5 {
                    AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
                    return
                }
            }
        }
        
        // Fallback: just bring the app frontmost
        let script = """
        tell application "System Events"
            tell process "\(window.appName)"
                set frontmost to true
            end tell
        end tell
        """
        
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
        }
    }
}

private let windowManagerAXCallback: @convention(c) (AXObserver, AXUIElement, CFString, UnsafeMutableRawPointer?) -> Void = { observer, element, notification, refcon in
    guard let refcon = refcon else { return }
    let manager = Unmanaged<WindowManager>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated {
        manager.adjustAXWindow(element)
    }
}
