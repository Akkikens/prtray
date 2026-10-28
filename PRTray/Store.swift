import Foundation
import Observation
import ServiceManagement
import UserNotifications
import AppKit

@Observable
@MainActor
final class Store: NSObject, UNUserNotificationCenterDelegate {
    var snapshot = Snapshot()
    var inbox: [InboxItem] = []
    var inboxError: LoadError?
    var inboxUnread: Int { inbox.filter(\.unread).count }
    var inboxUnreadMentions: Int { inbox.filter { $0.unread && $0.isMention }.count }
    var inboxDays: [InboxDay] { InboxDay.group(mentionsOnly ? inbox.filter(\.isMention) : inbox) }
    var mentionsOnly: Bool { didSet { UserDefaults.standard.set(mentionsOnly, forKey: "inboxMentionsOnly") } }
    var peopleOnly: Bool { didSet { UserDefaults.standard.set(peopleOnly, forKey: "inboxPeopleOnly") } }
    var showInbox: Bool { didSet { UserDefaults.standard.set(showInbox, forKey: "showInbox") } }
    var error: LoadError?
    var lastRefreshed: Date?
    var isLoading = false
    var avatars: [URL: NSImage] = [:]
    var visible: Set<String> {
        didSet { UserDefaults.standard.set(Array(visible), forKey: "visibleSections") }
    }
    private var avatarsRequested: Set<URL> = []

    var demo = Demo.launchFlag
    var signedInLogin: String? = UserDefaults.standard.string(forKey: "githubLogin")
    var hasKeychainToken = Keychain.read() != nil
    var updateTag: String?
    var updateURL: URL?
    var pinnedRepos: String {
        didSet {
            UserDefaults.standard.set(pinnedRepos, forKey: "pinnedRepos")
            Task { await refresh(force: true) }
        }
    }
    var ghLogin: String?
    var ownersFilter: String {
        didSet {
            UserDefaults.standard.set(ownersFilter, forKey: "ownersFilter")
            Task { await refresh(force: true) }
        }
    }
    var parsedOwners: [String] {
        ownersFilter.split(whereSeparator: { ", ;\n".contains($0) }).map { String($0).lowercased() }
    }
    var usingGH: Bool { client.usingGH && !hasKeychainToken }

    static func parsePinned(_ s: String) -> Set<String> {
        Set(s.split(whereSeparator: { ",;\n ".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { $0.contains("/") })
    }

    var pollMinutes: Int { didSet { UserDefaults.standard.set(pollMinutes, forKey: "pollMinutes"); schedule() } }
    var notificationsOn: Bool {
        didSet { UserDefaults.standard.set(notificationsOn, forKey: "notificationsOn"); if notificationsOn { requestAuth() } }
    }
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            try? (newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister())
        }
    }

    private let client = GitHubClient()
    private var previous: Snapshot?
    private var timer: Timer?

