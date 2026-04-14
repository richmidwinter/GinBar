import Cocoa
import Combine
import ScreenCaptureKit

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
    
    private var timer: Timer?
    private var hidePopupTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    
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
        updateWindows()
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
            
            let info = WindowInfo(
                id: windowNumber,
                pid: ownerPID,
                appName: ownerName,
                title: title,
                frame: frame,
                isOnScreen: true,
                layer: layer,
                alpha: alpha
            )
            
            newWindows.append(info)
        }
        
        self.windows = newWindows.sorted { $0.layer < $1.layer }
    }
    
    func windows(for app: NSRunningApplication) -> [WindowInfo] {
        windows.filter { $0.pid == app.processIdentifier && $0.isOnScreen }
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
        
        if let cached = thumbnails[windowID] {
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
            let config = SCStreamConfiguration()
            config.width = 320
            config.height = 200
            config.scalesToFit = true
            config.backgroundColor = .clear
            
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            
            let nsImage = NSImage(cgImage: image, size: NSSize(width: 160, height: 100))
            
            await MainActor.run {
                self.thumbnails[windowID] = nsImage
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
    
    func focusWindow(_ window: WindowInfo) {
        guard !isRunningInPreview else { return }
        guard let app = NSRunningApplication(processIdentifier: window.pid) else { return }
        app.activate()
        
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
