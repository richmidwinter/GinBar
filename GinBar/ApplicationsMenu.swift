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

    func show(relativeTo button: NSButton, applications: [URL], pinnedBundleIDs: [String]) {
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

        let pinnedSet = Set(pinnedBundleIDs)
        let pinnedApps = applications.filter { url in
            if let bundleID = Bundle(url: url)?.bundleIdentifier {
                return pinnedSet.contains(bundleID)
            }
            return false
        }
        let otherApps = applications.filter { !pinnedApps.contains($0) }

        let view = ApplicationsMenuContent(
            pinnedApplications: pinnedApps,
            applications: otherApps
        ) { [weak self] url in
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
    var pinnedBundleIDs: [String] = []
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
        dismissTooltip()
        if MenuWindowController.shared.isVisible {
            MenuWindowController.shared.hide()
        } else {
            MenuWindowController.shared.show(relativeTo: self, applications: applications, pinnedBundleIDs: pinnedBundleIDs)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        scheduleTooltip()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        dismissTooltip()
    }

    // MARK: - Custom tooltip (AppKit toolTip doesn't work inside NSHostingView)

    private var tooltipWindow: NSWindow?
    private var tooltipTimer: Timer?

    private func scheduleTooltip() {
        dismissTooltip()
        tooltipTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.showTooltip()
        }
    }

    private func dismissTooltip() {
        tooltipTimer?.invalidate()
        tooltipTimer = nil
        tooltipWindow?.orderOut(nil)
        tooltipWindow = nil
    }

    private func showTooltip() {
        let text = "Applications Menu"
        let label = NSTextField(labelWithString: text)
        label.sizeToFit()
        let width = max(label.frame.width + 16, 60)
        let height: CGFloat = 24

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = .popUpMenu
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true
        container.layer?.cornerRadius = 4
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor

        label.frame = container.bounds.insetBy(dx: 8, dy: 4)
        label.textColor = .white
        label.font = NSFont.systemFont(ofSize: 11)
        label.alignment = .center
        container.addSubview(label)

        window.contentView = container

        let rectInWindow = convert(bounds, to: nil)
        if let screenRect = self.window?.convertToScreen(rectInWindow) {
            var x = screenRect.midX - width / 2
            var y = screenRect.maxY + 2

            if let screen = self.window?.screen {
                let visible = screen.visibleFrame
                x = max(visible.minX, min(x, visible.maxX - width))
                y = max(visible.minY + height, min(y, visible.maxY))
            }

            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        window.orderFront(nil)
        tooltipWindow = window
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
    @ObservedObject private var dockManager = DockManager.shared

    var body: some View {
        RepresentedButton(applications: applications, pinnedBundleIDs: dockManager.pinnedBundleIDs)
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

        var foundApps = Set<URL>()

        // Recursively enumerate each directory for .app bundles
        for directory in applicationDirectories {
            let url = URL(fileURLWithPath: directory)
            guard fileManager.fileExists(atPath: directory) else { continue }

            if let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let fileURL as URL in enumerator {
                    if fileURL.pathExtension == "app" {
                        foundApps.insert(fileURL)
                        // Don't descend into app bundles themselves
                        enumerator.skipDescendants()
                    }
                }
            }
        }

        // CoreServices contains user-facing apps (Finder, Screen Sharing, etc.)
        // alongside background services (Dock, SystemUIServer). Read Info.plist
        // to filter out background-only agents.
        let coreServicesURL = URL(fileURLWithPath: "/System/Library/CoreServices")
        if let enumerator = fileManager.enumerator(
            at: coreServicesURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                if fileURL.pathExtension == "app" {
                    enumerator.skipDescendants()

                    let infoPlistURL = fileURL.appendingPathComponent("Contents/Info.plist")
                    if let plist = NSDictionary(contentsOf: infoPlistURL) as? [String: Any] {
                        let isBackground = (plist["LSBackgroundOnly"] as? Bool) == true
                        let isUIElement  = (plist["LSUIElement"] as? Bool) == true
                        if !isBackground && !isUIElement {
                            foundApps.insert(fileURL)
                        }
                    } else {
                        foundApps.insert(fileURL)
                    }
                }
            }
        }

        return Array(foundApps).sorted {
            $0.deletingPathExtension().lastPathComponent.localizedStandardCompare(
                $1.deletingPathExtension().lastPathComponent
            ) == .orderedAscending
        }
    }
}

struct RepresentedButton: NSViewRepresentable {
    let applications: [URL]
    let pinnedBundleIDs: [String]

    func makeNSView(context: Context) -> MenuButton {
        let button = MenuButton(frame: NSRect(x: 0, y: 0, width: 28, height: 24))
        button.applications = applications
        button.pinnedBundleIDs = pinnedBundleIDs
        return button
    }

    func updateNSView(_ nsView: MenuButton, context: Context) {
        nsView.applications = applications
        nsView.pinnedBundleIDs = pinnedBundleIDs
    }
}

struct ApplicationsMenuContent: View {
    let pinnedApplications: [URL]
    let applications: [URL]
    let onSelect: (URL) -> Void
    @State private var hoveredURL: URL?
    @State private var searchText: String = ""

    private var allApplications: [URL] {
        pinnedApplications + applications
    }

    private var filteredApplications: [URL] {
        if searchText.isEmpty { return allApplications }
        return allApplications.filter {
            $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 2) {
                    if !pinnedApplications.isEmpty && searchText.isEmpty {
                        Text("Pinned")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.5))
                            .padding(.horizontal, 8)
                            .padding(.top, 4)

                        ForEach(pinnedApplications, id: \.self) { url in
                            appButton(for: url)
                        }

                        Divider()
                            .background(Color.white.opacity(0.2))
                            .padding(.vertical, 4)
                    }

                    if !applications.isEmpty && searchText.isEmpty {
                        Text("Applications")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.5))
                            .padding(.horizontal, 8)
                            .padding(.top, 4)
                    }

                    let displayedApps = searchText.isEmpty ? applications : filteredApplications

                    ForEach(displayedApps, id: \.self) { url in
                        appButton(for: url)
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

    private func appButton(for url: URL) -> some View {
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
