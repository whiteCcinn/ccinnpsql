import Foundation
import os
import Testing
@testable import CcinnPsqlKit

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func table(_ name: String, _ columns: [String], unique: [[String]] = []) -> TableFacts {
    TableFacts(name: name, kind: .table, comment: "about \(name)",
               keys: TableFacts.Keys(primary: ["id"], unique: unique),
               columns: columns.map { ColumnFacts(name: $0, type: "bigint", isKey: $0 == "id", comment: "column \($0)") },
               fingerprint: "fp-" + name, state: .fresh, firstSeen: now)
}

/// An administrator's knowledge of `hr`: `employees(id, name, salary, manager_id, "Grade")` and `dsp(id)`.
private func knowledge() -> DatabaseKnowledge {
    var knowledge = DatabaseKnowledge(key: DatabaseKey(cluster: ClusterKey(rawValue: "pg://db:5432"), catalog: "app", database: "hr"))
    knowledge.tables = [table("employees", ["id", "name", "salary", "manager_id", "Grade"], unique: [["name"], ["salary", "id"]]), table("dsp", ["id"])]
    knowledge.relationships = [
        Relationship(from: .init(table: "employees", columns: ["manager_id"]), to: .init(table: "employees", columns: ["id"]), kind: .manyToOne,
                     evidence: [Evidence(source: .user, by: "user", at: now)]),
        Relationship(from: .init(table: "employees", columns: ["id"]), to: .init(table: "dsp", columns: ["id"]), kind: .oneToOne,
                     evidence: [Evidence(source: .naming, score: 55, at: now)]),
    ]
    knowledge.notes = [
        Note(id: "n-salary", table: "employees", column: "salary", kind: .caveat, text: "includes bonus", evidence: [], by: "user", at: now, fingerprint: nil),
        Note(id: "n-name", table: "employees", column: "name", kind: .description, text: "legal name", evidence: [], by: "user", at: now, fingerprint: nil),
        Note(id: "n-table", table: "employees", column: nil, kind: .description, text: "one row per person", evidence: [], by: "user", at: now, fingerprint: nil),
    ]
    knowledge.terms = [
        Term(id: "t-pay", term: "pay", synonyms: [], definition: "x", mapsTo: [.init(table: "employees", column: "salary")], by: "user", at: now),
        Term(id: "t-cost", term: "cost", synonyms: [], definition: "x", mapsTo: [.init(table: "employees", expression: "SUM(salary)")], by: "user", at: now),
        Term(id: "t-staff", term: "staff", synonyms: [], definition: "x", mapsTo: [.init(table: "employees", column: "name")], by: "user", at: now),
        Term(id: "t-dsp", term: "dsp count", synonyms: [], definition: "x", mapsTo: [.init(table: "dsp", expression: "COUNT(*)")], by: "user", at: now),
    ]
    return knowledge
}

@Suite("Knowledge visibility: column grants")
struct KnowledgeColumnVisibilityTests {
    // GRANT SELECT (id, name) ON employees: pg_catalog still lists every column, so the filter must hide the rest and
    // everything that mentions them.
    @Test func hiddenColumnsTakeTheirCommentsKeysNotesTermsAndRelationshipsAlong() {
        let visibility = KnowledgeVisibility(columns: ["employees": ["id", "name"], "dsp": nil])
        let filtered = KnowledgeMCP.filter(knowledge(), visibility: visibility)
        let employees = filtered.table(named: "employees")
        #expect(employees?.columns.map(\.name) == ["id", "name"])
        #expect(employees?.keys.primary == ["id"] && employees?.keys.unique == [["name"]], "a key with a hidden column would reveal it")
        #expect(filtered.notes.map(\.id) == ["n-name", "n-table"])
        #expect(filtered.terms.map(\.id) == ["t-staff", "t-dsp"], "a column or an expression the role may not read hides the mapping")
        #expect(filtered.relationships.count == 1 && filtered.relationships.first?.to.table == "dsp")
        let encoded = String(decoding: (try? KnowledgeStore.encoder.encode(filtered)) ?? Data(), as: UTF8.self)
        #expect(!encoded.contains("salary") && !encoded.contains("manager_id") && !encoded.contains("bonus"))
    }

