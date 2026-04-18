import SwiftUI
import AppKit

final class MenuWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class MenuWindowController {
    static let shared = MenuWindowController()
    
    private var window: NSWindow?
    private var monitor: Any?
    private var isHiding = false
    
    var isVisible: Bool { window?.isVisible == true }
    
    func show(relativeTo button: NSButton, applications: [URL]) {
        if isVisible { hide() }
        
        guard let screen = button.window?.screen ?? NSScreen.main else { return }
        let barHeight = NSStatusBar.system.thickness + 10
        let menuHeight = min(CGFloat(applications.count * 28) + 16 + 40, 540)
        let frame = NSRect(
            x: screen.frame.minX,
            y: screen.frame.minY + barHeight,
            width: 220,
            height: menuHeight
        )
        
        let view = ApplicationsMenuContent(applications: applications) { [weak self] url in
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            self?.hide()
        }
        
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        
        if window == nil {
            let w = MenuWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = NSWindow.Level.statusBar + 2
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = true
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            window = w
        } else {
            window?.setFrame(frame, display: true)
        }
        
        window?.contentView = hosting
        window?.makeKeyAndOrderFront(nil)
        
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }
    }
    
    func hide() {
        guard !isHiding else { return }
        isHiding = true
        if let mon = monitor {
            NSEvent.removeMonitor(mon)
            monitor = nil
        }
        window?.orderOut(nil)
        isHiding = false
    }
}

final class MenuButton: NSButton {
    var applications: [URL] = []
    private var isHovered = false {
        didSet { updateAppearance() }
    }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    
    private func setup() {
        bezelStyle = .shadowlessSquare
        isBordered = false
        image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        imagePosition = .imageOnly
        contentTintColor = .white
        target = self
        action = #selector(clicked)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
        updateAppearance()
    }
    
    override var bounds: NSRect {
        didSet {
            trackingAreas.forEach { removeTrackingArea($0) }
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways],
                owner: self,
                userInfo: nil
            ))
        }
    }
    
    @objc private func clicked() {
        if MenuWindowController.shared.isVisible {
            MenuWindowController.shared.hide()
        } else {
            MenuWindowController.shared.show(relativeTo: self, applications: applications)
        }
    }
    
    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }
    
    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }
    
    private func updateAppearance() {
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.backgroundColor = isHovered
            ? NSColor.white.withAlphaComponent(0.2).cgColor
            : NSColor.clear.cgColor
    }
}

struct ApplicationsMenu: View {
    @State private var applications: [URL] = []
    
    var body: some View {
        RepresentedButton(applications: applications)
            .frame(width: 28, height: 24)
            .onAppear {
                applications = loadApplications()
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

struct RepresentedButton: NSViewRepresentable {
    let applications: [URL]
    
    func makeNSView(context: Context) -> MenuButton {
        let button = MenuButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        button.applications = applications
        return button
    }
    
    func updateNSView(_ nsView: MenuButton, context: Context) {
        nsView.applications = applications
    }
}

struct ApplicationsMenuContent: View {
    let applications: [URL]
    let onSelect: (URL) -> Void
    @State private var hoveredURL: URL?
    @State private var searchText: String = ""
    
    private var filteredApplications: [URL] {
        if searchText.isEmpty { return applications }
        return applications.filter {
            $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredApplications, id: \.self) { url in
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
            
            Divider()
                .background(Color.white.opacity(0.2))
            
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.white.opacity(0.6))
                    .font(.system(size: 12))
                
                TextField("Search applications...", text: $searchText)
                    .font(.system(size: 13))
                    .textFieldStyle(PlainTextFieldStyle())
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(width: 220)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.4))
                .overlay(.ultraThinMaterial)
        )
    }
}
