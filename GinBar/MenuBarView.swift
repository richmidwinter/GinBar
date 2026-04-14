import SwiftUI
import ScreenCaptureKit

struct MenuBarView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var windowManager = WindowManager.shared
    @State private var captureResult = ""
    
    private var isRunningInPreview: Bool {
        windowManager.isRunningInPreview
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Enabled", isOn: $state.isEnabled)
            
            Divider()
            
            HStack {
                Text("Screen Capture:")
                Spacer()
                permissionStatusView
            }
            
            if windowManager.isRunningInPreview {
                Text("Preview mode — captures disabled")
                    .font(.caption)
                    .foregroundColor(.blue)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Button("Refresh Permission") {
                windowManager.refreshPermission()
            }
            
            if !captureResult.isEmpty {
                Text(captureResult)
                    .font(.caption)
                    .foregroundColor(captureResult.contains("Error") ? .red : .green)
            }
            
            Button("Test Capture") {
                testCapture()
            }
            
            Text("System Settings → Privacy & Security → Screen Recording")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Divider()
            
            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding()
        .frame(width: 260)
    }
    
    @ViewBuilder
    private var permissionStatusView: some View {
        switch windowManager.effectivePermissionStatus {
        case .unknown:
            Label("Checking...", systemImage: "questionmark.circle")
                .foregroundColor(.orange)
        case .granted:
            Label(windowManager.isRunningInPreview ? "Preview" : "Granted", systemImage: windowManager.isRunningInPreview ? "eye.circle.fill" : "checkmark.circle.fill")
                .foregroundColor(windowManager.isRunningInPreview ? .blue : .green)
        case .denied:
            Label("Denied", systemImage: "xmark.circle.fill")
                .foregroundColor(.red)
        }
    }
    
    private func testCapture() {
        guard !isRunningInPreview else {
            captureResult = "Preview mode"
            return
        }
        captureResult = "Testing..."
        Task {
            do {
                let content = try await SCShareableContent.current
                if let firstWindow = content.windows.first {
                    let filter = SCContentFilter(desktopIndependentWindow: firstWindow)
                    let config = SCStreamConfiguration()
                    config.width = 320
                    config.height = 200
                    
                    let image = try await SCScreenshotManager.captureImage(
                        contentFilter: filter,
                        configuration: config
                    )
                    
                    await MainActor.run {
                        captureResult = "Success! Captured \(image.width)x\(image.height) image"
                    }
                } else {
                    await MainActor.run {
                        captureResult = "Error: No windows found"
                    }
                }
            } catch {
                await MainActor.run {
                    captureResult = "Error: \(error.localizedDescription)"
                }
            }
        }
    }
}

extension Notification.Name {
    static let refreshCapturePermission = Notification.Name("refreshCapturePermission")
}
