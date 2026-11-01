import UIKit

/// The orientation the web host is holding the screen in.
///
/// iOS has no per-screen orientation: the app as a whole declares what it
/// supports, and one application's panel choice has to be made true for the
/// whole app while that application is open. The delegate reads the mask from
/// here, and a change is applied twice — the supported set is updated, and the
/// scene is asked to rotate to it, because a set that changed without a
/// rotation request is a set that only takes effect at the next rotation.
final class OrientationLock {

    static let shared = OrientationLock()

    private(set) var mask: UIInterfaceOrientationMask = .all
    private var restoreMask: UIInterfaceOrientationMask?

    func apply(_ orientation: WebOrientation) {
        if restoreMask == nil { restoreMask = physicalMask() }
        let mask = OrientationLock.mask(for: orientation)
        self.mask = mask
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
    }

    /// Leaving the application gives the screen back to the system. Setting the
    /// mask alone only re-allows rotation; the list would stay in the landscape
    /// the web application asked for until the device is turned. Ask the scene
    /// to return to the device's orientation as well.
    func release() {
        mask = .all
        let saved = restoreMask
        restoreMask = nil
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        let target = physicalMask() != .all ? physicalMask() : (saved ?? .all)
        if target != .all {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: target))
        }
    }

    private func physicalMask() -> UIInterfaceOrientationMask {
        switch UIDevice.current.orientation {
        case .portrait, .portraitUpsideDown: return .portrait
        case .landscapeLeft, .landscapeRight: return .landscape
        default: return .all
        }
    }

    static func mask(for orientation: WebOrientation) -> UIInterfaceOrientationMask {
        switch orientation {
        case .system: return .all
        case .portrait: return .portrait
        case .landscape: return .landscape
        }
    }
}
