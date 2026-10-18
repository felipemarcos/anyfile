import Combine
import Sparkle
import SwiftUI

/// "Check for Updates…" menu item, disabled while Sparkle is already checking.
struct CheckForUpdatesButton: View {
    @StateObject private var model: Model
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        _model = StateObject(wrappedValue: Model(updater: updater))
    }

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!model.canCheckForUpdates)
    }

    @MainActor
    private final class Model: ObservableObject {
        @Published var canCheckForUpdates = false

        init(updater: SPUUpdater) {
            updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        }
    }
}
