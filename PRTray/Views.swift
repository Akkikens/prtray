import SwiftUI

/// Graphite-style tray: a plain native menu, one line per PR.
struct TrayMenu: View {
    let store: Store
    private let maxRows = 5

    var body: some View {
        if let tag = store.updateTag, let url = store.updateURL {
            Button("Update available: \(tag) ↗") { NSWorkspace.shared.open(url) }
            Divider()
        }
        if let err = store.error {
            Text("⚠ " + err.localizedDescription)
            Divider()
        }
        ForEach(SectionID.allCases.filter(store.isVisible)) { id in
            let data = store.snapshot.data(id)
            Section("\(id.title) (\(data.count))") {
                ForEach(data.prs.prefix(maxRows)) { pr in
                    Button { NSWorkspace.shared.open(pr.url) } label: { PRLabel(pr: pr, avatar: pr.avatarURL.flatMap { store.avatars[$0] }) }
                }
                if data.count > maxRows, let url = id.seeAllURL(owners: store.parsedOwners) {
                    Button("See all ↗") { NSWorkspace.shared.open(url) }
                }
            }
            Divider()
        }
        Button("Refresh") { Task { await store.refresh() } }.disabled(store.isLoading)
        Menu("Sections to display") {
            ForEach(SectionID.allCases) { id in
                Toggle(id.title, isOn: Binding(get: { store.isVisible(id) }, set: { _ in store.toggle(id) }))
            }
            Divider()
            Toggle("Notifications", isOn: Binding(get: { store.notificationsOn }, set: { store.notificationsOn = $0 }))
            Toggle("Launch at login", isOn: Binding(get: { store.launchAtLogin }, set: { store.launchAtLogin = $0 }))
            Divider()
            Menu("Poll every \(store.pollMinutes) min") {
                ForEach([1, 3, 5, 10, 15], id: \.self) { m in
                    Toggle("\(m) min", isOn: Binding(get: { store.pollMinutes == m }, set: { _ in store.pollMinutes = m }))
                }
            }
            Divider()
            Toggle("Demo mode (fake data)", isOn: Binding(get: { store.demo }, set: { store.demo = $0; Task { await store.refresh(force: true) } }))
            Button("Send test notification") { store.sendTestNotification() }
        }
        Button("Settings…") { store.showSettings() }
        Button("Open GitHub ↗") { NSWorkspace.shared.open(URL(string: "https://github.com/pulls")!) }
        Divider()
        if store.hasKeychainToken {
            Button("Sign out" + (store.signedInLogin.map { " (@\($0))" } ?? "")) { store.signOut() }
        } else {
            if store.usingGH { Text("Signed in via gh" + (store.ghLogin.map { " (@\($0))" } ?? "")) }
            Button("Sign in with GitHub…") { store.signIn() }
        }
        Text("Shortcut to open tray  ⌥⌘G")
        Button("Quit PRTray") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
    }
}

struct PRLabel: View {
    let pr: PR
    let avatar: NSImage?

    private var text: String {
        let t = "#" + String(pr.number) + ": " + pr.title
        return t.count > 56 ? String(t.prefix(55)) + "…" : t
    }

    var body: some View {
        if let avatar {
            Label { Text(verbatim: text) } icon: { Image(nsImage: avatar) }
        } else {
            Text(verbatim: text)
        }
    }
}
