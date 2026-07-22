import Foundation
import UIKit

/// Shared client preferences with the same values and key scope as Android.
final class ClientSettings {
    static let shared = ClientSettings()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var globalOrientation: String {
        validated(defaults.string(forKey: "global_orientation"), allowed: ["system", "portrait", "landscape"], fallback: "system")
    }

    func setGlobalOrientation(_ value: String) {
        defaults.set(validated(value, allowed: ["system", "portrait", "landscape"], fallback: "system"), forKey: "global_orientation")
    }

    var globalDisplayMode: String {
        validated(defaults.string(forKey: "global_display_mode"), allowed: ["phone", "desktop"], fallback: "phone")
    }

    func setGlobalDisplayMode(_ value: String) {
        defaults.set(validated(value, allowed: ["phone", "desktop"], fallback: "phone"), forKey: "global_display_mode")
    }

    var themeMode: String {
        validated(defaults.string(forKey: "theme_mode"), allowed: ["system", "light", "dark"], fallback: "system")
    }

    func setThemeMode(_ value: String) {
        defaults.set(validated(value, allowed: ["system", "light", "dark"], fallback: "system"), forKey: "theme_mode")
    }

    func appOrientation(installationId: String, appId: String) -> String {
        validated(
            defaults.string(forKey: appKey("orientation", installationId: installationId, appId: appId)),
            allowed: ["global", "system", "portrait", "landscape"],
            fallback: "global"
        )
    }

    func setAppOrientation(_ value: String, installationId: String, appId: String) {
        defaults.set(
            validated(value, allowed: ["global", "system", "portrait", "landscape"], fallback: "global"),
            forKey: appKey("orientation", installationId: installationId, appId: appId)
        )
    }

    func resolvedOrientation(installationId: String, appId: String) -> String {
        let appValue = appOrientation(installationId: installationId, appId: appId)
        return appValue == "global" ? globalOrientation : appValue
    }

    func appDisplayMode(installationId: String, appId: String) -> String {
        validated(
            defaults.string(forKey: appKey("display", installationId: installationId, appId: appId)),
            allowed: ["global", "phone", "desktop"],
            fallback: "global"
        )
    }

    func setAppDisplayMode(_ value: String, installationId: String, appId: String) {
        defaults.set(
            validated(value, allowed: ["global", "phone", "desktop"], fallback: "global"),
            forKey: appKey("display", installationId: installationId, appId: appId)
        )
    }

    func resolvedDisplayMode(installationId: String, appId: String) -> String {
        let appValue = appDisplayMode(installationId: installationId, appId: appId)
        return appValue == "global" ? globalDisplayMode : appValue
    }

    func appOrder(installationId: String) -> [String] {
        var seen = Set<String>()
        return (defaults.stringArray(forKey: "app_order_\(installationId)") ?? [])
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    func setAppOrder(_ value: [String], installationId: String) {
        var seen = Set<String>()
        defaults.set(value.filter { !$0.isEmpty && seen.insert($0).inserted }, forKey: "app_order_\(installationId)")
    }

    func removeAppScopedValues(installationId: String) {
        let orientationPrefix = "orientation_\(installationId)_"
        let displayPrefix = "display_\(installationId)_"
        for key in defaults.dictionaryRepresentation().keys {
            if key.hasPrefix(orientationPrefix) || key.hasPrefix(displayPrefix) ||
                key == "app_order_\(installationId)" {
                defaults.removeObject(forKey: key)
            }
        }
    }

    private func appKey(_ prefix: String, installationId: String, appId: String) -> String {
        "\(prefix)_\(installationId)_\(appId)"
    }

    private func validated(_ value: String?, allowed: Set<String>, fallback: String) -> String {
        guard let value, allowed.contains(value) else { return fallback }
        return value
    }
}

@MainActor
enum OrientationController {
    static func apply(_ value: String) {
        let mask: UIInterfaceOrientationMask
        switch value {
        case "portrait": mask = .portrait
        case "landscape": mask = .landscape
        default: mask = .all
        }

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }

        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in
            // Some devices and multitasking layouts do not permit every orientation.
        }
        UIViewController.attemptRotationToDeviceOrientation()
    }
}
