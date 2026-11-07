import UIKit

/// Tells iOS which orientations are allowed right now. Normally all but upside
/// down; locked to landscape while the player's lock is on.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    @MainActor static var orientationMask: UIInterfaceOrientationMask = .allButUpsideDown

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientationMask
    }
}

@MainActor
enum Orientation {
    /// Landscape only (left and right). Turns the screen even if the iPhone's
    /// own rotation lock is on.
    static func lockLandscape() {
        apply(mask: .landscape, rotateTo: .landscapeRight)
    }

    /// Follows the phone again. `backToPortrait` turns the screen upright,
    /// for when the player closes.
    static func unlock(backToPortrait: Bool) {
        apply(mask: .allButUpsideDown, rotateTo: backToPortrait ? .portrait : nil)
    }

    private static func apply(mask: UIInterfaceOrientationMask, rotateTo: UIInterfaceOrientationMask?) {
        AppDelegate.orientationMask = mask
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) ??
            UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }
        // Every controller on screen must re-read the allowed orientations,
        // the full-screen player included.
        for window in scene.windows {
            var vc = window.rootViewController
            while let current = vc {
                current.setNeedsUpdateOfSupportedInterfaceOrientations()
                vc = current.presentedViewController
            }
        }
        if let rotateTo {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: rotateTo)) { _ in }
        }
    }
}
