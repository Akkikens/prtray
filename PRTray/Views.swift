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
        if store.showInbox {
            InboxMenu(store: store)
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
            Toggle("Inbox (GitHub notifications)", isOn: Binding(get: { store.showInbox }, set: { store.showInbox = $0; Task { await store.refresh(force: true) } }))
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

/// GitHub notifications that involve you, last 7 days, grouped by day, newest first.
struct InboxMenu: View {
    let store: Store
    private let maxPerDay = 15

    private var heading: String {
        let unread = store.inboxUnread
        let mentions = store.inboxUnreadMentions
        var t = "Inbox"
        if unread > 0 { t += " — \(unread) unread" }
        if mentions > 0 { t += ", \(mentions) @" }
        return t
    }

    var body: some View {
        Menu(heading) {
            if let err = store.inboxError {
                Text("⚠ " + err.localizedDescription)
                Divider()
            }
            let days = store.inboxDays
            if days.isEmpty && store.inboxError == nil {
                Text(store.mentionsOnly ? "No mentions in the last 7 days" : "Nothing in the last 7 days")
            }
            ForEach(days) { day in
                Section(day.title) {
                    ForEach(day.items.prefix(maxPerDay)) { item in
                        Button { store.open(item) } label: { Text(verbatim: InboxMenu.label(item)) }
                    }
                    if day.items.count > maxPerDay {
                        Text("+\(day.items.count - maxPerDay) more on github.com")
                    }
                }
            }
            Divider()
            Toggle("Mentions only", isOn: Binding(get: { store.mentionsOnly }, set: { store.mentionsOnly = $0 }))
            Button("Mark all as read") { store.markAllRead() }.disabled(store.inboxUnread == 0)
            Button("Open github.com/notifications ↗") { NSWorkspace.shared.open(URL(string: "https://github.com/notifications")!) }
        }
    }

    /// "● @ goldi #6188: ci(chat): group new… · mentioned you · 2h"
    static func label(_ item: InboxItem) -> String {
        let dot = item.unread ? "● " : "    "
        let at = item.isMention ? "@ " : ""
        var t = item.shortRepo + (item.number.map { " #\($0)" } ?? "") + ": " + item.title
        if t.count > 52 { t = String(t.prefix(51)) + "…" }
        return dot + at + t + " · " + item.reasonLabel + " · " + age(item.updatedAt)
    }

    static func age(_ d: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(d))
        if s < 3600 { return "\(max(1, Int(s / 60)))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86400))d"
    }
}
