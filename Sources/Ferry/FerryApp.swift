import SwiftUI

@main
struct FerryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Writing to a pipe whose reader died must raise an error, not kill the app.
        signal(SIGPIPE, SIG_IGN)
        // Warm up the login-shell environment (PATH for gcloud etc.) in the background.
        DispatchQueue.global(qos: .userInitiated).async { _ = LoginEnvironment.shared }
        DispatchQueue.global(qos: .utility).async { LocalFiles.clearOpenedFiles() }
    }

    var body: some Scene {
        WindowGroup("Ferry") {
            ContentView()
        }
        .windowToolbarStyle(.unified)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        SSH.closeAllMasters()
    }
}

struct ContentView: View {
    @State private var model = BrowserModel()

    var body: some View {
        Group {
            if model.isConnected {
                BrowserView(model: model)
            } else {
                ConnectView(model: model)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
    }
}
