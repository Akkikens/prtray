import SwiftUI
import AppKit

/// Small helper that shows SwiftUI views in plain windows (the app has no Dock icon).
@MainActor
enum Windows {
    private static var open: [String: NSWindow] = [:]

    static func show<V: View>(_ key: String, title: String, onClose: (() -> Void)? = nil, @ViewBuilder _ content: () -> V) {
        if let w = open[key] {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(contentViewController: NSHostingController(rootView: content()))
        w.title = title
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        let obs = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated {
                open[key] = nil
                onClose?()
            }
        }
        _ = obs
        open[key] = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func close(_ key: String) { open[key]?.close() }
}

struct SignInView: View {
    let flow: DeviceFlow

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.triangle.pull").font(.system(size: 28))
            Text("Sign in to GitHub").font(.headline)
            switch flow.phase {
            case .starting:
                ProgressView().controlSize(.small)
                Text("Requesting a code…").foregroundStyle(.secondary)
            case .waiting, .done:
                Text("Enter this code on github.com to authorize PRTray:")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                Text(flow.userCode)
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                Button("Copy code & open github.com/login/device") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(flow.userCode, forType: .string)
                    NSWorkspace.shared.open(flow.verificationURL)
                }
                .keyboardShortcut(.defaultAction)
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for authorization…").foregroundStyle(.secondary)
                }
            case .failed(let msg):
                Text(msg).foregroundStyle(.red).multilineTextAlignment(.center)
                Button("Try again") { flow.start() }
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}

struct SettingsView: View {
    let store: Store
    @State private var text = ""
    @State private var owners = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pinned repos").font(.headline)
            Text("Comma-separated owner/name list. PRs from these repos sort first in each section.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("acme/web, acme/api", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
            Text("Only these owners (optional)").font(.headline).padding(.top, 6)
            Text("Comma-separated users or organizations. Leave empty to show PRs from every repo.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("acme, octocat", text: $owners).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Save") {
                    store.ownersFilter = owners
                    store.pinnedRepos = text
                    Windows.close("settings")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { text = store.pinnedRepos; owners = store.ownersFilter }
    }
}
