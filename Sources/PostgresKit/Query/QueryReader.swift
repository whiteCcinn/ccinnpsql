import Foundation
import PostgresWire

/// Reads the server's response to one command until ReadyForQuery, honouring `RowLimits` (design D5).
/// A server error is reported as `QueryFailure` once the session is aligned again.
struct QueryReader {
    let limits: RowLimits
    let run: PostgresConnection.RunContext
    let timeZone: String
    let extended: Bool
    var copySink: (@Sendable ([UInt8]) async throws -> Void)?

    static let maxNotices = 1_000
    static let maxNotifications = 10_000
    /// Rows still accepted (and discarded) after a row-limit cancel was sent.
    static let rowsAfterCancel = 10_000_000

    private var results: [ResultSet] = []
    private var notices: [ServerMessageFields] = []
    private var notifications: [NotificationMessage] = []
    private var parameterChanges: [String: String] = [:]
    private var serverError: ServerMessageFields?
    private var sinkError: (any Error)?
    private var transactionStatus: TransactionStatus = .idle
    private var completedStatements = 0
    /// When rows past the limit started to be skipped (bounds the drain by `drainSeconds`).
    private var drainStarted: ContinuousClock.Instant?
    private var cancelledForLimit = false
    private var limitCancelLanded = false

    // Row set being read.
    private var columns: [ColumnDescription]?
    private var formats: [FormatCode] = []
    private var rows: [[String?]] = []
    private var keptBytes = 0
    private var truncated = false
    private var discarded = 0
    /// Rows were promised by Describe(statement) (binary path): the next DataRows belong to them.
    private var pendingFields: [FieldDescription]?

    init(limits: RowLimits, run: PostgresConnection.RunContext, timeZone: String, extended: Bool) {
        self.limits = limits
        self.run = run
        self.timeZone = timeZone
        self.extended = extended
    }

    // MARK: Extended protocol, phase 1 (binary results)

    /// Reads ParseComplete, ParameterDescription and RowDescription/NoData after Parse+Describe+Flush.
    /// Returns `nil` after an error (having re-synchronised with Sync).
    mutating func readStatementDescription(_ channel: inout MessageChannel) async throws -> [FieldDescription]? {
        while true {
            let message = try await channel.read()
            switch try message.parse() {
            case .parseComplete, .parameterDescription:
                continue
            case let .rowDescription(fields):
                return fields
            case .noData:
                return []
            case let .errorResponse(fields):
                serverError = fields
                try await channel.send(FrontendMessage.sync)
                _ = try await readUntilReadyRaw(&channel)
                return nil
            case let .noticeResponse(fields):
                appendNotice(fields)
            case let .parameterStatus(name, value):
                parameterChanges[name] = value
            case let .notification(note):
                appendNotification(note)
            default:
                throw PostgresError(.protocolViolation, "Unexpected message while describing the statement")
            }
        }
    }

    /// The row layout for the Execute that follows a statement Describe.
    mutating func expectRows(fields: [FieldDescription], formats: [FormatCode]) {
        guard !fields.isEmpty else { return }
        pendingFields = fields
        self.formats = formats
    }

    // MARK: Main loop

    mutating func readUntilReady(_ channel: inout MessageChannel) async throws -> QueryResult {
        try await readUntilReadyRaw(&channel)
        return try finish()
    }

    /// The final outcome once ReadyForQuery was read: a result, or `QueryFailure` for a server error.
    func finish() throws -> QueryResult {
        if let sinkError { throw sinkError }
        if let serverError {
            throw QueryFailure(error: PostgresError.server(serverError), transactionStatus: transactionStatus,
                               parameters: parameterChanges, notices: notices, completedStatements: completedStatements)
        }
        var notices = notices
        if limitCancelLanded { notices.append(limitCancelWarning()) }
        return QueryResult(results: results, notices: notices, notifications: notifications, transactionStatus: transactionStatus,
                           parameterChanges: parameterChanges, completedStatements: completedStatements, cancelledAtRowLimit: limitCancelLanded)
    }

    /// Says truthfully what the cancel did: it is never a harmless truncation.
    private func limitCancelWarning() -> ServerMessageFields {
        let consequence = if transactionStatus == .failedTransaction {
            "the open transaction is now aborted; run ROLLBACK."
        } else if extended {
            "anything it changed was rolled back."
        } else {
            "the batch stopped at this statement and everything it had not committed was rolled back."
        }
        let message = "The result was cut at the row limit, and skipping the remaining rows took too long, so the statement was cancelled: "
            + consequence
        return ServerMessageFields(fields: [UInt8(ascii: "S"): "WARNING", UInt8(ascii: "V"): "WARNING", UInt8(ascii: "M"): message])
    }

