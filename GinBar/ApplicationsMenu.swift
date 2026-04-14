import SwiftUI
import AppKit

// Menu target singleton
@objc class MenuActionTarget: NSObject {
    @objc static let shared = MenuActionTarget()
    
    @objc func openApplication(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

struct ApplicationsMenu: View {
    @State private var isHovering = false
    @State private var applications: [URL] = []
    @State private var menuWindow: NSWindow?
    
    var body: some View {
        Button(action: {
            showMenu()
        }) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 14))
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(isHovering ? Color.white.opacity(0.2) : Color.clear)
                .cornerRadius(4)
        }
        .buttonStyle(PlainButtonStyle())
        .frame(width: 24)
        .onHover { hovering in
            isHovering = hovering
        }
        .onAppear {
            applications = loadApplications()
        }
    }
    
    private func showMenu() {
        // If menu is already showing, close it (toggle behavior)
        if let window = menuWindow, window.isVisible {
            window.close()
            menuWindow = nil
            return
        }
        
        // Create a new menu window
        let menuView = ApplicationsMenuContent(applications: applications) { url in
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            self.menuWindow?.close()
        }
        
        let hostingView = NSHostingView(rootView: menuView)
        let menuHeight = min(CGFloat(applications.count * 28) + 16, 500)
        hostingView.frame = NSRect(x: 0, y: 0, width: 220, height: menuHeight)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: menuHeight),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        
        window.contentView = hostingView
        window.level = NSWindow.Level.statusBar + 2
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        
        // Position at bottom left of screen, above the bar
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let barHeight: CGFloat = 22
            let screenHeight = screen.frame.height
            let maxMenuHeight = screenHeight / 2 // Half screen height max
            let actualMenuHeight = min(menuHeight, maxMenuHeight)
            
            let xPos = screen.frame.minX
            // Position menu so its bottom edge is just above the bar
            // yPos is the bottom of the window
            let yPos = screen.frame.minY + barHeight
            
            window.setFrame(NSRect(x: xPos, y: yPos, width: 220, height: actualMenuHeight), display: true)
        }
        
        window.makeKeyAndOrderFront(nil)
        menuWindow = window
        
        // Close when clicking outside
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak window] event in
            guard let win = window else { return }
            win.close()
            // Menu window will be nil'd out in the window's deinit or when toggled
        }
    }
    
    private func loadApplications() -> [URL] {
        let fileManager = FileManager.default
        let applicationDirectories = [
            "/Applications",
            "/System/Applications",
            NSHomeDirectory() + "/Applications"
        ]
        
        var foundApps: [URL] = []
        
        for directory in applicationDirectories {
            guard let urls = try? fileManager.contentsOfDirectory(
                at: URL(fileURLWithPath: directory),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            
            for url in urls where url.pathExtension == "app" {
                foundApps.append(url)
            }
        }
        
        return foundApps.sorted {
            $0.deletingPathExtension().lastPathComponent <
            $1.deletingPathExtension().lastPathComponent
        }
    }
}

struct ApplicationsMenuContent: View {
    let applications: [URL]
    let onSelect: (URL) -> Void
    @State private var hoveredURL: URL?
    
    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(applications, id: \.self) { url in
                    Button(action: {
                        onSelect(url)
                    }) {
                        HStack(spacing: 8) {
                            let icon = NSWorkspace.shared.icon(forFile: url.path)
                            Image(nsImage: icon)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 16, height: 16)
                            
                            Text(url.deletingPathExtension().lastPathComponent)
                                .font(.system(size: 13))
                                .foregroundColor(.white)
                            
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(hoveredURL == url ? Color.white.opacity(0.15) : Color.clear)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .onHover { hovering in
                        hoveredURL = hovering ? url : nil
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.85))
                .overlay(.ultraThinMaterial)
        )
    }
}
