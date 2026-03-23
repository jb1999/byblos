import SwiftUI

@main
struct ByblosApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Dummy scene — required by SwiftUI but we never show it.
        // All UI is managed by AppDelegate (menu bar, settings window, transcripts).
        Settings {
            EmptyView()
        }
    }
}