    private mutating func readUntilReadyRaw(_ channel: inout MessageChannel) async throws {
        while true {
            let message = try await channel.read()
            if message.type == 0x44 { // DataRow: hot path
                try appendRow(message.payload, channel: &channel)
                continue
            }
            switch try message.parse() {
            case let .rowDescription(fields):
                finishRowSet(tag: nil)
                beginRowSet(fields.map { ColumnDescription($0, format: extended && pendingFields != nil ? .binary : $0.format) },
                            formats: fields.map(\.format))
            case .bindComplete:
                if let fields = pendingFields {
                    beginRowSet(zip(fields, formats).map { ColumnDescription($0.0, format: $0.1) }, formats: formats)
                    pendingFields = nil
                }
            case let .commandComplete(tag):
                completedStatements += 1
                finishRowSet(tag: CommandTag(tag))
            case .portalSuspended:
                // Execute's row count was reached: more rows may exist.
                truncated = true
                finishRowSet(tag: nil)
            case .emptyQueryResponse:
                finishRowSet(tag: nil)
            case .parseComplete, .closeComplete, .noData, .parameterDescription:
                continue
            case let .errorResponse(fields):
                if fields.sqlState == "57014", run.cancellation == .rowLimit {
                    // We stopped the statement ourselves after draining for too long: the rows are kept, and
                    // `finish()` reports what the server rolled back.
                    truncated = true
                    limitCancelLanded = true
                    finishRowSet(tag: nil)
                } else if serverError == nil {
                    serverError = fields
                }
                finishRowSet(tag: nil)
            case let .noticeResponse(fields):
                appendNotice(fields)
            case let .notification(note):
                appendNotification(note)
            case let .parameterStatus(name, value):
                parameterChanges[name] = value
            case .copyInResponse:
                // COPY FROM STDIN needs data we do not have: fail it so the server returns to normal.
                try await channel.send(FrontendMessage.copyFail("COPY FROM STDIN is not supported by CcinnPsql")
                    + (extended ? FrontendMessage.sync : []))
            case .copyOutResponse:
                finishRowSet(tag: nil)
                if copySink == nil {
                    beginRowSet([ColumnDescription(name: "COPY", typeOID: PostgresType.text.oid)], formats: [.text])
                }
            case let .copyData(payload):
                try await handleCopyData(payload, channel: &channel)
            case .copyDone:
                continue
            case .copyBothResponse:
                throw PostgresError(.unsupported, "Replication (CopyBoth) streams are not supported")
            case let .readyForQuery(status):
                finishRowSet(tag: nil)
                transactionStatus = status
                return
            case .authentication, .backendKeyData, .negotiateProtocolVersion, .functionCallResponse, .dataRow:
                throw PostgresError(.protocolViolation, "Unexpected message while reading results")
            case .unknown:
                continue
            }
        }
    }

    // MARK: Row sets

    private mutating func beginRowSet(_ newColumns: [ColumnDescription], formats newFormats: [FormatCode]) {
        columns = newColumns
        formats = newFormats
        rows = []
        keptBytes = 0
        truncated = false
        discarded = 0
    }

    private mutating func finishRowSet(tag: CommandTag?) {
        if let columns {
            results.append(ResultSet(columns: columns, rows: rows, commandTag: tag, isTruncated: truncated))
            self.columns = nil
            rows = []
            truncated = false
        } else if let tag {
            results.append(.command(tag))
        }
    }

    private mutating func appendRow(_ payload: ArraySlice<UInt8>, channel: inout MessageChannel) throws {
        guard let columns else { throw PostgresError(.protocolViolation, "DataRow without RowDescription") }
        if truncated || rows.count >= limits.maxRows || keptBytes + payload.count > limits.maxBytes {
            truncated = true
            discarded += 1
            try skipOrCancel()
            return
        }
        let cells = try DataRow.cells(payload)
        guard cells.count == columns.count else {
            throw PostgresError(.protocolViolation, "DataRow has \(cells.count) values for \(columns.count) columns")
        }
        var row: [String?] = []
        row.reserveCapacity(cells.count)
        for (index, cell) in cells.enumerated() {
            guard let cell else {
                row.append(nil)
                continue
            }
            if index < formats.count, formats[index] == .binary {
                row.append(BinaryValue.canonicalText(cell, type: columns[index].typeOID, timeZone: timeZone)
                    ?? "\\x" + cell.map { String(format: "%02x", $0) }.joined())
            } else {
                row.append(String(decoding: cell, as: UTF8.self))
            }
        }
        rows.append(row)
        keptBytes += payload.count
    }

    private mutating func handleCopyData(_ payload: ArraySlice<UInt8>, channel: inout MessageChannel) async throws {
        if let copySink {
            guard sinkError == nil else { return }
            do {
                try await copySink(Array(payload))
            } catch {
                sinkError = error
                run.canceller.cancel(generation: run.generation, reason: .task)
            }
            return
        }
        guard columns != nil else { return }
        var line = payload
        if line.last == 0x0A { line = line.dropLast() }
        if !truncated, rows.count < limits.maxRows, keptBytes + line.count <= limits.maxBytes {
            rows.append([String(decoding: line, as: UTF8.self)])
            keptBytes += line.count
        } else {
            truncated = true
            discarded += 1
            try skipOrCancel()
        }
    }

    /// Rows past the limit are skipped, not cancelled: a cancel aborts the statement's transaction (and, in a
    /// simple-protocol batch, everything the batch has not committed). Only a drain that exceeds its row or time
    /// budget is cancelled; a server that keeps sending far beyond that is dropped.
    private mutating func skipOrCancel() throws {
        let now = ContinuousClock.now
        let started = drainStarted ?? now
        drainStarted = started
        if !cancelledForLimit, discarded > limits.drainRows || now - started > .milliseconds(Int(limits.drainSeconds * 1000)) {
            cancelledForLimit = true
            run.cancelForRowLimit()
        }
        // After the cancel the server stops within its latency; the cancel's grace period closes the socket of
        // one that does not. This cap only guards against a server streaming rows faster than that forever.
        if discarded > limits.drainRows + Self.rowsAfterCancel {
            throw PostgresError(.protocolViolation, "The server kept sending rows after the statement was cancelled")
        }
    }

    private mutating func appendNotice(_ fields: ServerMessageFields) {
        if notices.count < Self.maxNotices { notices.append(fields) }
    }

    private mutating func appendNotification(_ note: NotificationMessage) {
        if notifications.count < Self.maxNotifications { notifications.append(note) }
        run.notify?(note)
    }
}
