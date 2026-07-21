import SwiftUI

@main
struct RemoteEverythingApp: App {
    @State private var model = AppViewModel()

    var body: some Scene {
        WindowGroup {
            AppRoot(model: model)
        }
    }
}
