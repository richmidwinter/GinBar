import SwiftUI
import Combine

@MainActor
class AppState: ObservableObject {
    @Published var config = Config()
    @Published var isEnabled: Bool = true
    var overlayManager: OverlayManager?
    
    init() {
        self.overlayManager = OverlayManager(state: self)
    }
}
