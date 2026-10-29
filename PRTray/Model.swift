import Foundation

enum CIState { case success, failure, pending, none }

struct PR: Identifiable, Equatable {
    let id: String            // GraphQL node id
    let number: Int
    let title: String
    let url: URL
    let repo: String          // owner/name
    let isDraft: Bool
    let updatedAt: Date
    let conflicting: Bool
    let reviewDecision: String?
    let ci: CIState
    let author: String
    let avatarURL: URL?
    let labels: [String]
    let viewerReview: String?
    var returnedAt: Date? = nil
    var lastCommitAt: Date? = nil
    var pendingRequests = 0

    var isReturned: Bool {
        ReturnedRule.isReturned(decision: reviewDecision, pendingRequests: pendingRequests,
                                returnedAt: returnedAt, lastCommitAt: lastCommitAt)
    }

    var shortRepo: String { repo.split(separator: "/").last.map(String.init) ?? repo }
    var statusLabels: [String] { labels.filter { $0.hasPrefix("status:") || $0.hasPrefix("qa:") } }
    var inMergeQueue: Bool { labels.contains("Merge Queue") }
}

enum SectionID: String, CaseIterable, Identifiable {
    case review, returned, approved, waitingReviewers, drafts, merging, waitingAuthor
    var id: String { rawValue }

    var title: String {
        switch self {
        case .review: return "Needs your review"
        case .returned: return "Returned to you"
        case .approved: return "Approved"
        case .waitingReviewers: return "Waiting for reviewers"
        case .drafts: return "Drafts"
        case .merging: return "Merging and recently merged"
        case .waitingAuthor: return "Waiting for author"
        }
    }

    /// The GitHub search behind the "See all" row.
    func searchQuery(owners: [String] = []) -> String {
        base + owners.map { " user:\($0)" }.joined()
    }

    private var base: String {
        switch self {
        case .review: return "is:pr is:open review-requested:@me archived:false draft:false sort:updated-desc"
        case .returned: return "is:pr is:open author:@me archived:false review:changes_requested"
        case .approved: return "is:pr is:open author:@me archived:false draft:false review:approved"
        case .waitingReviewers: return "is:pr is:open author:@me archived:false draft:false -review:approved"
        case .drafts: return "is:pr is:open author:@me archived:false draft:true"
        case .merging: return "is:pr involves:@me is:merged merged:>=\(GitHubClient.mergedSince) sort:updated-desc"
        case .waitingAuthor: return "is:pr is:open reviewed-by:@me -author:@me archived:false sort:updated-desc"
        }
    }

    func seeAllURL(owners: [String] = []) -> URL? {
        var c = URLComponents(string: "https://github.com/pulls")
        c?.queryItems = [URLQueryItem(name: "q", value: searchQuery(owners: owners))]
        return c?.url
    }
}

struct SectionData: Equatable {
    var count = 0
    var prs: [PR] = []
}

struct Snapshot: Equatable {
    var sections: [SectionID: SectionData] = [:]
    var mine: [PR] = []       // all my open PRs, used for notification diffs

    var review: [PR] { sections[.review]?.prs ?? [] }
    var attentionCount: Int { (sections[.review]?.count ?? 0) + (sections[.returned]?.count ?? 0) }
    func data(_ id: SectionID) -> SectionData { sections[id] ?? SectionData() }
}

enum LoadError: Error, LocalizedError {
    case noToken, unauthorized, offline(String), api(String)
    var errorDescription: String? {
        switch self {
        case .noToken: return "Sign in with GitHub to see your pull requests."
        case .unauthorized: return "GitHub rejected the token. Please sign in again."
        case .offline(let m): return "Can't reach GitHub: \(m)"
        case .api(let m): return "GitHub: \(m)"
        }
    }
}

/// One GitHub notification thread (REST /notifications).
struct InboxItem: Identifiable, Equatable {
    let id: String            // thread id
    let reason: String        // mention, team_mention, review_requested, comment, assign, author, state_change, ...
    let title: String
    let repo: String          // owner/name
    let number: Int?
    let type: String          // PullRequest, Issue, Release, Discussion, CheckSuite, ...
    let url: URL              // github.com page
    var updatedAt: Date
    var unread: Bool
    var commentURL: String? = nil  // API url of the thread's latest comment (the subject itself when none)
    var actor: String? = nil       // the person behind the latest activity, when known

    var isMention: Bool { reason == "mention" || reason == "team_mention" }
    /// Pulled in on purpose by someone: always shown, even with "People only" on.
    var isDirected: Bool { InboxItem.directed.contains(reason) }
    var shortRepo: String { repo.split(separator: "/").last.map(String.init) ?? repo }

    /// Short verb for the row, so the reason reads without an icon legend.
    var reasonLabel: String {
        switch reason {
        case "mention": return "mentioned you"
        case "team_mention": return "mentioned your team"
        case "review_requested": return "review requested"
        case "comment": return "comment"
        case "assign": return "assigned"
        case "author": return "your thread"
        case "state_change": return "state changed"
        case "ci_activity": return "CI"
        case "approval_requested": return "approval requested"
        case "manual": return "subscribed"
        case "subscribed": return "watching"
        default: return reason.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// Reasons that mean someone actually pulled you in, not repo watching or CI noise.
    static let involving: Set<String> = ["mention", "team_mention", "review_requested", "comment", "assign", "author", "state_change", "approval_requested", "manual"]
    static let directed: Set<String> = ["mention", "team_mention", "review_requested", "approval_requested"]
}

/// Inbox items grouped by calendar day, newest day first and newest item first within a day.
struct InboxDay: Identifiable {
    let day: Date
    let items: [InboxItem]
    var id: Date { day }

    var title: String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE MMM d")
        return f.string(from: day)
    }

    static func group(_ items: [InboxItem]) -> [InboxDay] {
        let cal = Calendar.current
        return Dictionary(grouping: items) { cal.startOfDay(for: $0.updatedAt) }
            .map { InboxDay(day: $0.key, items: $0.value.sorted { $0.updatedAt > $1.updatedAt }) }
            .sorted { $0.day > $1.day }
    }
}
