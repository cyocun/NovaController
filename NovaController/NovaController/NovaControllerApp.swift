import SwiftUI

@main
struct NovaControllerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 840, minHeight: 560)
                .onAppear {
                    USBManager.shared.startMonitoring()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
    }
}
