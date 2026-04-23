import SwiftUI
import Combine

struct BarView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var dockManager = DockManager.shared
    @ObservedObject private var windowManager = WindowManager.shared
    let barHeight: CGFloat
    let spaceID: UInt64

    /// Lightweight pulse to force re-evaluation when the bar becomes visible.
    /// SwiftUI in hidden NSPanels can miss @Published updates, so this
    /// ensures the bar always renders the latest spaceApps cache.
    @State private var refreshTick = 0

    @State private var draggedPinnedBundleID: String?

    var body: some View {
        let _ = refreshTick
        let apps = dockManager.spaceApps[spaceID] ?? []
        let pinnedApps = apps.filter { $0.isPinned }
        let regularApps = apps.filter { !$0.isPinned }

        HStack(spacing: 4) {
            ApplicationsMenu()
                .frame(width: 28)

            Divider()
                .background(Color.white.opacity(0.3))
                .padding(.horizontal, 4)

            // Pinned apps: icon only, no names or counts
            if !pinnedApps.isEmpty {
                HStack(spacing: 0) {
                    PinnedDropZone(
                        index: 0,
                        draggedBundleID: $draggedPinnedBundleID,
                        dockManager: dockManager,
                        onReordered: { refreshTick += 1 }
                    )

                    ForEach(Array(pinnedApps.enumerated()), id: \.element.id) { index, app in
                        PinnedAppIconView(
                            app: app,
                            dockManager: dockManager
                        )
                        .onDrag {
                            if let bundleID = app.bundleIdentifier {
                                draggedPinnedBundleID = bundleID
                                return NSItemProvider(object: bundleID as NSString)
                            }
                            return NSItemProvider()
                        }
                        .onTapGesture {
                            dockManager.activateApp(app)
                        }

                        PinnedDropZone(
                            index: index + 1,
                            draggedBundleID: $draggedPinnedBundleID,
                            dockManager: dockManager,
                            onReordered: { refreshTick += 1 }
                        )
                    }
                }
            }

            // Separator between pinned and regular apps
            if !pinnedApps.isEmpty && !regularApps.isEmpty {
                Divider()
                    .background(Color.white.opacity(0.3))
                    .padding(.horizontal, 4)
            }

            // Regular apps: icon + name + window count
            ForEach(regularApps) { app in
                AppItemView(
                    app: app,
                    windowManager: windowManager,
                    dockManager: dockManager,
                    spaceID: spaceID
                )
                .onTapGesture {
                    dockManager.activateApp(app)
                }
            }

            Spacer()

            SpacesMenu(spaceID: spaceID)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: barHeight, alignment: .leading)
        .background(
            Color.black.opacity(0.4)
                .overlay(.ultraThinMaterial)
        )
        .onReceive(Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()) { _ in
            refreshTick += 1
        }
    }
}

struct PinnedAppIconView: View {
    let app: BarAppItem
    @ObservedObject var dockManager: DockManager

    var body: some View {
        PinnedAppIconContainer(app: app)
            .frame(width: 28, height: 24)
            .onTapGesture {
                dockManager.activateApp(app)
            }
            .contextMenu {
                if app.isPinned {
                    Button("Unpin from Bar") {
                        if let bundleID = app.bundleIdentifier {
                            dockManager.unpinApp(bundleID: bundleID)
                        }
                    }
                } else {
                    Button("Pin to Bar") {
                        if let bundleID = app.bundleIdentifier {
                            dockManager.pinApp(bundleID: bundleID, name: app.name, url: app.url ?? URL(fileURLWithPath: ""))
                        }
                    }
                }
                Divider()
                Button("Close") {
                    dockManager.closeApp(app)
                }
            }
    }
}

