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

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                LibraryGridView()
            }
            .environment(store)
            .preferredColorScheme(.light)
        }
    }
}
