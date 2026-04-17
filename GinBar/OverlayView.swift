import SwiftUI

struct BarView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var dockManager = DockManager.shared
    @ObservedObject private var windowManager = WindowManager.shared
    let barHeight: CGFloat
    let spaceID: UInt64
    
    var body: some View {
        HStack(spacing: 4) {
            ApplicationsMenu()
                .frame(width: 28)
            
            Divider()
                .background(Color.white.opacity(0.3))
                .padding(.horizontal, 4)
            
            ForEach(dockManager.appsWithWindows, id: \.processIdentifier) { app in
                AppItemView(
                    app: app,
                    isActive: app.isActive,
                    windowManager: windowManager,
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
    }
}

struct AppItemView: View {
    let app: NSRunningApplication
    let isActive: Bool
    @ObservedObject var windowManager: WindowManager
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
            
            Text(app.localizedName ?? "Unknown")
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundColor(isActive ? .white : .white.opacity(0.7))
                .lineLimit(1)
            
            let count = windowManager.windows(for: app).count
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
        .background(isActive ? Color.white.opacity(0.15) : Color.clear)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .overlay(
            GeometryReader { geo in
                Color.clear
                    .onHover { hovering in
                        if hovering {
                            windowManager.cancelHidePopupTimer()
                            windowManager.selectedApp = app
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
}

struct WindowPreviewPopup: View {
    @ObservedObject var windowManager: WindowManager
    
    var body: some View {
        if let app = windowManager.selectedApp {
            let appWindows = windowManager.windows(for: app)
            
            HStack(spacing: 12) {
                if appWindows.isEmpty {
                    Text("No windows for \(app.localizedName ?? "Unknown")")
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                        .frame(minWidth: 160, minHeight: 100)
                } else {
                    ForEach(appWindows) { window in
                        WindowThumbnailView(window: window, windowManager: windowManager)
                    }
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 12)
            .padding(.trailing, 12)
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