/// AppKit-native container for pinned app icons.
/// Uses a custom NSView with a centered 16×16 NSImageView so the icon size
/// is constrained, and sets toolTip on both the container and the parent
/// NSHostingView to work around SwiftUI's event interception.
struct PinnedAppIconContainer: NSViewRepresentable {
    let app: BarAppItem

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 28, height: 24))
        container.wantsLayer = true
        container.layer?.cornerRadius = 4

        // 16×16 image view centered in the 28×24 container
        let imageView = NSImageView(frame: NSRect(x: 6, y: 4, width: 16, height: 16))
        imageView.image = app.icon
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.isEditable = false
        container.addSubview(imageView)

        let trackingArea = NSTrackingArea(
            rect: container.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: context.coordinator,
            userInfo: nil
        )
        container.addTrackingArea(trackingArea)
        context.coordinator.setContainerView(container)

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let imageView = nsView.subviews.first as? NSImageView {
            imageView.image = app.icon
        }
        context.coordinator.app = app
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(app: app)
    }

    class Coordinator: NSResponder {
        var app: BarAppItem
        private weak var containerView: NSView?
        private var tooltipWindow: NSWindow?
        private var tooltipTimer: Timer?

        init(app: BarAppItem) {
            self.app = app
            super.init()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func setContainerView(_ view: NSView) {
            self.containerView = view
        }

        override func mouseEntered(with event: NSEvent) {
            guard let container = containerView else { return }
            container.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
            scheduleTooltip()
        }

        override func mouseExited(with event: NSEvent) {
            guard let container = containerView else { return }
            container.layer?.backgroundColor = NSColor.clear.cgColor
            dismissTooltip()
        }

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
            guard let view = containerView else { return }

            let label = NSTextField(labelWithString: app.name)
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

            let containerView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
            containerView.wantsLayer = true
            containerView.layer?.cornerRadius = 4
            containerView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor

            label.frame = containerView.bounds.insetBy(dx: 8, dy: 4)
            label.textColor = .white
            label.font = NSFont.systemFont(ofSize: 11)
            label.alignment = .center
            containerView.addSubview(label)

            window.contentView = containerView

            // Position just above the icon, in screen coordinates
            let rectInWindow = view.convert(view.bounds, to: nil)
            if let screenRect = view.window?.convertToScreen(rectInWindow) {
                var x = screenRect.midX - width / 2
                var y = screenRect.maxY + 4

                // Keep on-screen
                if let screen = view.window?.screen {
                    let visible = screen.visibleFrame
                    x = max(visible.minX, min(x, visible.maxX - width))
                    y = max(visible.minY + height, min(y, visible.maxY))
                }

                window.setFrameOrigin(NSPoint(x: x, y: y))
            }

            window.orderFront(nil)
            tooltipWindow = window
        }
    }
}

// MARK: - Drag-and-drop drop zone for pinned app reordering

struct PinnedDropZone: View {
    let index: Int
    @Binding var draggedBundleID: String?
    let dockManager: DockManager
    let onReordered: () -> Void

    @State private var isTargeted = false

    var body: some View {
        ZStack {
            Color.clear
            Rectangle()
                .fill(isTargeted ? Color.white : Color.clear)
                .frame(width: 2, height: 20)
        }
        .frame(width: 2, height: 24)
        .onDrop(of: ["public.plain-text"], isTargeted: $isTargeted) { providers in
            guard let draggedID = draggedBundleID else { return false }

            let pinnedIDs = dockManager.pinnedBundleIDs
            guard let fromIndex = pinnedIDs.firstIndex(of: draggedID) else { return false }

            var toIndex = index
            if fromIndex < toIndex {
                toIndex -= 1
            }

            dockManager.reorderPinnedApp(from: fromIndex, to: toIndex)
            draggedBundleID = nil
            onReordered()
            return true
        }
    }
}

struct AppItemView: View {
    let app: BarAppItem
    @ObservedObject var windowManager: WindowManager
    @ObservedObject var dockManager: DockManager
    let spaceID: UInt64

    var body: some View {
        HStack(spacing: 4) {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.gray)
                    .frame(width: 16, height: 16)
            }

            Text(app.name)
                .font(.system(size: 12, weight: app.isActive ? .semibold : .regular))
                .foregroundColor(app.isActive ? .white : .white.opacity(0.7))
                .lineLimit(1)

            let count = windowManager.windows(for: app.processIdentifier).count
            if count > 1 {
                Divider()
                    .frame(height: 12)
                    .background(Color.white.opacity(0.3))

                Text("\(count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(app.isActive ? Color.white.opacity(0.15) : Color.clear)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .contextMenu {
            if app.isPinned {
                Button("Unpin from Bar") {
                    if let bundleID = app.bundleIdentifier {
                        dockManager.unpinApp(bundleID: bundleID)
                    }
                }
            } else {
                Button("Pin to Bar") {
                    if let bundleID = app.bundleIdentifier {
                        dockManager.pinApp(bundleID: bundleID, name: app.name, url: app.url ?? URL(fileURLWithPath: ""))
                    }
                }
            }
            Divider()
            Button("Close") {
                dockManager.closeApp(app)
            }
        }
        .overlay(
            GeometryReader { geo in
                Color.clear
                    .onHover { hovering in
                        if hovering {
                            windowManager.cancelHidePopupTimer()
                            if app.processIdentifier > 0 {
                                windowManager.selectedApp = app
                            }
                            let frame = geo.frame(in: .global)
                            NotificationCenter.default.post(
                                name: .appChipHovered,
                                object: nil,
                                userInfo: [
                                    "spaceID": spaceID,
                                    "localMinX": frame.minX
                                ]
                            )
                        } else {
                            windowManager.scheduleHidePopup()
                        }
                    }
            }
        )
    }
}

extension Notification.Name {
    static let appChipHovered = Notification.Name("appChipHovered")
    static let spaceChipHovered = Notification.Name("spaceChipHovered")
}

struct WindowPreviewPopup: View {
    @ObservedObject var windowManager: WindowManager

