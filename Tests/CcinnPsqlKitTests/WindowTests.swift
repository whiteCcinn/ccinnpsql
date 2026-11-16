import Foundation
import Testing
@testable import CcinnPsqlKit

@Suite("Window requests")
struct WindowRequestTests {
    @Test func everyRequestOpensItsOwnWindow() {
        let profile = UUID()
        // SwiftUI brings an existing window to the front when the value is equal, so two requests for the same
        // connection must differ.
        #expect(WindowRequest(profileID: profile) != WindowRequest(profileID: profile))
        #expect(WindowRequest(profileID: profile).profileID == profile)
    }

    @Test func roundTripsThroughCodable() throws {
        let request = WindowRequest(profileID: UUID())
        let decoded = try JSONDecoder().decode(WindowRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded == request)
    }

    @Test func decodesWithoutTheNonce() throws {
        let profile = UUID()
        let decoded = try JSONDecoder().decode(WindowRequest.self, from: Data(#"{"profileID":"\#(profile.uuidString)"}"#.utf8))
        #expect(decoded.profileID == profile)
    }

    @Test func rejectsARequestWithoutAProfile() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(WindowRequest.self, from: Data(#"{"nonce":"\#(UUID().uuidString)"}"#.utf8))
        }
    }
}

@MainActor
@Suite("Window handoff")
struct WindowHandoffTests {
    @Test func aPayloadIsTakenExactlyOnce() {
        let handoff = WindowHandoff<String>()
        let request = handoff.request(profileID: UUID(), payload: "secret")
        #expect(handoff.pendingCount == 1)
        #expect(handoff.take(request) == "secret")
        #expect(handoff.take(request) == nil, "a second window must not reuse the connection")
        #expect(handoff.pendingCount == 0)
    }

    @Test func restoredRequestsCarryNothing() throws {
        // A request decoded after a relaunch (window restoration) was not created by this process.
        let handoff = WindowHandoff<String>()
        #expect(handoff.take(WindowRequest(profileID: UUID())) == nil)
        let handed = handoff.request(profileID: UUID(), payload: "secret")
        let restored = try JSONDecoder().decode(WindowRequest.self, from: Data(#"{"profileID":"\#(handed.profileID.uuidString)"}"#.utf8))
        #expect(handoff.take(restored) == nil, "a request without this process's nonce must not connect")
        #expect(handoff.pendingCount == 1, "a restored request must not consume another window's connection")
    }

    @Test func aRestoredRequestFallsThroughLikeNoRequest() throws {
        // A window opened without a request (⌘N) and one macOS restored take the same path: the connection screen,
        // and the launch arguments if no window applied them yet. The handoff answers both the same way.
        let handoff = WindowHandoff<String>()
        _ = handoff.request(profileID: UUID(), payload: "secret")
        let restored = try JSONDecoder().decode(WindowRequest.self, from: JSONEncoder().encode(WindowRequest(profileID: UUID())))
        let noRequest: WindowRequest? = nil
        #expect(handoff.take(noRequest) == nil)
        #expect(handoff.take(Optional(restored)) == nil)
        #expect(handoff.pendingCount == 1)
    }

    @Test func requestsForTheSameProfileAreIndependent() {
        let handoff = WindowHandoff<String>()
        let profile = UUID()
        let first = handoff.request(profileID: profile, payload: "a")
        let second = handoff.request(profileID: profile, payload: "b")
        #expect(first != second)
        #expect(first.profileID == profile && second.profileID == profile)
        #expect(handoff.take(second) == "b")
        #expect(handoff.take(first) == "a")
        #expect(handoff.pendingCount == 0)
    }
}
