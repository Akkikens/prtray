import XCTest

final class ReturnedRuleTests: XCTestCase {
    private let iso = ISO8601DateFormatter()
    private func t(_ s: String) -> Date { iso.date(from: s)! }
    private func review(_ who: String, _ state: String, _ at: String, bot: Bool = false) -> ReturnedRule.Review {
        ReturnedRule.Review(author: who, isBot: bot, state: state, at: t(at))
    }
    private func commit(_ at: String, merge: Bool = false) -> ReturnedRule.Commit {
        ReturnedRule.Commit(at: t(at), parents: merge ? 2 : 1)
    }
    private func returned(_ reviews: [ReturnedRule.Review], _ commits: [ReturnedRule.Commit], pending: Int = 0) -> Bool {
        ReturnedRule.isReturned(decision: "CHANGES_REQUESTED", pendingRequests: pending,
                                returnedAt: ReturnedRule.returnedAt(reviews: reviews, prAuthor: "me"),
                                lastCommitAt: ReturnedRule.lastCommitAt(commits))
    }

    // Real case: changes requested, author pushed and re-requested, reviewer came back with a
    // COMMENTED review (which clears the request) asking for more, then the author merged main.
    func testCommentedFollowUpAfterPushIsReturned() {
        let reviews = [
            review("github-actions", "COMMENTED", "2026-10-22T05:34:25Z", bot: true),
            review("alice", "APPROVED", "2026-10-22T08:12:38Z"),
            review("bob", "CHANGES_REQUESTED", "2026-10-26T12:38:39Z"),
            review("bob", "COMMENTED", "2026-10-27T10:15:20Z"),
        ]
        let commits = [
            commit("2026-10-26T17:12:24Z"),
            commit("2026-10-29T06:30:39Z", merge: true),
        ]
        XCTAssertEqual(ReturnedRule.returnedAt(reviews: reviews, prAuthor: "me"), t("2026-10-27T10:15:20Z"))
        XCTAssertTrue(returned(reviews, commits))
    }

    func testAuthorPushAfterCommentedReviewIsNotReturned() {
        let reviews = [
            review("bob", "CHANGES_REQUESTED", "2026-10-26T12:38:39Z"),
            review("bob", "COMMENTED", "2026-10-27T10:15:20Z"),
        ]
        XCTAssertFalse(returned(reviews, [commit("2026-10-26T17:12:24Z"), commit("2026-10-28T09:00:00Z")]))
    }

    func testMergeFromMainAfterReviewIsStillReturned() {
        let reviews = [review("alice", "CHANGES_REQUESTED", "2026-10-26T12:00:00Z")]
        let commits = [commit("2026-10-25T12:00:00Z"), commit("2026-10-27T12:00:00Z", merge: true)]
        XCTAssertEqual(ReturnedRule.lastCommitAt(commits), t("2026-10-25T12:00:00Z"))
        XCTAssertTrue(returned(reviews, commits))
    }

    func testPendingReRequestIsNotReturned() {
        let reviews = [review("alice", "CHANGES_REQUESTED", "2026-10-26T12:00:00Z")]
        XCTAssertFalse(returned(reviews, [commit("2026-10-25T12:00:00Z")], pending: 1))
    }

    func testIgnoresAuthorBotsAndReviewersWhoApprovedSince() {
        let reviews = [
            review("alice", "CHANGES_REQUESTED", "2026-10-26T12:00:00Z"),
            review("alice", "APPROVED", "2026-10-28T12:00:00Z"),
            review("me", "COMMENTED", "2026-10-28T13:00:00Z"),
            review("copilot", "COMMENTED", "2026-10-28T14:00:00Z", bot: true),
            review("bob", "CHANGES_REQUESTED", "2026-10-27T12:00:00Z"),
        ]
        XCTAssertEqual(ReturnedRule.returnedAt(reviews: reviews, prAuthor: "me"), t("2026-10-27T12:00:00Z"))
    }

    func testNotChangesRequestedIsNotReturned() {
        XCTAssertFalse(ReturnedRule.isReturned(decision: "REVIEW_REQUIRED", pendingRequests: 0, returnedAt: nil, lastCommitAt: nil))
    }
}
