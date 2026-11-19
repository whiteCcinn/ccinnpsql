import Foundation
import PostgresKit
import Testing
@testable import CcinnPsqlKit

// Foundations of the knowledge base and backups: private atomic files, a lock shared by the app and `mcp`, and the
// profile fields knowledge and backups rely on.

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("ccinn-kb-\(UUID().uuidString)", isDirectory: true)
}

private func permissions(_ url: URL) throws -> Int {
    try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

@Suite("Secure files")
struct SecureFileTests {
    @Test func filesArePrivateFromTheFirstByteAndReplacedAtomically() throws {
        let directory = temporaryDirectory().appendingPathComponent("nested", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let url = directory.appendingPathComponent("index.json")
        try SecureFile.write(Data("one".utf8), to: url)
        #expect(try permissions(url) == 0o600)
        #expect(try permissions(directory) == 0o700, "missing directories are created private")
        try SecureFile.write(Data("two".utf8), to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "two")
        #expect(try permissions(url) == 0o600, "replacing keeps the file private")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0 != "index.json" }
        #expect(leftovers.isEmpty, "no temporary files are left behind: \(leftovers)")
    }

    @Test func anExistingDirectoryIsTightened() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try SecureFile.createDirectory(directory)
        #expect(try permissions(directory) == 0o700)
    }
}

@Suite("File lock", .serialized)
struct FileLockTests {
    // Each attempt opens the lock file itself, as the app and the `mcp` process do: flock serializes them.
    @Test func concurrentWritersLoseNoUpdate() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try SecureFile.createDirectory(directory)
        let lock = directory.appendingPathComponent(".lock")
        let counter = directory.appendingPathComponent("counter")
        try SecureFile.write(Data("0".utf8), to: counter)
        DispatchQueue.concurrentPerform(iterations: 40) { _ in
            try? FileLock.withLock(at: lock, timeout: .seconds(10)) {
                let value = Int((try? String(contentsOf: counter, encoding: .utf8)) ?? "") ?? -1000
                try SecureFile.write(Data("\(value + 1)".utf8), to: counter)
            }
        }
        #expect(try String(contentsOf: counter, encoding: .utf8) == "40")
    }

    @Test func aHeldLockTimesOut() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try SecureFile.createDirectory(directory)
        let lock = directory.appendingPathComponent(".lock")
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let holder = Thread {
            try? FileLock.withLock(at: lock, timeout: .seconds(5)) {
                held.signal()
                release.wait()
            }
        }
        holder.start()
        held.wait()
        let started = ContinuousClock.now
        #expect(throws: FileLock.Failure.busy(lock.path)) {
            try FileLock.withLock(at: lock, timeout: .milliseconds(200)) {}
        }
        #expect(ContinuousClock.now - started < .seconds(3))
        release.signal()
    }
}

@Suite("Profile fields for knowledge and backups")
struct KnowledgeProfileFieldTests {
    @Test func legacyProfilesDecodeWithDefaults() throws {
        let legacy = #"{"id":"0F9C2F34-6B1C-4C55-9E77-1B8C2E0A9D11","name":"prod","host":"fe","port":5432,"username":"u","createdAt":0}"#
        let profile = try JSONDecoder().decode(ConnectionProfile.self, from: Data(legacy.utf8))
        #expect(profile.updatedAt == nil)
        #expect(profile.mcpKnowledgeWrites == true, "AI knowledge writes default on (owner's decision)")
    }

    @Test func newFieldsRoundTrip() throws {
        var profile = ConnectionProfile(name: "prod", host: "db", port: 5432)
        profile.updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        profile.mcpKnowledgeWrites = false
        let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(profile))
        #expect(decoded.updatedAt == profile.updatedAt)
        #expect(decoded.mcpKnowledgeWrites == false)
    }

    @Test func historyDirectoryIsSharedWithTheMCPProcess() {
        #expect(QueryHistoryStore.defaultDirectory == ProfileRepository.defaultDirectory.appendingPathComponent("History", isDirectory: true))
    }
}
