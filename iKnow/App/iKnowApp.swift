import SwiftUI

@main
struct IKnowApp: App {
    var body: some Scene {
        Window("iKnow", id: "graph") {
            DesktopView()
                .environment(\.locale, .iKnow)
                .frame(minWidth: 980, minHeight: 560)
        }
        .defaultSize(width: 1_360, height: 820)
        .windowToolbarStyle(.unified)
    }
}
