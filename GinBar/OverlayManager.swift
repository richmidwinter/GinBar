import Cocoa
import SwiftUI
import Combine

typealias SLSMainConnectionIDFunc = @convention(c) () -> Int32
typealias SLSCopyManagedDisplaySpacesFunc = @convention(c) (Int32) -> Unmanaged<CFArray>?
typealias SLSAddWindowsToSpacesFunc = @convention(c) (Int32, CFArray, CFArray) -> Int32
typealias SLSRemoveWindowsFromSpacesFunc = @convention(c) (Int32, CFArray, CFArray) -> Int32
typealias SLSManagedDisplaySetCurrentSpaceFunc = @convention(c) (Int32, CFString, UInt64) -> Int32
typealias SLSCopySpacesForWindowsFunc = @convention(c) (Int32, UInt64, CFArray) -> Unmanaged<CFArray>?

struct SkyLightAPIs {
    static let shared = SkyLightAPIs()
    
    let mainConnectionID: SLSMainConnectionIDFunc?
    let copyManagedDisplaySpaces: SLSCopyManagedDisplaySpacesFunc?
    let addWindowsToSpaces: SLSAddWindowsToSpacesFunc?
    let removeWindowsFromSpaces: SLSRemoveWindowsFromSpacesFunc?
    let managedDisplaySetCurrentSpace: SLSManagedDisplaySetCurrentSpaceFunc?
    let copySpacesForWindows: SLSCopySpacesForWindowsFunc?
    
    init() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW) else {
            self.mainConnectionID = nil
            self.copyManagedDisplaySpaces = nil
            self.addWindowsToSpaces = nil
            self.removeWindowsFromSpaces = nil
            self.managedDisplaySetCurrentSpace = nil
            self.copySpacesForWindows = nil
            return
        }
        self.mainConnectionID = unsafeBitCast(dlsym(handle, "SLSMainConnectionID"), to: SLSMainConnectionIDFunc.self)
        self.copyManagedDisplaySpaces = unsafeBitCast(dlsym(handle, "SLSCopyManagedDisplaySpaces"), to: SLSCopyManagedDisplaySpacesFunc.self)
        self.addWindowsToSpaces = unsafeBitCast(dlsym(handle, "SLSAddWindowsToSpaces"), to: SLSAddWindowsToSpacesFunc.self)
        self.removeWindowsFromSpaces = unsafeBitCast(dlsym(handle, "SLSRemoveWindowsFromSpaces"), to: SLSRemoveWindowsFromSpacesFunc.self)
        self.managedDisplaySetCurrentSpace = unsafeBitCast(dlsym(handle, "SLSManagedDisplaySetCurrentSpace"), to: SLSManagedDisplaySetCurrentSpaceFunc.self)
        // Try modern SLS name first, then older CGS name
        if let fn = dlsym(handle, "SLSCopySpacesForWindows") {
            self.copySpacesForWindows = unsafeBitCast(fn, to: SLSCopySpacesForWindowsFunc.self)
        } else if let fn = dlsym(handle, "CGSCopySpacesForWindows") {
            self.copySpacesForWindows = unsafeBitCast(fn, to: SLSCopySpacesForWindowsFunc.self)
        } else {
            self.copySpacesForWindows = nil
        }
    }
}

final class BarWindow: NSPanel {
    var allowBecomeKey: Bool = false
    override var canBecomeKey: Bool { allowBecomeKey }
    override var canBecomeMain: Bool { allowBecomeKey }
}

private final class BarContentView: NSView {
    // Intentionally empty: BarContentView is just a plain NSView wrapper
    // for the NSHostingView so we can own the full view hierarchy.
}

private final class BarHostingView<Content: View>: NSHostingView<Content> {
    private var cursorTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = cursorTrackingArea {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        cursorTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        // Explicitly invalidate cursor rects so AppKit re-evaluates them
        // for this (non-key) window on every mouse move.
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        // Cover the entire hosting view with an arrow cursor rect.
        // This gives AppKit a proper cursor rect to use when it evaluates
        // the bar window, which should win over the window below.
        addCursorRect(bounds, cursor: .arrow)
    }
}

