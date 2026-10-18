import Sparkle
import SwiftUI

@main
struct AnyFileApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    private var queue: ConversionQueue { appDelegate.queue }
    private var settings: AppSettings { appDelegate.settings }

    var body: some Scene {
        Window("AnyFile", id: "main") {
            ContentView()
                .environment(queue)
                .environment(settings)
        }
        .defaultSize(width: 760, height: 520)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updater: appDelegate.updaterController.updater)
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Files…") {
                    NotificationCenter.default.post(name: .openFiles, object: nil)
                }
                .keyboardShortcut("o")
            }
        }

        Settings {
            SettingsView()
                .environment(queue)
                .environment(settings)
        }
    }
}

/// Receives files opened from Finder ("Open With", dropping on the Dock icon, `open -a AnyFile`).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings: AppSettings
    let queue: ConversionQueue
    /// Sparkle: checks the GitHub Releases appcast (SUFeedURL in AnyFile-Info.plist).
    let updaterController: SPUStandardUpdaterController

    override init() {
        settings = AppSettings()
        queue = ConversionQueue(ffmpegPath: settings.ffmpegPath)
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        queue.add(urls.filter(\.isFileURL))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

extension Notification.Name {
    static let openFiles = Notification.Name("AnyFile.openFiles")
}