    var body: some View {
        if let spaceID = windowManager.selectedSpace {
            SpacePreviewView(spaceID: spaceID, windowManager: windowManager)
        } else if let app = windowManager.selectedApp {
            AppPreviewView(app: app, windowManager: windowManager)
        }
    }
}

struct SpacePreviewView: View {
    let spaceID: UInt64
    @ObservedObject var windowManager: WindowManager
    
    private var isCurrentSpace: Bool {
        spaceID == windowManager.currentSpaceID
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let screenshot = windowManager.spaceScreenshots[spaceID]
            if let screenshot = screenshot {
                Image(nsImage: screenshot)
                    .resizable()
                    .scaledToFit()
                    .cornerRadius(6)
            } else if isCurrentSpace {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        Text("Capturing…")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    Spacer()
                }
                .frame(minWidth: 200, minHeight: 120)
            } else {
                HStack {
                    Spacer()
                    Text("No preview")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(minWidth: 200, minHeight: 120)
                    Spacer()
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.6))
                .overlay(.ultraThinMaterial)
        )
        .onHover { hovering in
            windowManager.isPopupHovered = hovering
            if hovering {
                windowManager.cancelHidePopupTimer()
            } else {
                windowManager.scheduleHidePopup()
            }
        }
    }
}

struct AppPreviewView: View {
    let app: BarAppItem
    @ObservedObject var windowManager: WindowManager
    
    var body: some View {
        let appWindows = windowManager.windows(for: app.processIdentifier)

        HStack(spacing: 12) {
            if appWindows.isEmpty {
                Text("No windows for \(app.name)")
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .frame(minWidth: 160, minHeight: 100)
            } else {
                ForEach(appWindows) { window in
                    WindowThumbnailView(window: window, windowManager: windowManager)
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.6))
                .overlay(.ultraThinMaterial)
        )
        .onHover { hovering in
            windowManager.isPopupHovered = hovering
            if hovering {
                windowManager.cancelHidePopupTimer()
            } else {
                windowManager.scheduleHidePopup()
            }
        }
    }
}

struct WindowThumbnailView: View {
    let window: WindowInfo
    @ObservedObject var windowManager: WindowManager
    @State private var isHovering = false

    private var fallbackIcon: NSImage? {
        NSRunningApplication(processIdentifier: window.pid)?.icon
    }

    var body: some View {
        VStack(spacing: 4) {
            if let thumbnail = windowManager.thumbnails[window.id] {
                Image(nsImage: topCroppedImage(thumbnail, to: NSSize(width: 160, height: 100)))
                    .resizable()
                    .frame(width: 160, height: 100)
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(isHovering ? Color.white : Color.white.opacity(0.3), lineWidth: isHovering ? 2 : 1)
                    )
            } else if let icon = fallbackIcon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .frame(width: 160, height: 100)
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(isHovering ? Color.white : Color.white.opacity(0.3), lineWidth: isHovering ? 2 : 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 160, height: 100)
                    .overlay(
                        VStack {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.8)
                            Text(windowManager.thumbnailStatus(for: window.id))
                                .font(.system(size: 9))
                                .foregroundColor(.white.opacity(0.7))
                                .padding(.top, 4)
                        }
                    )
            }

            Text(window.title.isEmpty ? "Untitled" : window.title)
                .font(.system(size: 10))
                .foregroundColor(.white)
                .lineLimit(1)
                .frame(width: 160, alignment: .center)
        }
        .task(id: window.id) {
            loadThumbnail()
        }
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                windowManager.hoveredWindow = window
                windowManager.cancelHidePopupTimer()
            } else {
                windowManager.hoveredWindow = nil
                windowManager.scheduleHidePopup()
            }
        }
        .onTapGesture {
            windowManager.focusWindow(window)
        }
    }

    private func loadThumbnail() {
        _ = windowManager.captureThumbnail(for: window.id)
    }
}

extension NSImage {
    var bestCGImage: CGImage? {
        if let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return cgImage
        }
        guard let tiffData = self.tiffRepresentation,
              let source = CGImageSourceCreateWithData(tiffData as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

func topCroppedImage(_ image: NSImage, to targetSize: NSSize) -> NSImage {
    guard let cgImage = image.bestCGImage else { return image }

    let width = Int(targetSize.width)
    let height = Int(targetSize.height)

    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return image }

    let imgSize = image.size
    let scale = targetSize.width / imgSize.width
    let scaledHeight = imgSize.height * scale

    let drawRect = CGRect(x: 0, y: CGFloat(height) - scaledHeight, width: targetSize.width, height: scaledHeight)
    context.interpolationQuality = .high
    context.draw(cgImage, in: drawRect)

    guard let newCGImage = context.makeImage() else { return image }
    let bitmapRep = NSBitmapImageRep(cgImage: newCGImage)
    let newImage = NSImage(size: targetSize)
    newImage.addRepresentation(bitmapRep)
    return newImage
}
