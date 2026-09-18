import SwiftUI

/// The app itself: one window, one scene, one model.
///
/// A single scene is deliberate (pitfalls §5): several scenes would make the
/// WebView's data store leases and the polling loops a different problem, and
/// nothing in this contract needs them.
@main
@MainActor
struct RemoteEverythingApp: App {

    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environmentObject(model)
        }
    }
}
