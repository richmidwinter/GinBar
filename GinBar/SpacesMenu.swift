import SwiftUI
import Darwin

private typealias SLSMainConnectionIDFunc = @convention(c) () -> Int32
private typealias SLSCopyManagedDisplaySpacesFunc = @convention(c) (Int32) -> Unmanaged<CFArray>?

private struct SkyLightAPIs {
    static let shared = SkyLightAPIs()
    
    let mainConnectionID: SLSMainConnectionIDFunc?
    let copyManagedDisplaySpaces: SLSCopyManagedDisplaySpacesFunc?
    
    init() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW) else {
            self.mainConnectionID = nil
            self.copyManagedDisplaySpaces = nil
            return
        }
        self.mainConnectionID = unsafeBitCast(dlsym(handle, "SLSMainConnectionID"), to: SLSMainConnectionIDFunc.self)
        self.copyManagedDisplaySpaces = unsafeBitCast(dlsym(handle, "SLSCopyManagedDisplaySpaces"), to: SLSCopyManagedDisplaySpacesFunc.self)
    }
}

struct SpacesMenu: View {
    @State private var spaces: [(id: UInt64, index: Int)] = []
    @State private var currentSpaceIndex: Int = 1
    @State private var isHovered = false
    let spaceID: UInt64
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
                    .onHover { hovering in
                        isHovered = hovering
                    }
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
