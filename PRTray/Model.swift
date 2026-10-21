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
    var changesRequestedAt: Date? = nil
    var lastCommitAt: Date? = nil
    var pendingRequests = 0

    /// Changes requested, nobody re-requested, and nothing pushed since.
    var isReturned: Bool {
        guard reviewDecision == "CHANGES_REQUESTED", pendingRequests == 0 else { return false }
        guard let cr = changesRequestedAt else { return true }
        guard let c = lastCommitAt else { return true }
        return c < cr
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
