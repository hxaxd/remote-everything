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

    func apply(_ orientation: WebOrientation) {
        let mask = OrientationLock.mask(for: orientation)
        self.mask = mask
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
    }

    /// Leaving the application gives the screen back to the system: the mask is
    /// released and the scene is asked to rotate to it, the way entering asked
    /// it to hold — otherwise the phone stays in the application's orientation
    /// until the person happens to turn it (the other clients restore on exit).
    func release() {
        mask = .all
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .all))
    }

    static func mask(for orientation: WebOrientation) -> UIInterfaceOrientationMask {
        switch orientation {
        case .system: return .all
        case .portrait: return .portrait
        case .landscape: return .landscape
        }
    }
}
