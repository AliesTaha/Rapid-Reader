import Combine
import SwiftUI

// Local source build: no binary updater dependency or automatic updates.
@MainActor
final class AppUpdater: ObservableObject {
    let canCheckForUpdates = false
    var isAvailable: Bool { false }
    var automaticallyChecksForUpdates: Bool {
        get { false }
        set { }
    }
    func checkForUpdates() { }
}

struct UpdateCommands: Commands {
    @ObservedObject var updater: AppUpdater
    var body: some Commands { CommandGroup(after: .appInfo) { } }
}
