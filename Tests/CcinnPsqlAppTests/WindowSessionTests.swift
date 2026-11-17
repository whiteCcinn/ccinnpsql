import CcinnPsqlKit
import Foundation
import PostgresKit
import Testing
@testable import CcinnPsql

/// Releases a waiting opener once, whatever task cancellation says (progress reports can come from work that does not
/// check for cancellation, such as an SSH process step).
private actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

@Suite("Window session", .serialized)
@MainActor
struct WindowSessionTests {
    private func store() -> ProfileStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnpsql-window-\(UUID().uuidString)")
        return ProfileStore(repository: ProfileRepository(directory: directory, secrets: InMemorySecretStore()))
    }

    // A connect that was superseded (a second Connect, a double-click) cannot overwrite the new connect's status.
    @Test func aSupersededConnectCannotReportIntoTheNewOne() async throws {
        let released = Gate()
        let finished = Gate()
        let session = WindowSession(opener: { profile, _, _, progress in
            if profile.name == "first" {
                await released.wait()
                progress("Opening SSH tunnel…")
                await finished.open()
                throw CancellationError()
            }
            progress("Authenticating…")
            try await Task.sleep(for: .seconds(30))
            throw CancellationError()
        })
        let store = store()
        session.connect(profile: ConnectionProfile(name: "first"), store: store, password: "x")
        session.connect(profile: ConnectionProfile(name: "second"), store: store, password: "x")
        for _ in 0..<50 {
            if case .connecting(_, "Authenticating…") = session.phase { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await released.open()
        await finished.wait()
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(10)) } // the late report's main-actor hop
        guard case let .connecting(name, status) = session.phase else {
            Issue.record("expected to be connecting, got \(session.phase)")
            return
        }
        #expect(name == "second")
        #expect(status == "Authenticating…")
        #expect(session.connectError == nil)
        session.cancelConnecting()
        #expect(session.workspace == nil)
    }

    // After Cancel, a late report from the cancelled connect does not bring the connecting screen back.
    @Test func aCancelledConnectStaysCancelled() async throws {
        let released = Gate()
        let finished = Gate()
        let session = WindowSession(opener: { _, _, _, progress in
            await released.wait()
            progress("Opening SSH tunnel…")
            await finished.open()
            throw CancellationError()
        })
        session.connect(profile: ConnectionProfile(name: "only"), store: store(), password: "x")
        session.cancelConnecting()
        await released.open()
        await finished.wait()
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(10)) }
        guard case .connections = session.phase else {
            Issue.record("expected the connection screen, got \(session.phase)")
            return
        }
        #expect(session.connectError == nil)
    }
}
