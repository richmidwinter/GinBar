import SwiftUI
import ApplicationServices
import CoreGraphics

struct MenuBarView: View {
    @State private var menuOpenCount = 0

    private var screenRecordingStatus: PermissionStatus {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    private var accessibilityStatus: PermissionStatus {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        return AXIsProcessTrustedWithOptions(options as CFDictionary) ? .granted : .denied
    }

    var body: some View {
        let _ = menuOpenCount

        VStack(spacing: 0) {
            PermissionRow(
                title: "Screen Recording",
                status: screenRecordingStatus,
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            )

            Divider()
                .padding(.vertical, 4)

            PermissionRow(
                title: "Accessibility",
                status: accessibilityStatus,
                settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            )

            Divider()
                .padding(.vertical, 4)

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .padding(.vertical, 3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(width: 240)
        .onAppear {
            menuOpenCount += 1
        }
    }
}

enum PermissionStatus: Equatable {
    case granted
    case denied

    var label: String {
        switch self {
        case .granted: return "Granted"
        case .denied:  return "Required"
        }
    }

    var color: Color {
        switch self {
        case .granted: return .green
        case .denied:  return .red
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let status: PermissionStatus
    let settingsURL: URL

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.system(size: 13))

            Text(status.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(status.color)

            if status == .denied {
                Button("Open Settings...") {
                    NSWorkspace.shared.open(settingsURL)
                }
                .controlSize(.small)
                .buttonStyle(BorderedButtonStyle())
            }
        }
    }
}
