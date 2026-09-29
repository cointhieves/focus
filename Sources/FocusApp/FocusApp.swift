import SwiftUI

@main
struct FocusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    // All UI is AppKit-managed (status item + floating panel); this scene is a stub.
    var body: some Scene {
        Settings { EmptyView() }
    }
}
