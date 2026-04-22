import SwiftUI
import AppKit

// MARK: - Data Model

struct AppMenuEntry: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let isFolder: Bool
    let children: [URL]
}

// MARK: - Windows

final class MenuWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class MenuWindowController {
    static let shared = MenuWindowController()

    private var window: NSWindow?
    private var submenuWindow: NSWindow?
    private var monitor: Any?
    private var isHiding = false

    var isVisible: Bool { window?.isVisible == true }

    func show(relativeTo button: NSButton, applications: [AppMenuEntry], pinnedBundleIDs: [String]) {
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
        let pinnedApps: [AppMenuEntry] = applications.compactMap { entry in
            guard !entry.isFolder,
                  let bundleID = Bundle(url: entry.url)?.bundleIdentifier,
                  pinnedSet.contains(bundleID) else { return nil }
            return entry
        }
        let otherApps = applications.filter { entry in
            !pinnedApps.contains(where: { $0.id == entry.id })
        }

        let view = ApplicationsMenuContent(
            pinnedApplications: pinnedApps.map(\.url),
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

    private var submenuHideTimer: Timer?
    var submenuFrame: NSRect? { submenuWindow?.frame }

    func showSubmenu(for entry: AppMenuEntry, at screenRect: NSRect) {
        cancelSubmenuHideTimer()
        hideSubmenu()

        let apps = entry.children
        let width: CGFloat = 200
        let rowHeight: CGFloat = 28
        let menuHeight = min(CGFloat(apps.count) * rowHeight + 16, 400)

        var x = screenRect.maxX - 2 // slight overlap so mouse path is continuous
        var y = screenRect.maxY - menuHeight

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            if x + width > visible.maxX {
                x = screenRect.minX - width + 2
            }
            if y < visible.minY {
                y = visible.minY
            }
        }

        let frame = NSRect(x: x, y: y, width: width, height: menuHeight)

        let view = SubmenuContent(apps: apps) { [weak self] url in
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            self?.hide()
        }

        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: frame.size)

        let wrapper = SubmenuTrackingView(frame: hosting.bounds)
        wrapper.addSubview(hosting)
        hosting.autoresizingMask = [.width, .height]

        let window = MenuWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level.statusBar + 2
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.contentView = wrapper
        window.orderFront(nil)

        submenuWindow = window
    }

    func scheduleSubmenuHide() {
        cancelSubmenuHideTimer()
        submenuHideTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            let mouseLoc = NSEvent.mouseLocation
            if let frame = self.submenuFrame, NSPointInRect(mouseLoc, frame) {
                // mouse is over submenu — don't hide, it'll be re-scheduled on exit
                return
            }
            self.hideSubmenu()
        }
    }

    func cancelSubmenuHideTimer() {
        submenuHideTimer?.invalidate()
        submenuHideTimer = nil
    }

    func hideSubmenu() {
        cancelSubmenuHideTimer()
        submenuWindow?.orderOut(nil)
        submenuWindow = nil
    }

    func hide() {
        guard !isHiding else { return }
        isHiding = true
        hideSubmenu()
        if let mon = monitor {
            NSEvent.removeMonitor(mon)
            monitor = nil
        }
        window?.orderOut(nil)
        isHiding = false
    }
}

// MARK: - Menu Button

final class MenuButton: NSButton {
    var applications: [AppMenuEntry] = []
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

    // MARK: - Custom tooltip

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

// MARK: - Applications Menu

struct ApplicationsMenu: View {
    @State private var applications: [AppMenuEntry] = []
    @ObservedObject private var dockManager = DockManager.shared

    var body: some View {
        RepresentedButton(applications: applications, pinnedBundleIDs: dockManager.pinnedBundleIDs)
            .frame(width: 28, height: 24)
            .onAppear {
                applications = loadApplications()
            }
    }

    private func loadApplications() -> [AppMenuEntry] {
        let fileManager = FileManager.default
        let applicationDirectories = [
            "/Applications",
            "/System/Applications",
            NSHomeDirectory() + "/Applications"
        ]

        var entries: [AppMenuEntry] = []
        var seenURLs = Set<URL>()

        for directory in applicationDirectories {
            let dirURL = URL(fileURLWithPath: directory)
            guard fileManager.fileExists(atPath: directory),
                  let contents = try? fileManager.contentsOfDirectory(
                      at: dirURL,
                      includingPropertiesForKeys: [.isDirectoryKey],
                      options: [.skipsHiddenFiles]
                  ) else { continue }

            let isSystemDir = directory == "/System/Applications"

            for url in contents {
                if url.lastPathComponent.hasPrefix(".") { continue }

                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }

                if url.pathExtension == "app" {
                    if seenURLs.insert(url).inserted {
                        entries.append(AppMenuEntry(url: url, isFolder: false, children: []))
                    }
                } else if isDir.boolValue {
                    let appsInDir = findApps(in: url, fileManager: fileManager)
                    let newApps = appsInDir.filter { seenURLs.insert($0).inserted }

                    if isSystemDir && !newApps.isEmpty {
                        // System subdirectories (e.g. Utilities) become folder entries
                        entries.append(AppMenuEntry(url: url, isFolder: true, children: newApps))
                    } else {
                        // User subdirectories are flattened — apps appear individually
                        for appURL in newApps {
                            entries.append(AppMenuEntry(url: appURL, isFolder: false, children: []))
                        }
                    }
                }
            }
        }

