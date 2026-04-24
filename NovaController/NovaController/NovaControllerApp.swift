import SwiftUI
import Sparkle

@main
struct NovaControllerApp: App {
    // Sparkle Updater コントローラ
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

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
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }
    }
}

/// アプリメニューの「Check for Updates…」項目
struct CheckForUpdatesView: View {
    @ObservedObject private var checker: UpdaterStatusObserver
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.checker = UpdaterStatusObserver(updater: updater)
    }

    var body: some View {
        Button("アップデートを確認…") {
            updater.checkForUpdates()
        }
        .disabled(!checker.canCheckForUpdates)
    }
}

/// `canCheckForUpdates` を監視する ObservableObject ラッパー
final class UpdaterStatusObserver: ObservableObject {
    @Published var canCheckForUpdates: Bool = false
    private var observation: NSKeyValueObservation?

    init(updater: SPUUpdater) {
        self.canCheckForUpdates = updater.canCheckForUpdates
        self.observation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            if let value = change.newValue {
                DispatchQueue.main.async { self?.canCheckForUpdates = value }
            }
        }
    }
}
