import SwiftUI
import UIKit

/// Constrain view rotation
@MainActor
enum OrientationLock {
    static var allowsRotation = false {
        didSet {
            guard allowsRotation != oldValue else { return }
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene else { continue }
                windowScene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                if !allowsRotation {
                    windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
                }
            }
        }
    }
}

final class SigmaDevelopAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.allowsRotation ? .all : .portrait
    }
}

@main
struct SigmaDevelopApp: App {
    @UIApplicationDelegateAdaptor(SigmaDevelopAppDelegate.self) private var appDelegate
    @State private var store = LibraryStore()
    @State private var path = NavigationPath()

    var body: some Scene {
        WindowGroup {
            NavigationStack(path: $path) {
                LibraryGridView()
            }
            .environment(store)
            .preferredColorScheme(.light)
            .task { await autoDrive() }
        }
    }

    /// Headless-verification hook (debug builds only): `SIGMA_AUTO_IMPORT=<dir>`
    /// imports a folder on launch and `SIGMA_AUTO_OPEN=1` pushes the first item,
    /// so `simctl` runs can exercise the full pipeline without a file picker.
    /// Once per process: a scene reconnect recreates the content view and would
    /// rerun the task, double-importing.
    @MainActor private static var didAutoDrive = false

    private func autoDrive() async {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["SIGMA_AUTO_IMPORT"], !Self.didAutoDrive else { return }
        Self.didAutoDrive = true
        await store.importPicked([URL(fileURLWithPath: dir)])
        if env["SIGMA_AUTO_OPEN"] == "1", let first = store.items.first {
            path.append(first)
        }
        #endif
    }
}