class OverlayManager {

    private var barWindows: [UInt64: NSWindow] = [:]
    private var spaceScreenMap: [UInt64: NSScreen] = [:]
    private var spaceCurrentSpaceMap: [UInt64: UInt64] = [:]
    private var spaceDisplayUUIDMap: [UInt64: String] = [:]
    private var popupWindows: [NSScreen: NSWindow] = [:]
    private weak var state: AppState?
    private var cancellables = Set<AnyCancellable>()
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

    private var spaceCheckTimer: Timer?
    private var lastKnownSpaceID: UInt64?
    
    init(state: AppState) {
        self.state = state
        
        guard !isRunningInPreview else { return }

        WindowManager.shared.onSwitchToSpace = { [weak self] spaceID in
            self?.switchToSpace(spaceID)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(chipFrameUpdated(_:)),
            name: .appChipHovered,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateScreens),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        
        state.$isEnabled
            .sink { [weak self] _ in
                self?.updateVisibility()
            }
            .store(in: &cancellables)

        updateScreens()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            if self.barWindows.isEmpty {
                self.updateScreens()
            }
            WindowManager.shared.startAdjustingWindowsForBar(barHeight: NSStatusBar.system.thickness + 10)
        }
        
        // activeSpaceDidChangeNotification is not delivered to background
        // panel apps, so we poll SkyLight directly to detect space changes.
        spaceCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.pollForSpaceChange()
        }
    }
    
    @objc private func appWillTerminate() {
        cleanup()
    }

    @objc func updateScreens() {
        refreshSpaceBars()
        
        for screen in NSScreen.screens {
            if popupWindows[screen] == nil {
                createPopupWindow(for: screen)
            }
        }
    }
    
    private func pollForSpaceChange() {
        guard let copyFn = sls.copyManagedDisplaySpaces,
              let displays = copyFn(sls.mainConnectionID?() ?? 0)?.takeRetainedValue() as? [NSDictionary] else { return }
        for display in displays {
            guard let currentSpace = (display["Current Space"] as? NSDictionary)?["id64"] as? UInt64 else { continue }
            if currentSpace != lastKnownSpaceID {
                lastKnownSpaceID = currentSpace
                spaceDidChange()
            }
        }
    }
    
    @objc private func spaceDidChange() {
        refreshSpaceBars()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self else { return }
            
            if let copyFn = self.sls.copyManagedDisplaySpaces,
               let displays = copyFn(self.sls.mainConnectionID?() ?? 0)?.takeRetainedValue() as? [NSDictionary] {
                for display in displays {
                    guard let currentSpace = (display["Current Space"] as? NSDictionary)?["id64"] as? UInt64 else { continue }
                    WindowManager.shared.currentSpaceID = currentSpace
                    DockManager.shared.spaceApps[currentSpace] = nil
                    DockManager.shared.updateAppsWithWindows()
                    
                    if let window = self.barWindows[currentSpace] as? BarWindow {
                        window.allowBecomeKey = true
                        NSApp.activate(ignoringOtherApps: true)
                        window.makeKeyAndOrderFront(nil)
                        window.allowBecomeKey = false
                    }
                }
            }
        }
    }

    private func updateVisibility() {
        guard let state = state else { return }
        for (_, window) in barWindows {
            if state.isEnabled {
                window.orderFront(nil)
            } else {
                window.orderOut(nil)
            }
        }
        for (_, window) in popupWindows {
            if !state.isEnabled {
                window.orderOut(nil)
                window.ignoresMouseEvents = true
            }
        }
    }

    private func refreshSpaceBars() {
        guard let copyFn = sls.copyManagedDisplaySpaces,
              let displays = copyFn(sls.mainConnectionID?() ?? 0)?.takeRetainedValue() as? [NSDictionary] else { return }
        
        var newSpaceScreenMap: [UInt64: NSScreen] = [:]
        var newSpaceCurrentSpaceMap: [UInt64: UInt64] = [:]
        var newSpaceDisplayUUIDMap: [UInt64: String] = [:]
        var currentSpaceIDs = Set<UInt64>()
        
        for display in displays {
            guard let spacesArray = display["Spaces"] as? [NSDictionary] else { continue }
            let screen = screenForDisplay(display)
            let currentSpaceID = (display["Current Space"] as? NSDictionary)?["id64"] as? UInt64
            let displayUUID = display["Display Identifier"] as? String
            
            for space in spacesArray {
                if let id64 = space["id64"] as? UInt64 {
                    currentSpaceIDs.insert(id64)
                    newSpaceScreenMap[id64] = screen
                    newSpaceCurrentSpaceMap[id64] = currentSpaceID
                    if let uuid = displayUUID {
                        newSpaceDisplayUUIDMap[id64] = uuid
                    }
                }
            }
            // Set initial current space if not yet known
            if WindowManager.shared.currentSpaceID == nil, let spaceID = currentSpaceID {
                WindowManager.shared.currentSpaceID = spaceID
            }
        }
        
        spaceScreenMap = newSpaceScreenMap
        spaceCurrentSpaceMap = newSpaceCurrentSpaceMap
        spaceDisplayUUIDMap = newSpaceDisplayUUIDMap
        
        // Remove bars for spaces that no longer exist
        for (spaceID, window) in barWindows {
            if !currentSpaceIDs.contains(spaceID) {
                window.orderOut(nil)
                window.close()
                barWindows.removeValue(forKey: spaceID)
            }
        }
        
        // Create bars sequentially to avoid overwhelming SwiftUI's graph engine
        let spacesToCreate = currentSpaceIDs.filter { barWindows[$0] == nil }.sorted()
        createNextBar(from: spacesToCreate, index: 0)
    }
    
    private func createNextBar(from spaces: [UInt64], index: Int) {
        guard index < spaces.count else {
            updateVisibility()
            return
        }
        
        let spaceID = spaces[index]
        if let screen = spaceScreenMap[spaceID] {
            createBarWindow(for: spaceID, screen: screen)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.createNextBar(from: spaces, index: index + 1)
        }
    }
    
    private func screenForDisplay(_ display: NSDictionary) -> NSScreen? {
        guard let displayUUID = display["Display Identifier"] as? String else { return NSScreen.screens.first }
        
        for screen in NSScreen.screens {
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let displayID = screenNumber.uint32Value
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { continue }
            let uuidString = CFUUIDCreateString(nil, uuid) as String
            if uuidString == displayUUID {
                return screen
            }
        }
        return NSScreen.screens.first
    }

    private func createBarWindow(for spaceID: UInt64, screen: NSScreen) {
        let barHeight = NSStatusBar.system.thickness + 10
        
        let frame = NSRect(
            x: screen.frame.origin.x,
            y: screen.frame.minY,
            width: screen.frame.width,
            height: barHeight
        )

        guard let state = state else { return }
        let view = BarView(barHeight: barHeight, spaceID: spaceID)
            .environmentObject(state)
        let hosting = BarHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: frame.width, height: frame.height)
        hosting.autoresizingMask = [.width, .height]
        
        let contentView = BarContentView()
        contentView.frame = NSRect(x: 0, y: 0, width: frame.width, height: frame.height)
        contentView.addSubview(hosting)

        let window = BarWindow(
            contentRect: frame,
            styleMask: .nonactivatingPanel,
            backing: .buffered,
            defer: false
        )

        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = false
        window.animationBehavior = .documentWindow
        window.acceptsMouseMovedEvents = true
        window.ignoresMouseEvents = false
        window.becomesKeyOnlyIfNeeded = true
        window.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.contentView = contentView

        barWindows[spaceID] = window
        
        // For the current space, show it immediately.
        guard let currentSpace = spaceCurrentSpaceMap[spaceID], currentSpace != spaceID else {
            window.orderFront(nil)
            return
        }
        
        // Assign to target space immediately while window is still fresh.
        let windowNumber = window.windowNumber
        if windowNumber > 0, let cid = self.sls.mainConnectionID?() {
            var windowIDValue = Int32(windowNumber)
            var targetSpaceValue = Int64(spaceID)
            var currentSpaceValue = Int64(currentSpace)
            
            if let windowNum = CFNumberCreate(nil, .sInt32Type, &windowIDValue),
               let targetNum = CFNumberCreate(nil, .sInt64Type, &targetSpaceValue),
               let currentNum = CFNumberCreate(nil, .sInt64Type, &currentSpaceValue) {
                let windowArray = [windowNum] as CFArray
                let targetSpaceArray = [targetNum] as CFArray
                let currentSpaceArray = [currentNum] as CFArray
                
                if let addFn = self.sls.addWindowsToSpaces {
                    let addResult = addFn(cid, windowArray, targetSpaceArray)
                    NSLog("[GinBar] SLSAddWindowsToSpaces space=%llu win=%d result=%d", spaceID, windowNumber, addResult)
                    
                    if addResult == 0, let removeFn = self.sls.removeWindowsFromSpaces {
                        let removeResult = removeFn(cid, windowArray, currentSpaceArray)
                        NSLog("[GinBar] SLSRemoveWindowsFromSpaces space=%llu current=%llu result=%d", spaceID, currentSpace, removeResult)
                    }
                }
            }
        }
        
        // Non-current space: hide the window. It will be shown via makeKeyAndOrderFront:
        // when the user switches to this space.
        window.orderOut(nil)
    }
    
    private func createPopupWindow(for screen: NSScreen) {
        let barHeight = NSStatusBar.system.thickness + 10
        let popupHeight: CGFloat = 140
        
        let frame = NSRect(
            x: screen.frame.origin.x,
            y: screen.frame.minY + barHeight - 4,
            width: screen.frame.width,
            height: popupHeight + 4
        )

        let view = WindowPreviewPopup(windowManager: WindowManager.shared)
            .frame(height: popupHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: frame.width, height: frame.height)

        let window = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        window.level = NSWindow.Level.statusBar + 2
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.contentView = hosting

        popupWindows[screen] = window
        
        WindowManager.shared.$selectedApp
            .receive(on: DispatchQueue.main)
            .sink { [weak window] app in
                guard let window = window else { return }
                if app != nil {
                    window.ignoresMouseEvents = false
                    window.orderFront(nil)
                } else {
                    window.ignoresMouseEvents = true
                    window.orderOut(nil)
                }
            }
            .store(in: &cancellables)
    }
    
    @objc private func chipFrameUpdated(_ notification: Notification) {
        guard let spaceID = notification.userInfo?["spaceID"] as? UInt64,
              let localMinX = notification.userInfo?["localMinX"] as? CGFloat,
              let barWindow = barWindows[spaceID] else { return }
        let chipMinX = barWindow.frame.minX + localMinX
        
        let barHeight = NSStatusBar.system.thickness + 10
        let popupHeight: CGFloat = 140
        
        for (screen, window) in popupWindows {
            guard chipMinX >= screen.frame.minX && chipMinX < screen.frame.maxX else { continue }
            let popupWidth = max(200, screen.frame.maxX - chipMinX)
            let newFrame = NSRect(
                x: chipMinX,
                y: screen.frame.minY + barHeight - 4,
                width: popupWidth,
                height: popupHeight + 4
            )
            window.setFrame(newFrame, display: true)
            if let hosting = window.contentView {
                hosting.frame = NSRect(x: 0, y: 0, width: popupWidth, height: popupHeight + 4)
            }
            break
        }
    }
    
    func switchToSpace(_ spaceID: UInt64) {
        if barWindows[spaceID] == nil {
            if let screen = spaceScreenMap[spaceID] ?? NSScreen.screens.first {
                createBarWindow(for: spaceID, screen: screen)
            }
        }
        
        guard let window = barWindows[spaceID] as? BarWindow else { return }
        
        // Temporarily allow the bar to become key, matching boringBar's allowBecomeKey trick.
        window.allowBecomeKey = true
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.allowBecomeKey = false
    }
    
    func cleanup() {
        cancellables.removeAll()
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            for (_, window) in self.barWindows {
                window.orderOut(nil)
                window.close()
            }
            for (_, window) in self.popupWindows {
                window.orderOut(nil)
                window.close()
            }
            self.barWindows.removeAll()
            self.popupWindows.removeAll()
        }
    }
}
