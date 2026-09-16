import XCTest
@testable import NotesToNotion

final class AppErrorTests: XCTestCase {
    /// 2026-09-16 incident: a 503 (server overload) was reported to the
    /// user as "quota is used up," which was false and sent them chasing
    /// the wrong fix. These two cases must never share wording again.
    func testOverloadedAndRateLimitedMessagesDoNotClaimTheSameThing() {
        let overloadedMessage = AppError.geminiOverloaded.errorDescription ?? ""
        let rateLimitedMessage = AppError.geminiRateLimited(retryAfterSeconds: nil).errorDescription ?? ""

        // The 503 case may still mention "quota" to explicitly rule it out
        // (e.g. "not a quota issue") — what must never happen again is it
        // asserting quota exhaustion as the cause, the way the 429 case does.
        XCTAssertTrue(rateLimitedMessage.localizedCaseInsensitiveContains("quota is used up"))
        XCTAssertFalse(overloadedMessage.localizedCaseInsensitiveContains("quota is used up"))
        XCTAssertFalse(overloadedMessage.localizedCaseInsensitiveContains("quota ran out"))
    }

    func testRateLimitedMessageMentionsTheTranscriptIsSafe() {
        let message = AppError.geminiRateLimited(retryAfterSeconds: 30).errorDescription ?? ""
        XCTAssertTrue(message.localizedCaseInsensitiveContains("saved locally"))
    }

    func testOverloadedMessageMentionsTheTranscriptIsSafe() {
        let message = AppError.geminiOverloaded.errorDescription ?? ""
        XCTAssertTrue(message.localizedCaseInsensitiveContains("saved locally"))
    }
}