        // CoreServices contains user-facing apps alongside background services.
        let coreServicesURL = URL(fileURLWithPath: "/System/Library/CoreServices")
        if let contents = try? fileManager.contentsOfDirectory(
            at: coreServicesURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for url in contents {
                if url.pathExtension == "app" {
                    let infoPlistURL = url.appendingPathComponent("Contents/Info.plist")
                    if let plist = NSDictionary(contentsOf: infoPlistURL) as? [String: Any] {
                        let isBackground = (plist["LSBackgroundOnly"] as? Bool) == true
                        let isUIElement  = (plist["LSUIElement"] as? Bool) == true
                        if isBackground || isUIElement { continue }
                    }
                    if seenURLs.insert(url).inserted {
                        entries.append(AppMenuEntry(url: url, isFolder: false, children: []))
                    }
                }
            }
        }

        // Sort folders and apps together alphabetically by display name
        return entries.sorted {
            let name0 = $0.isFolder
                ? $0.url.lastPathComponent
                : $0.url.deletingPathExtension().lastPathComponent
            let name1 = $1.isFolder
                ? $1.url.lastPathComponent
                : $1.url.deletingPathExtension().lastPathComponent
            return name0.localizedStandardCompare(name1) == .orderedAscending
        }
    }

    private func findApps(in directory: URL, fileManager: FileManager) -> [URL] {
        var apps: [URL] = []
        if let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                if fileURL.pathExtension == "app" {
                    apps.append(fileURL)
                    enumerator.skipDescendants()
                }
            }
        }
        return apps.sorted {
            $0.deletingPathExtension().lastPathComponent.localizedStandardCompare(
                $1.deletingPathExtension().lastPathComponent
            ) == .orderedAscending
        }
    }
}

struct RepresentedButton: NSViewRepresentable {
    let applications: [AppMenuEntry]
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

// MARK: - Menu Content

struct ApplicationsMenuContent: View {
    let pinnedApplications: [URL]
    let applications: [AppMenuEntry]
    let onSelect: (URL) -> Void
    @State private var hoveredURL: URL?
    @State private var searchText: String = ""

    private var allAppURLs: [URL] {
        pinnedApplications + applications.flatMap { entry in
            entry.isFolder ? entry.children : [entry.url]
        }
    }

    private var filteredApplications: [URL] {
        if searchText.isEmpty { return allAppURLs }
        return allAppURLs.filter {
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

                    if searchText.isEmpty {
                        ForEach(applications) { entry in
                            if entry.isFolder {
                                FolderMenuRow(entry: entry)
                            } else {
                                appButton(for: entry.url)
                            }
                        }
                    } else {
                        ForEach(filteredApplications, id: \.self) { url in
                            appButton(for: url)
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

// MARK: - Folder Row (AppKit for reliable hover + submenu)

final class FolderRowView: NSView {
    override var intrinsicContentSize: NSSize {
        return NSSize(width: 220, height: 28)
    }
}

final class SubmenuTrackingView: NSView {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        MenuWindowController.shared.cancelSubmenuHideTimer()
    }

    override func mouseExited(with event: NSEvent) {
        MenuWindowController.shared.scheduleSubmenuHide()
    }
}

struct FolderMenuRow: NSViewRepresentable {
    let entry: AppMenuEntry

    func makeNSView(context: Context) -> NSView {
        let container = FolderRowView(frame: NSRect(x: 0, y: 0, width: 220, height: 28))
        container.wantsLayer = true

        // Folder icon
        let iconView = NSImageView(frame: NSRect(x: 8, y: 6, width: 16, height: 16))
        if let image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil) {
            image.isTemplate = true
            iconView.image = image
            iconView.contentTintColor = .white
        }
        container.addSubview(iconView)

        // Label
        let label = NSTextField(frame: NSRect(x: 32, y: 5, width: 160, height: 18))
        label.stringValue = entry.url.lastPathComponent
        label.isEditable = false
        label.isBordered = false
        label.backgroundColor = .clear
        label.textColor = .white
        label.font = NSFont.systemFont(ofSize: 13)
        container.addSubview(label)

        // Chevron
        let chevronView = NSImageView(frame: NSRect(x: 196, y: 6, width: 16, height: 16))
        if let image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) {
            image.isTemplate = true
            chevronView.image = image
            chevronView.contentTintColor = .white
        }
        container.addSubview(chevronView)

        // Tracking area
        let trackingArea = NSTrackingArea(
            rect: container.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: context.coordinator,
            userInfo: nil
        )
        container.addTrackingArea(trackingArea)
        context.coordinator.container = container
        context.coordinator.entry = entry

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.entry = entry
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(entry: entry)
    }

    class Coordinator: NSResponder {
        var entry: AppMenuEntry
        weak var container: NSView?

        init(entry: AppMenuEntry) {
            self.entry = entry
            super.init()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func mouseEntered(with event: NSEvent) {
            MenuWindowController.shared.cancelSubmenuHideTimer()
            if let container = container {
                container.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
                let rectInWindow = container.convert(container.bounds, to: nil)
                if let screenRect = container.window?.convertToScreen(rectInWindow) {
                    MenuWindowController.shared.showSubmenu(for: entry, at: screenRect)
                }
            }
        }

        override func mouseExited(with event: NSEvent) {
            if let container = container {
                container.layer?.backgroundColor = NSColor.clear.cgColor
            }
            MenuWindowController.shared.scheduleSubmenuHide()
        }
    }
}

// MARK: - Submenu Content

struct SubmenuContent: View {
    let apps: [URL]
    let onSelect: (URL) -> Void
    @State private var hoveredURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(apps, id: \.self) { url in
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
        }
        .frame(width: 200)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.4))
                .overlay(.ultraThinMaterial)
        )
    }
}
