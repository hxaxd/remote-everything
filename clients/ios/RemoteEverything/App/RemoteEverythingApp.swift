import SwiftUI
import UIKit

/// What the system asks the app rather than the views: the orientation an
/// application in the web host has asked to be held in (S4's panel). Everything
/// else is answered through SwiftUI.
final class RemoteEverythingAppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationLock.shared.mask
    }
}

/// The app itself: one window, one scene, one model.
///
/// A single scene is deliberate: several scenes would make the
/// WebView's data store leases and the polling loops a different problem, and
/// nothing in this contract needs them.
@main
@MainActor
struct RemoteEverythingApp: App {

    @UIApplicationDelegateAdaptor(RemoteEverythingAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environmentObject(model)
        }
    }
}
