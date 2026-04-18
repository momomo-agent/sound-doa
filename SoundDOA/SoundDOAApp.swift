import SwiftUI
import UIKit

@main
struct SoundDOAApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    var bgTask: UIBackgroundTaskIdentifier = .invalid
    func applicationDidEnterBackground(_ application: UIApplication) {
        bgTask = application.beginBackgroundTask(withName: "audio") {
            application.endBackgroundTask(self.bgTask)
            self.bgTask = .invalid
        }
    }
}
