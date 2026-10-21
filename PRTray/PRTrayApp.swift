import SwiftUI

@main
struct PRTrayApp: App {
    @State private var store = Store()

    init() {
        HotKey.register()
        // Used for README screenshots: opens the tray shortly after launch.
        if CommandLine.arguments.contains("-openTray") {
            DispatchQueue.main.asyncAfter(deadline: .now() + (Demo.launchFlag ? 2 : 10)) { HotKey.openTray() }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            TrayMenu(store: store)
        } label: {
            Image("MenuBarIcon")
            if store.snapshot.attentionCount > 0 {
                Text("\(store.snapshot.attentionCount)")
            }
        }
        .menuBarExtraStyle(.menu)
    }
}
