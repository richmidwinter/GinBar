import Cocoa
import SwiftUI
import Combine

class OverlayManager {

    private var barWindows: [NSScreen: NSWindow] = [:]
    private var popupWindows: [NSScreen: NSWindow] = [:]
    private weak var state: AppState?
    private var cancellables = Set<AnyCancellable>()
    
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

    init(state: AppState) {
        self.state = state
        
        guard !isRunningInPreview else { return }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateScreens),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        
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

        state.$isEnabled
            .sink { [weak self] _ in
                self?.updateVisibility()
            }
            .store(in: &cancellables)

        updateScreens()
        updateVisibility()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            if self.barWindows.isEmpty {
                self.updateScreens()
                self.updateVisibility()
            }
            WindowManager.shared.startAdjustingWindowsForBar(barHeight: NSStatusBar.system.thickness + 4)
        }
    }
    
    @objc private func appWillTerminate() {
        cleanup()
    }

    @objc func updateScreens() {
        for screen in NSScreen.screens {
            if barWindows[screen] == nil {
                createBarWindow(for: screen)
                createPopupWindow(for: screen)
            }
        }
        updateVisibility()
    }

    private func updateVisibility() {
        guard let state = state else { return }
        for window in barWindows.values {
            if state.isEnabled {
                window.orderFront(nil)
            } else {
                window.orderOut(nil)
            }
        }
        for window in popupWindows.values {
            if !state.isEnabled {
                window.orderOut(nil)
                window.ignoresMouseEvents = true
            }
        }
    }

    private func createBarWindow(for screen: NSScreen) {
        let barHeight = NSStatusBar.system.thickness + 4
        
        let frame = NSRect(
            x: screen.frame.origin.x,
            y: screen.frame.minY,
            width: screen.frame.width,
            height: barHeight
        )

        guard let state = state else { return }
        let view = BarView(barHeight: barHeight)
            .environmentObject(state)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: frame.width, height: frame.height)

        let window = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        window.level = NSWindow.Level.statusBar + 1
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)

        barWindows[screen] = window
    }
    
    private func createPopupWindow(for screen: NSScreen) {
        let barHeight = NSStatusBar.system.thickness + 4
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
        guard let screenMinX = notification.userInfo?["screenMinX"] as? CGFloat,
              let localMinX = notification.userInfo?["localMinX"] as? CGFloat else { return }
        let chipMinX = screenMinX + localMinX
        
        let barHeight = NSStatusBar.system.thickness + 4
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
