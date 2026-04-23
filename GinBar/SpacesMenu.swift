import SwiftUI
import Darwin

struct SpacesMenu: View {
    @State private var spaces: [(id: UInt64, index: Int)] = []
    @State private var currentSpaceIndex: Int = 1
    let spaceID: UInt64
    @ObservedObject private var windowManager = WindowManager.shared
    private let sls = SkyLightAPIs.shared
    
    var body: some View {
        HStack(spacing: 4) {
            if !spaces.isEmpty {
                Divider()
                    .background(Color.white.opacity(0.3))
                    .padding(.horizontal, 4)
            }
            
            ForEach(spaces, id: \.id) { space in
                let isActive = currentSpaceIndex == space.index
                Text("\(space.index)")
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .foregroundColor(isActive ? .white : .white.opacity(0.7))
                    .frame(width: 20, height: 20)
                    .background(isActive ? Color.white.opacity(0.15) : Color.clear)
                    .cornerRadius(4)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        switchToSpace(space)
                    }
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .onHover { hovering in
                                    if hovering {
                                        windowManager.cancelHidePopupTimer()
                                        windowManager.selectedSpace = space.id
                                        windowManager.selectedApp = nil
                                        let frame = geo.frame(in: .global)
                                        NotificationCenter.default.post(
                                            name: .spaceChipHovered,
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
        .onAppear {
            refreshSpaces()
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                refreshSpaces()
            }
        }
    }
    
    private func refreshSpaces() {
        guard let copyFn = sls.copyManagedDisplaySpaces,
              let displays = copyFn(sls.mainConnectionID?() ?? 0)?.takeRetainedValue() as? [NSDictionary] else { return }
        
        var newSpaces: [(id: UInt64, index: Int)] = []
        var index = 1
        for display in displays {
            guard let spacesArray = display["Spaces"] as? [NSDictionary] else { continue }
            
            for space in spacesArray {
                if let id64 = space["id64"] as? UInt64 {
                    newSpaces.append((id: id64, index: index))
                    index += 1
                }
            }
            
            if let current = display["Current Space"] as? NSDictionary,
               let id64 = current["id64"] as? UInt64,
               let idx = newSpaces.firstIndex(where: { $0.id == id64 }) {
                currentSpaceIndex = newSpaces[idx].index
            }
        }
        
        self.spaces = newSpaces
    }
    
    private func switchToSpace(_ space: (id: UInt64, index: Int)) {
        WindowManager.shared.switchToSpace(space.id)
        currentSpaceIndex = space.index
    }
}
