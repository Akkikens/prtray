import Foundation

/// Talks to the GitHub GraphQL API. The token comes from the Keychain (OAuth) or `gh auth token` and is never logged.
final class GitHubClient {
    private var token: String?

    enum TokenSource { case keychain, gh }
    var pinned: Set<String> = []
    var owners: [String] = []

    func resetToken() { token = nil; source = nil }
    private var source: TokenSource?

    var usingGH: Bool { source == .gh }
    var currentTokenForLogin: String? { token }

    private func resolveToken() async -> String? {
        if let token { return token }
        if let t = Keychain.read() { token = t; source = .keychain; return t }
        if let t = await Task.detached(operation: { GHCLI.token() }).value { token = t; source = .gh; return t }
        return nil
    }

    /// Login of the authenticated user (for the "Sign out (@login)" row).
    func fetchLogin(token: String) async -> String? {
        guard let url = URL(string: "https://api.github.com/user") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("PRTray", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["login"] as? String
    }

    /// Rolling 7 days, UTC timestamp (matches Graphite's count).
    static var mergedSince: String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date().addingTimeInterval(-7 * 24 * 3600))
    }

    // Heavy fragment, only used for the viewer's own PRs.
    private static let fragment = """
    fragment F on PullRequest {
      id number title url isDraft updatedAt mergeable reviewDecision
      viewerLatestReview { state }
      repository { nameWithOwner }
      author { login avatarUrl }
      labels(first: 10) { nodes { name } }
      reviewRequests(first: 1) { totalCount }
      changeReviews: reviews(states: CHANGES_REQUESTED, last: 1) { nodes { submittedAt } }
      commits(last: 1) { nodes { commit { committedDate statusCheckRollup { state } } } }
    }
    """

    private static let lightFragment = """
    fragment L on PullRequest {
      id number title url isDraft updatedAt reviewDecision
      viewerLatestReview { state }
      repository { nameWithOwner }
      author { login avatarUrl }
    }
    """

    private static func esc(_ q: String) -> String {
        q.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Section rules follow Graphite's tray:
    /// - Returned: my open non-draft PRs with changes requested, no pending review requests, and no commits since that review.
    /// - Waiting for reviewers: my open non-draft PRs that are neither approved nor returned.
    /// - Waiting for author: others' open PRs I reviewed (any state), minus the ones needing my review.
    /// - Merging: open PRs with the Merge Queue label plus PRs involving me merged in the last 7 days.
    func fetchSnapshot() async throws -> Snapshot {
        // Keep requests light: big pages with heavy fields make GitHub answer 502.
        var parts = ["query {"]
        let ownerQ = owners.map { " user:\($0)" }.joined()
        let searches: [(String, String, Int)] = [
            ("review", SectionID.review.searchQuery(owners: owners), 100),
            ("waitingAuthor", SectionID.waitingAuthor.searchQuery(owners: owners), 100),
            ("merging", SectionID.merging.searchQuery(owners: owners), 30),
            ("queue", "is:pr is:open author:@me archived:false label:\"Merge Queue\" sort:updated-desc" + ownerQ, 10),
        ]
        for (alias, q, n) in searches {
            parts.append("  \(alias): search(query: \"\(Self.esc(q))\", type: ISSUE, first: \(n)) { issueCount nodes { ...L } }")
        }
        parts.append("}")
        parts.append(Self.lightFragment)
        let json = try await graphQL(parts.joined(separator: "\n"))
        guard let data = json["data"] as? [String: Any] else { throw LoadError.api("empty response") }
        func result(_ key: String) -> (count: Int, prs: [PR]) {
            let r = data[key] as? [String: Any]
            let nodes = (r?["nodes"] as? [[String: Any]]) ?? []
            return (r?["issueCount"] as? Int ?? 0, nodes.compactMap(Self.parse))
        }

        // My own open PRs, paged.
        var mine: [PR] = []
        var cursor: String?
        for _ in 0..<6 {
            let after = cursor.map { ", after: \"\($0)\"" } ?? ""
            let q = "query { mine: search(query: \"\(Self.esc("is:pr is:open author:@me archived:false sort:updated-desc" + ownerQ))\", type: ISSUE, first: 40\(after)) { pageInfo { hasNextPage endCursor } nodes { ...F } } }\n" + Self.fragment
            let j = try await graphQL(q)
            let m = (j["data"] as? [String: Any])?["mine"] as? [String: Any]
            mine += ((m?["nodes"] as? [[String: Any]]) ?? []).compactMap(Self.parse)
            let info = m?["pageInfo"] as? [String: Any]
            guard info?["hasNextPage"] as? Bool == true, let c = info?["endCursor"] as? String else { break }
            cursor = c
        }

        let sort = { (prs: [PR]) in Self.sorted(prs, pinned: self.pinned) }
        let reviewR = result("review")
        let askedIDs = Set(reviewR.prs.map(\.id))
        let nonDraft = mine.filter { !$0.isDraft }
        let approved = nonDraft.filter { $0.reviewDecision == "APPROVED" }
        let returned = nonDraft.filter(\.isReturned)
        let returnedIDs = Set(returned.map(\.id))
        let waiting = nonDraft.filter { $0.reviewDecision != "APPROVED" && !returnedIDs.contains($0.id) }
        let drafts = mine.filter(\.isDraft)

        let wa = result("waitingAuthor")
        let waPRs = wa.prs.filter { !askedIDs.contains($0.id) }
        let waCount = max(waPRs.count, wa.count - (wa.prs.count - waPRs.count))

        let queued = result("queue").prs
        let queuedIDs = Set(queued.map(\.id))
        let mergedR = result("merging")
        let merged = mergedR.prs.filter { !queuedIDs.contains($0.id) }

        var snap = Snapshot()
        snap.sections[.review] = SectionData(count: reviewR.count, prs: sort(reviewR.prs))
        snap.sections[.returned] = SectionData(count: returned.count, prs: sort(returned))
        snap.sections[.approved] = SectionData(count: approved.count, prs: sort(approved))
        snap.sections[.waitingReviewers] = SectionData(count: waiting.count, prs: sort(waiting))
        snap.sections[.drafts] = SectionData(count: drafts.count, prs: sort(drafts))
        snap.sections[.merging] = SectionData(count: queued.count + mergedR.count, prs: sort(queued) + sort(merged))
        snap.sections[.waitingAuthor] = SectionData(count: waCount, prs: sort(waPRs))
        snap.mine = mine
        return snap
    }

    /// For PRs that disappeared from the open list: returns node id -> state (MERGED / CLOSED / OPEN).
    func states(of ids: [String]) async -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        let idList = ids.map { "\"\($0)\"" }.joined(separator: ",")
        let q = "query { nodes(ids: [\(idList)]) { ... on PullRequest { id state } } }"
        guard let json = try? await graphQL(q),
              let nodes = (json["data"] as? [String: Any])?["nodes"] as? [Any] else { return [:] }
        var out: [String: String] = [:]
        for case let n as [String: Any] in nodes {
            if let id = n["id"] as? String, let s = n["state"] as? String { out[id] = s }
        }
        return out
    }

    // MARK: - Notifications (REST)

    /// Notification threads updated in the last `days` days, read and unread, newest first.
    /// Only reasons in `InboxItem.involving` are kept: watching and CI noise is dropped.
    /// With `peopleOnly`, threads that only moved because of a bot, CI, a label or your own activity are dropped too.
    func fetchInbox(days: Int = 7, peopleOnly: Bool = false) async throws -> [InboxItem] {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        let sinceDate = Date().addingTimeInterval(-Double(days) * 24 * 3600)
        let since = f.string(from: sinceDate)
        var out: [InboxItem] = []
        for page in 1...4 {
            let (data, _) = try await rest("notifications?all=true&since=\(since)&per_page=50&page=\(page)")
            guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw LoadError.api("unreadable notifications")
            }
            out += arr.compactMap(Self.parseNotification)
            if arr.count < 50 { break }
        }
        let owners = Set(self.owners)
        out = out
            .filter { InboxItem.involving.contains($0.reason) }
            .filter { owners.isEmpty || owners.contains(String($0.repo.split(separator: "/").first ?? "").lowercased()) }
        if peopleOnly { out = await keepPeople(out, since: sinceDate) }
        return out.sorted { $0.updatedAt > $1.updatedAt }
    }

    struct Commenter { let login: String; let isBot: Bool; let at: Date }
    /// Keyed by latest-comment URL. A new comment gets a new URL, so entries never go stale.
    private var commenters: [String: Commenter] = [:]
    private var viewer: String?

    /// GitHub's `reason` says why you are subscribed, not what just happened: an issue you were
    /// assigned to resurfaces on every bot comment or label change. Mentions and review requests
    /// always stay, named after the latest person to comment. Everything else stays only if its
    /// latest comment is by a person other than you, written inside the window; the row then
    /// shows that person and that time.
    private func keepPeople(_ items: [InboxItem], since: Date) async -> [InboxItem] {
        guard let token = await resolveToken() else { return items }
        if viewer == nil { viewer = await fetchLogin(token: token) }
        let missing = Set(items.compactMap(\.commentURL)).subtracting(commenters.keys)
        await withTaskGroup(of: (String, Commenter?).self) { group in
            for u in missing { group.addTask { (u, await Self.commenter(u, token: token)) } }
            for await (u, c) in group { if let c { commenters[u] = c } }
        }
        let me = viewer?.lowercased()
        return items.compactMap { item in
            if item.isDirected {
                // Kept regardless; named when the latest comment is a person's (for a fresh
                // review request that is the PR's author, who usually asked).
                var kept = item
                if let c = item.commentURL.flatMap({ commenters[$0] }), !c.isBot, c.login.lowercased() != me { kept.actor = c.login }
                return kept
            }
            guard let u = item.commentURL else { return nil }
            // A failed lookup keeps the row: better one extra line than a missed comment.
            guard let c = commenters[u] else { return item }
            guard !c.isBot, c.login.lowercased() != me, c.at >= since else { return nil }
            var kept = item
            kept.actor = c.login
            kept.updatedAt = min(item.updatedAt, c.at)
            return kept
        }
    }

    private static func commenter(_ api: String, token: String) async -> Commenter? {
        guard let url = URL(string: api) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("PRTray", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = obj["user"] as? [String: Any],
              let login = user["login"] as? String,
              let at = (obj["created_at"] as? String).flatMap({ iso.date(from: $0) })
        else { return nil }
        return Commenter(login: login, isBot: user["type"] as? String == "Bot" || login.hasSuffix("[bot]"), at: at)
    }

    /// Marks one thread read on GitHub. Failures are ignored: the next poll shows the truth.
    func markRead(_ threadID: String) async {
        _ = try? await rest("notifications/threads/\(threadID)", method: "PATCH")
    }

    /// Marks everything up to now read.
    func markAllRead() async {
        _ = try? await rest("notifications", method: "PUT", body: ["read": true])
    }

    private static func parseNotification(_ n: [String: Any]) -> InboxItem? {
        guard let id = n["id"] as? String,
              let reason = n["reason"] as? String,
              let subject = n["subject"] as? [String: Any],
              let title = subject["title"] as? String,
              let repoObj = n["repository"] as? [String: Any],
              let repo = repoObj["full_name"] as? String,
              let updated = (n["updated_at"] as? String).flatMap({ iso.date(from: $0) })
        else { return nil }
        let type = subject["type"] as? String ?? ""
        let apiURL = subject["url"] as? String
        let number = apiURL.flatMap { Int($0.split(separator: "/").last ?? "") }
        return InboxItem(id: id, reason: reason, title: title, repo: repo, number: number, type: type,
                         url: htmlURL(apiURL, repo: repo, type: type, number: number),
                         updatedAt: updated, unread: n["unread"] as? Bool ?? false,
                         commentURL: subject["latest_comment_url"] as? String ?? apiURL)
    }

    /// The API gives api.github.com subject URLs; map them to the page a person opens.
    static func htmlURL(_ api: String?, repo: String, type: String, number: Int?) -> URL {
        let base = "https://github.com/\(repo)"
        switch (type, number) {
        case ("PullRequest", let n?): return URL(string: "\(base)/pull/\(n)")!
        case ("Issue", let n?): return URL(string: "\(base)/issues/\(n)")!
        case ("Discussion", let n?): return URL(string: "\(base)/discussions/\(n)")!
        case ("Release", _): return URL(string: "\(base)/releases")!
        default: return URL(string: base)!
        }
    }

    // MARK: - Internals

    private func rest(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> (Data, HTTPURLResponse) {
        guard let token = await resolveToken() else { throw LoadError.noToken }
        guard let url = URL(string: "https://api.github.com/" + path) else { throw LoadError.api("bad url") }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("PRTray", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // Without this, URLSession may serve a cached list and new notifications show up late.
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw LoadError.offline(error.localizedDescription) }
        guard let http = resp as? HTTPURLResponse else { throw LoadError.api("no response") }
        if http.statusCode == 401 {
            if source == .keychain { Keychain.delete() }
            self.token = nil; self.source = nil
            throw LoadError.unauthorized
        }
        if http.statusCode >= 400 {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw LoadError.api("HTTP \(http.statusCode)" + (msg.map { ": \($0)" } ?? ""))
        }
        return (data, http)
    }

    private func graphQL(_ query: String) async throws -> [String: Any] {
        guard let token = await resolveToken() else { throw LoadError.noToken }
        guard let url = URL(string: "https://api.github.com/graphql") else { throw LoadError.api("bad url") }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("PRTray", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw LoadError.offline(error.localizedDescription) }
        if let http = resp as? HTTPURLResponse {
            if http.statusCode == 401 {
                if source == .keychain { Keychain.delete() }
                self.token = nil; self.source = nil
                throw LoadError.unauthorized
            }
            if http.statusCode >= 400 {
                let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
                throw LoadError.api("HTTP \(http.statusCode)" + (body.map { ": \($0)" } ?? ""))
            }
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LoadError.api("unreadable response")
        }
        if let errors = json["errors"] as? [[String: Any]], !errors.isEmpty {
            let msg = (errors.first?["message"] as? String) ?? "unknown"
            NSLog("PRTray GraphQL error: %@", msg)
            throw LoadError.api(msg)
        }
        return json
    }

    private static let iso: ISO8601DateFormatter = ISO8601DateFormatter()

    private static func parse(_ n: [String: Any]) -> PR? {
        guard let id = n["id"] as? String,
              let number = n["number"] as? Int,
              let title = n["title"] as? String,
              let urlStr = n["url"] as? String, let url = URL(string: urlStr),
              let repo = (n["repository"] as? [String: Any])?["nameWithOwner"] as? String
        else { return nil }
        let author = n["author"] as? [String: Any]
        let labels = (((n["labels"] as? [String: Any])?["nodes"]) as? [[String: Any]] ?? [])
            .compactMap { $0["name"] as? String }
        let commit = (((n["commits"] as? [String: Any])?["nodes"]) as? [[String: Any]])?.first?["commit"] as? [String: Any]
        let rollup = commit?["statusCheckRollup"] as? [String: Any]
        let crDate = ((((n["changeReviews"] as? [String: Any])?["nodes"]) as? [[String: Any]])?.first?["submittedAt"] as? String).flatMap { iso.date(from: $0) }
        let commitDate = (commit?["committedDate"] as? String).flatMap { iso.date(from: $0) }
        let pending = (n["reviewRequests"] as? [String: Any])?["totalCount"] as? Int ?? 0
        let ci: CIState
        switch rollup?["state"] as? String {
        case "SUCCESS": ci = .success
        case "FAILURE", "ERROR": ci = .failure
        case "PENDING", "EXPECTED": ci = .pending
        default: ci = .none
        }
        return PR(id: id, number: number, title: title, url: url, repo: repo,
                  isDraft: n["isDraft"] as? Bool ?? false,
                  updatedAt: (n["updatedAt"] as? String).flatMap { iso.date(from: $0) } ?? .distantPast,
                  conflicting: (n["mergeable"] as? String) == "CONFLICTING",
                  reviewDecision: n["reviewDecision"] as? String,
                  ci: ci,
                  author: author?["login"] as? String ?? "ghost",
                  avatarURL: (author?["avatarUrl"] as? String).flatMap { URL(string: $0) },
                  labels: labels,
                  viewerReview: (n["viewerLatestReview"] as? [String: Any])?["state"] as? String,
                  changesRequestedAt: crDate, lastCommitAt: commitDate, pendingRequests: pending)
    }

    /// Pinned repos first, then most recently updated.
    static func sorted(_ prs: [PR], pinned: Set<String>) -> [PR] {
        prs.sorted {
            let a = pinned.contains($0.repo.lowercased()), b = pinned.contains($1.repo.lowercased())
            if a != b { return a }
            return $0.updatedAt > $1.updatedAt
        }
    }
}
