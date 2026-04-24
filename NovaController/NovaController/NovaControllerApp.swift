import SwiftUI
import Sparkle

@main
struct NovaControllerApp: App {
    init() {
        // print の即時反映 (パイプ経由起動時のフルバッファ問題を回避)
        setvbuf(stdout, nil, _IONBF, 0)
    }

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
            TestPatternCommands()
        }
    }
}

// MARK: - TestPatternCommands

/// "View" menu — test pattern and display mode shortcuts.
struct TestPatternCommands: Commands {
    var body: some Commands {
        CommandMenu("View") {
            Button("Clear Pattern")  { USBManager.shared.setTestPattern(.normal) }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
            Button("Red")            { USBManager.shared.setTestPattern(.red) }
                .keyboardShortcut("1", modifiers: .command)
            Button("Green")          { USBManager.shared.setTestPattern(.green) }
                .keyboardShortcut("2", modifiers: .command)
            Button("Blue")           { USBManager.shared.setTestPattern(.blue) }
                .keyboardShortcut("3", modifiers: .command)
            Button("White")          { USBManager.shared.setTestPattern(.white) }
                .keyboardShortcut("4", modifiers: .command)
            Button("Horizontal Stripes") { USBManager.shared.setTestPattern(.horizontal) }
                .keyboardShortcut("5", modifiers: .command)
            Button("Vertical Stripes")   { USBManager.shared.setTestPattern(.vertical) }
                .keyboardShortcut("6", modifiers: .command)
            Button("Diagonal")       { USBManager.shared.setTestPattern(.diagonal) }
                .keyboardShortcut("7", modifiers: .command)
            Button("Grayscale")      { USBManager.shared.setTestPattern(.grayscale) }
                .keyboardShortcut("8", modifiers: .command)
            Divider()
            Button("Freeze")         { USBManager.shared.setDisplayMode(.freeze) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Black")          { USBManager.shared.setDisplayMode(.black) }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Button("Clear Mode")     { USBManager.shared.setDisplayMode(.normal) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
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
        Button("Check for Updates…") {
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