    // PostgreSQL names are case-sensitive: reading "grade" says nothing about "Grade".
    @Test func columnNamesAreComparedExactly() {
        let visibility = KnowledgeVisibility(columns: ["employees": ["id", "grade"]])
        #expect(visibility.contains("employees", column: "grade") && !visibility.contains("employees", column: "Grade"))
        #expect(KnowledgeMCP.filter(knowledge(), visibility: visibility).table(named: "employees")?.columns.map(\.name) == ["id"])
    }

    @Test func aTableLevelGrantShowsEveryColumn() {
        let filtered = KnowledgeMCP.filter(knowledge(), visibility: KnowledgeVisibility(tables: ["employees", "dsp"]))
        #expect(filtered == knowledge())
        #expect(KnowledgeMCP.filter(knowledge(), visible: ["employees", "dsp"]) == knowledge(), "the table-only form still works")
    }

    @Test func anotherSchemasHiddenColumnHidesTheRelationship() {
        var base = knowledge()
        base.relationships = [Relationship(from: .init(table: "dsp", columns: ["id"]), to: .init(database: "admin", table: "owners", columns: ["secret_id"]),
                                           kind: .manyToOne, evidence: [Evidence(source: .ai, at: now)])]
        let readable = KnowledgeVisibility(columns: ["owners": ["secret_id"]])
        let hidden = KnowledgeVisibility(columns: ["owners": ["id"]])
        let visibility = KnowledgeVisibility(tables: ["employees", "dsp"])
        #expect(KnowledgeMCP.filter(base, visibility: visibility, visibilityOther: ["admin": readable]).relationships.count == 1)
        #expect(KnowledgeMCP.filter(base, visibility: visibility, visibilityOther: ["admin": hidden]).relationships.isEmpty)
    }
}

@Suite("Knowledge: .git/config")
struct KnowledgeGitConfigTests {
    private func checkout() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnpsql-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".git"), withIntermediateDirectories: true)
        return directory
    }

    // A hostile checkout's .git/config must not hang a link: it is read for link_project and remapping.
    @Test func onlyABoundedRegularFileIsRead() async throws {
        let fifo = try checkout()
        defer { try? FileManager.default.removeItem(at: fifo) }
        #expect(mkfifo(fifo.appendingPathComponent(".git/config").path, 0o600) == 0)
        let fromFIFO = await withinSeconds(5) { () -> String? in KnowledgeMCP.gitRemote(of: fifo.path) }
        #expect(fromFIFO == .some(nil), "a FIFO is not read (opening it to read blocks)")

        let link = try checkout()
        defer { try? FileManager.default.removeItem(at: link) }
        try FileManager.default.createSymbolicLink(atPath: link.appendingPathComponent(".git/config").path, withDestinationPath: "/dev/zero")
        let fromLink = await withinSeconds(5) { () -> String? in KnowledgeMCP.gitRemote(of: link.path) }
        #expect(fromLink == .some(nil), "a link to a device is not followed")

        let huge = try checkout()
        defer { try? FileManager.default.removeItem(at: huge) }
        try (String(repeating: "#", count: 200_000) + "\n[remote \"origin\"]\n\turl = https://example.com/x.git\n")
            .write(to: huge.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)
        #expect(KnowledgeMCP.gitRemote(of: huge.path) == nil, "an oversized config is not read")
    }
}

/// `body` on a thread of its own; nil when it has not returned within `seconds` (the thread is left behind).
private func withinSeconds<T: Sendable>(_ seconds: Double, _ body: @escaping @Sendable () -> T) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let once = OSAllocatedUnfairLock(initialState: false)
        let finish = { @Sendable (value: T?) -> Void in
            let first = once.withLock { (done: inout Bool) -> Bool in
                defer { done = true }
                return !done
            }
            if first { continuation.resume(returning: value) }
        }
        let thread = Thread { finish(body()) }
        thread.start()
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { finish(nil) }
    }
}
