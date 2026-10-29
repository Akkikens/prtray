import Foundation

/// "Returned to you": changes requested, nobody re-requested, and no real push since the
/// reviewers who asked for changes last spoke. Pure so it can be unit tested.
enum ReturnedRule {
    struct Review { let author: String; let isBot: Bool; let state: String; let at: Date }
    struct Commit { let at: Date; let parents: Int }

    static let decisive: Set<String> = ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"]

    /// Latest review of any state (COMMENTED included) from each human reviewer whose
    /// latest decisive review is CHANGES_REQUESTED; the max of those.
    static func returnedAt(reviews: [Review], prAuthor: String) -> Date? {
        let byReviewer = Dictionary(grouping: reviews.filter {
            !$0.isBot && $0.author.lowercased() != prAuthor.lowercased()
        }, by: { $0.author.lowercased() })
        return byReviewer.values.compactMap { rs -> Date? in
            let sorted = rs.sorted { $0.at < $1.at }
            guard sorted.last(where: { decisive.contains($0.state) })?.state == "CHANGES_REQUESTED" else { return nil }
            return sorted.last?.at
        }.max()
    }

    /// Newest non-merge commit, so merging main into the branch does not count as a push.
    static func lastCommitAt(_ commits: [Commit]) -> Date? {
        commits.filter { $0.parents < 2 }.map(\.at).max()
    }

    static func isReturned(decision: String?, pendingRequests: Int, returnedAt: Date?, lastCommitAt: Date?) -> Bool {
        guard decision == "CHANGES_REQUESTED", pendingRequests == 0 else { return false }
        guard let r = returnedAt, let c = lastCommitAt else { return true }
        return c < r
    }
}