    override init() {
        let d = UserDefaults.standard
        pollMinutes = d.object(forKey: "pollMinutes") as? Int ?? 3
        notificationsOn = d.object(forKey: "notificationsOn") as? Bool ?? true
        let saved = d.stringArray(forKey: "visibleSections")
        visible = Set(saved ?? SectionID.allCases.map(\.rawValue))
        pinnedRepos = d.string(forKey: "pinnedRepos") ?? ""
        ownersFilter = d.string(forKey: "ownersFilter") ?? ""
        mentionsOnly = d.object(forKey: "inboxMentionsOnly") as? Bool ?? false
        showInbox = d.object(forKey: "showInbox") as? Bool ?? true
        peopleOnly = d.object(forKey: "inboxPeopleOnly") as? Bool ?? true
        super.init()
        UNUserNotificationCenter.current().delegate = self
        if notificationsOn { requestAuth() }
        schedule()
        Task { await refresh() }
        Task { await checkForUpdate() }
        let daily = Timer(timeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkForUpdate() }
        }
        RunLoop.main.add(daily, forMode: .common)
        if CommandLine.arguments.contains("-testNotification") { Task { try? await Task.sleep(for: .seconds(2)); sendTestNotification() } }
    }

    func sendTestNotification() {
        let c = UNMutableNotificationContent()
        c.title = "PRTray test notification"
        c.body = "Notifications are working."
        c.sound = .default
        c.userInfo = ["url": "https://github.com/pulls"]
        UNUserNotificationCenter.current().getNotificationSettings { s in
            NSLog("PRTray notification auth status: %ld", s.authorizationStatus.rawValue)
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)) { err in
            NSLog("PRTray test notification result: %@", err.map { "\($0)" } ?? "ok")
        }
    }

    func isVisible(_ id: SectionID) -> Bool { visible.contains(id.rawValue) }
    func toggle(_ id: SectionID) {
        if visible.contains(id.rawValue) { visible.remove(id.rawValue) } else { visible.insert(id.rawValue) }
    }

    /// Fetches avatars once and caches them as 16pt circles.
    private func loadAvatars(_ snap: Snapshot) {
        let urls = Set(snap.sections.values.flatMap { $0.prs.prefix(5) }.compactMap(\.avatarURL))
        for url in urls where !avatarsRequested.contains(url) {
            avatarsRequested.insert(url)
            Task {
                guard let (data, _) = try? await URLSession.shared.data(from: url),
                      let img = NSImage(data: data) else { avatarsRequested.remove(url); return }
                avatars[url] = Self.circle(img, size: 16)
            }
        }
    }

    private static func circle(_ img: NSImage, size: CGFloat) -> NSImage {
        let out = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            NSBezierPath(ovalIn: r).addClip()
            img.draw(in: r)
            return true
        }
        return out
    }

    private func schedule() {
        timer?.invalidate()
        let t = Timer(timeInterval: Double(max(1, pollMinutes)) * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh(force: Bool = false) async {
        if demo {
            snapshot = Demo.snapshot()
            inbox = Demo.inbox()
            inboxError = nil
            avatars = Demo.avatars()
            error = nil
            lastRefreshed = Date()
            return
        }
        guard !isLoading || force else { return }
        isLoading = true
        defer { isLoading = false }
        client.pinned = Self.parsePinned(pinnedRepos)
        client.owners = parsedOwners
        do {
            let snap = try await client.fetchSnapshot()
            if let prev = previous, notificationsOn { await notifyDiff(prev, snap) }
            previous = snap
            snapshot = snap
            loadAvatars(snap)
            error = nil
            lastRefreshed = Date()
            if usingGH, ghLogin == nil, let t = client.currentTokenForLogin, let l = await client.fetchLogin(token: t) { ghLogin = l }
        } catch let e as LoadError {
            error = e
            if case .unauthorized = e { hasKeychainToken = Keychain.read() != nil; if !hasKeychainToken { signedInLogin = nil; UserDefaults.standard.removeObject(forKey: "githubLogin") } }
        } catch {
            self.error = .api(error.localizedDescription)
        }
        if showInbox { await refreshInbox() }
    }

    // MARK: - Inbox

    private var previousInbox: [InboxItem]?

    /// Fails on its own: a notifications error shows in the Inbox menu and leaves the PR sections alone.
    private func refreshInbox() async {
        do {
            let items = try await client.fetchInbox(peopleOnly: peopleOnly)
            if let prev = previousInbox, notificationsOn { notifyNewMentions(prev, items) }
            previousInbox = items
            inbox = items
            inboxError = nil
        } catch let e as LoadError {
            inboxError = e
        } catch {
            inboxError = .api(error.localizedDescription)
        }
    }

    func setPeopleOnly(_ on: Bool) {
        peopleOnly = on
        guard !demo else { return }
        Task { await refreshInbox() }
    }

    func open(_ item: InboxItem) {
        NSWorkspace.shared.open(item.url)
        guard item.unread, !demo else { return }
        if let i = inbox.firstIndex(where: { $0.id == item.id }) { inbox[i].unread = false }
        Task { await client.markRead(item.id) }
    }

    func markAllRead() {
        for i in inbox.indices { inbox[i].unread = false }
        guard !demo else { return }
        Task { await client.markAllRead() }
    }

    private func notifyNewMentions(_ old: [InboxItem], _ new: [InboxItem]) {
        // A thread already unread before this poll was announced then (or predates launch).
        let wasUnread = Set(old.filter(\.unread).map(\.id))
        for item in new where item.unread && item.isMention && !wasUnread.contains(item.id) {
            let c = UNMutableNotificationContent()
            c.title = item.reason == "team_mention" ? "Your team was mentioned" : "You were mentioned"
            c.body = "\(item.shortRepo)" + (item.number.map { " #\($0)" } ?? "") + ": \(item.title)"
            c.sound = .default
            c.userInfo = ["url": item.url.absoluteString]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
    }

    // MARK: - Auth

    private var flow: DeviceFlow?

    func signIn() {
        let f = DeviceFlow()
        flow = f
        f.onToken = { [weak self] token in
            guard let self else { return }
            Task { @MainActor in await self.finishSignIn(token) }
        }
        Windows.show("signin", title: "Sign in to GitHub", onClose: { [weak self] in self?.flow?.cancel(); self?.flow = nil }) { SignInView(flow: f) }
        f.start()
    }

    private func finishSignIn(_ token: String) async {
        Keychain.save(token)
        hasKeychainToken = true
        client.resetToken()
        if let login = await client.fetchLogin(token: token) {
            signedInLogin = login
            UserDefaults.standard.set(login, forKey: "githubLogin")
        }
        Windows.close("signin")
        await refresh(force: true)
    }

    func signOut() {
        Keychain.delete()
        hasKeychainToken = false
        signedInLogin = nil
        UserDefaults.standard.removeObject(forKey: "githubLogin")
        client.resetToken()
        snapshot = Snapshot()
        previous = nil
        inbox = []
        previousInbox = nil
        Task { await refresh(force: true) }
    }

    func showSettings() { Windows.show("settings", title: "PRTray Settings") { SettingsView(store: self) } }

    // MARK: - Updates

    func checkForUpdate() async {
        guard let url = URL(string: "https://api.github.com/repos/Akkikens/prtray/releases/latest") else { return }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("PRTray", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return }
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        if Self.isNewer(tag, than: current) {
            updateTag = tag
            updateURL = (json["html_url"] as? String).flatMap { URL(string: $0) } ?? URL(string: "https://github.com/Akkikens/prtray/releases/latest")
        } else {
            updateTag = nil
        }
    }

    static func isNewer(_ tag: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let a = parts(tag), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Notifications

    private func requestAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(_ title: String, _ pr: PR) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = "\(pr.shortRepo) #\(pr.number): \(pr.title)"
        c.sound = .default
        c.userInfo = ["url": pr.url.absoluteString]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    private func notifyDiff(_ old: Snapshot, _ new: Snapshot) async {
        let oldReview = Set(old.review.map(\.id))
        for pr in new.review where !oldReview.contains(pr.id) { notify("Review requested", pr) }

        let oldMine = Dictionary(old.mine.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let newIDs = Set(new.mine.map(\.id))
        for pr in new.mine {
            guard let was = oldMine[pr.id] else { continue }
            if pr.reviewDecision == "CHANGES_REQUESTED", was.reviewDecision != "CHANGES_REQUESTED" { notify("Changes requested", pr) }
            if pr.reviewDecision == "APPROVED", was.reviewDecision != "APPROVED" { notify("Approved", pr) }
            if pr.ci == .failure, was.ci != .failure { notify("CI failing", pr) }
        }
        let gone = old.mine.filter { !newIDs.contains($0.id) }
        if !gone.isEmpty {
            let states = await client.states(of: gone.map(\.id))
            for pr in gone {
                switch states[pr.id] {
                case "MERGED": notify("Merged", pr)
                case "CLOSED": notify("Closed", pr)
                default: break
                }
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let s = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: s) {
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
