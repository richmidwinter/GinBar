import SwiftUI
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {
    private var activityToken: NSObjectProtocol?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent app nap so timers keep firing when backgrounded
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "GinBar bar updates"
        )
        
        // Accessory policy (no Dock icon), matching boringBar
        NSApp.setActivationPolicy(.accessory)
        
        // Hide the main SwiftUI window (not overlay windows which are borderless)
        for window in NSApp.windows {
            // Only close titled windows (SwiftUI creates these, not our overlays)
            if window.styleMask.contains(.titled) {
                window.close()
                break
            }
        }
        
        // Setup shutdown handler
        setupShutdownHandler()
    }
    
    func setupShutdownHandler() {
        // Force close all borderless overlay windows on quit
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            print("[GinBar] Terminating - closing all windows")
            for window in NSApp.windows {
                if window.styleMask.contains(.nonactivatingPanel) || window.styleMask == .borderless {
                    window.orderOut(nil)
                    window.close()
                }
            }
            // Force screen refresh
            NSScreen.screens.forEach { _ in }
        }
        
        // Also handle Cmd+Q
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 12 && event.modifierFlags.contains(.command) { // Cmd+Q
                print("[GinBar] Cmd+Q detected")
                NSApp.terminate(nil)
            }
        }
    }
}

@main
struct GinBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var state = AppState()
    
    var body: some Scene {
        WindowGroup {
            EmptyView()
        }
        .defaultSize(width: 0, height: 0)
        
        Settings {
            SettingsView().environmentObject(state)
        }
        
        MenuBarExtra("GinBar", image: "GinIcon") {
            MenuBarView().environmentObject(state)
        }
    }
}
