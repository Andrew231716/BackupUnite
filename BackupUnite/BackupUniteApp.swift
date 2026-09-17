import SwiftUI

@main
struct BackupUniteApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--run-self-test") {
                SelfTestView()
            } else {
                ContentView()
            }
            #else
            ContentView()
            #endif
        }
    }
}
