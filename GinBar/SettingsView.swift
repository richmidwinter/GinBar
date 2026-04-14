import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Slider(value: $state.config.cornerRadius, in: 0...30) {
                Text("Corner Radius")
            }
            Slider(value: $state.config.padding, in: 0...20) {
                Text("Padding")
            }
        }
        .padding()
        .frame(width: 400)
    }
}
