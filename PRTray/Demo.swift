import AppKit

/// Fake data for README screenshots. No network, generated initials avatars.
enum Demo {
    static var launchFlag: Bool { CommandLine.arguments.contains("-demo") }

    static func avatarURL(_ login: String) -> URL { URL(string: "https://demo.invalid/avatar/\(login)")! }

    static func avatar(_ login: String, size: CGFloat = 16) -> NSImage {
        let palette: [NSColor] = [.systemBlue, .systemPurple, .systemTeal, .systemOrange, .systemPink, .systemIndigo, .systemGreen]
        let color = palette[color(for: login) % palette.count]
        let initials = String(login.prefix(2)).uppercased()
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            NSBezierPath(ovalIn: r).addClip()
            color.setFill()
            r.fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size * 0.45, weight: .semibold),
                .foregroundColor: NSColor.white]
            let str = NSAttributedString(string: initials, attributes: attrs)
            let sz = str.size()
            str.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
            return true
        }
    }

    // Stable fake logins so avatar colors do not depend on per-launch hashing.
    static func color(for login: String) -> Int { login.unicodeScalars.reduce(0) { $0 + Int($1.value) } }

    private static func pr(_ n: Int, _ title: String, _ repo: String, _ author: String, ago: Double,
                           draft: Bool = false, decision: String? = nil, ci: CIState = .success) -> PR {
        PR(id: "demo-\(repo)-\(n)", number: n, title: title,
           url: URL(string: "https://github.com/\(repo)/pull/\(n)")!, repo: repo,
           isDraft: draft, updatedAt: Date().addingTimeInterval(-ago), conflicting: false,
           reviewDecision: decision, ci: ci, author: author, avatarURL: avatarURL(author),
           labels: [], viewerReview: nil)
    }

    static func snapshot() -> Snapshot {
        var s = Snapshot()
        func set(_ id: SectionID, _ prs: [PR], count: Int? = nil) { s.sections[id] = SectionData(count: count ?? prs.count, prs: prs) }
        set(.review, [
            pr(482, "Add retry with backoff to webhook delivery", "acme/api", "maya", ago: 600),
            pr(1317, "Fix flaky checkout test on slow runners", "acme/web", "jordan", ago: 3_600, ci: .failure),
            pr(95, "Bump design tokens to v4", "acme/design-system", "priya", ago: 9_000),
        ])
        set(.returned, [pr(471, "Paginate the audit log endpoint", "acme/api", "alex", ago: 4_000, decision: "CHANGES_REQUESTED")])
        set(.approved, [
            pr(468, "Cache org settings lookups", "acme/api", "alex", ago: 7_000, decision: "APPROVED"),
            pr(1309, "Dark mode for the settings page", "acme/web", "alex", ago: 20_000, decision: "APPROVED"),
        ])
        set(.waitingReviewers, [
            pr(1322, "Redesign onboarding checklist", "acme/web", "alex", ago: 2_000, ci: .pending),
            pr(479, "Add rate limit headers", "acme/api", "alex", ago: 30_000),
        ], count: 4)
        set(.drafts, [pr(1325, "WIP: command palette", "acme/web", "alex", ago: 1_200, draft: true, ci: .none)])
        set(.merging, [
            pr(465, "Migrate sessions table to uuid keys", "acme/api", "alex", ago: 50_000),
            pr(1301, "Fix avatar crop on Safari", "acme/web", "alex", ago: 90_000),
        ])
        set(.waitingAuthor, [pr(88, "Document the release process", "acme/docs", "sam", ago: 70_000)])
        s.mine = s.sections.values.flatMap(\.prs).filter { $0.author == "alex" }
        return s
    }

    /// Avatars for every fake author, keyed by the fake URL.
    static func avatars() -> [URL: NSImage] {
        var out: [URL: NSImage] = [:]
        for login in ["maya", "jordan", "priya", "alex", "sam"] { out[avatarURL(login)] = avatar(login) }
        return out
    }
}
