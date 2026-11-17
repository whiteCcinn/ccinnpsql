import CcinnPsqlKit
import Foundation
import Observation

/// The tab Format SQL works for: its text and selection (used while no editor is attached, such as a tab opened from
/// launch arguments), and where each outcome is reported.
@MainActor
protocol SQLFormatHost: AnyObject {
    var text: String { get set }
    var selection: NSRange { get set }
    func formatDidFinish(_ outcome: SQLFormatRunner.Outcome)
}

/// Runs Format SQL for one editor: takes the text the user sees, formats it off the main actor (an edit cancels the work),
/// and applies the result as one undoable edit only to exactly that text, never while an input method is composing.
/// Every outcome is reported, so a refused format is never silent.
@MainActor
@Observable
final class SQLFormatRunner {
    enum Outcome: Equatable {
        case formatted
        case alreadyFormatted
        /// An input method is composing: the marked text is not part of the document yet.
        case composing
        /// The text changed while it was being formatted (or the editor no longer shows the text it was formatted from).
        case textChanged
        /// The result could not be proven to mean the same as the input.
        case notEquivalent
        case tooComplex
        /// Whitespace PostgreSQL versions read differently (a vertical tab).
        case versionDependent
        /// A NUL character, which cannot be sent.
        case nulCharacter
        case invalidSelection

        /// What the status line says; `nil` when the edit shows itself.
        var status: (message: String, isError: Bool)? {
            switch self {
            case .formatted: nil
            case .alreadyFormatted: ("Already formatted", false)
            case .composing: ("Formatting skipped: finish the text the input method is composing first", true)
            case .textChanged: ("Formatting skipped: the text changed while it was being formatted", true)
            case .notEquivalent: ("Formatting skipped: the result could not be proven to mean the same", true)
            case .tooComplex: ("Formatting skipped: the SQL is nested too deeply or would grow too much", true)
            case .versionDependent: ("Formatting skipped: the text has a vertical tab, which PostgreSQL 13 rejects and later versions accept", true)
            case .nulCharacter: ("Formatting skipped: the text has a NUL character, which can't be sent to PostgreSQL", true)
            case .invalidSelection: ("Formatting skipped: the selection is outside the text", true)
            }
        }

        init(_ error: SQLFormatError) {
            switch error {
            case .notEquivalent: self = .notEquivalent
            case .tooComplex: self = .tooComplex
            case .invalidSelection: self = .invalidSelection
            case .versionDependent: self = .versionDependent
            case .nulCharacter: self = .nulCharacter
            case .cancelled: self = .textChanged // only an edit (or a closing tab, which reports nothing) cancels
            }
        }
    }

    /// Formats `text`, or the part of it in `selection` (widened to whole tokens) when there is one.
    typealias Formatter = @Sendable (_ text: String, _ selection: NSRange?, _ options: SQLFormatOptions)
        -> Result<SQLFormatReplacement, SQLFormatError>

    static let standard: Formatter = { text, selection, options in
        do throws(SQLFormatError) {
            if let selection { return .success(try SQLFormatter.formatSelection(in: text, range: selection, options: options)) }
            return .success(SQLFormatReplacement(range: NSRange(location: 0, length: (text as NSString).length),
                                                 text: try SQLFormatter.formatted(text, options: options)))
        } catch {
            return .failure(error)
        }
    }

    private(set) var isRunning = false
    /// Set once the tab exists (it owns this runner).
    @ObservationIgnored weak var host: (any SQLFormatHost)?
    @ObservationIgnored private let editor: SQLEditorController
    @ObservationIgnored private let formatter: Formatter
    @ObservationIgnored private var task: Task<Void, Never>?

    init(editor: SQLEditorController, formatter: @escaping Formatter = SQLFormatRunner.standard) {
        self.editor = editor
        self.formatter = formatter
    }

    convenience init(editor: SQLEditorController, host: any SQLFormatHost, formatter: @escaping Formatter = SQLFormatRunner.standard) {
        self.init(editor: editor, formatter: formatter)
        self.host = host
    }

    /// Starts formatting the selection, or the whole text when nothing is selected. Returns the running work (tests await
    /// it); `nil` when nothing started: a format is already running, or an input method is composing (reported).
    @discardableResult
    func format(options: SQLFormatOptions) -> Task<Void, Never>? {
        guard task == nil, let host else { return nil }
        let snapshot: (text: String, selection: NSRange)
        if editor.textView != nil {
            guard let live = editor.snapshot() else {
                host.formatDidFinish(.composing)
                return nil
            }
            snapshot = live
        } else {
            snapshot = (host.text, host.selection)
        }
        let source = snapshot.text
        let cursor = snapshot.selection
        let length = (source as NSString).length
        let selection = cursor.length > 0 && cursor.location >= 0 && cursor.location <= length && cursor.length <= length - cursor.location
            ? cursor : nil
        let formatter = formatter
        let job = Task.detached(priority: .userInitiated) { formatter(source, selection, options) }
        isRunning = true
        let work = Task { [weak self] in
            let result = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            guard let self, !Task.isCancelled else { return } // cancelled: `cancel` reported it
            self.task = nil
            self.isRunning = false
            self.apply(result, source: source, cursor: cursor, formatsSelection: selection != nil)
        }
        task = work
        return work
    }

    /// Stops a running format: the text it started from is being edited (`reportingChange`), or the tab closes.
    func cancel(reportingChange: Bool) {
        guard let task else { return }
        task.cancel()
        self.task = nil
        isRunning = false
        if reportingChange { host?.formatDidFinish(.textChanged) }
    }

    private func apply(_ result: Result<SQLFormatReplacement, SQLFormatError>, source: String, cursor: NSRange, formatsSelection: Bool) {
        guard let host else { return }
        let replacement: SQLFormatReplacement
        switch result {
        case let .success(value): replacement = value
        case let .failure(error): return host.formatDidFinish(Outcome(error))
        }
        let original = source as NSString
        let range = replacement.range
        guard range.location >= 0, range.length >= 0, range.location <= original.length, range.length <= original.length - range.location else {
            return host.formatDidFinish(.invalidSelection)
        }
        guard replacement.text != original.substring(with: replacement.range) else { return host.formatDidFinish(.alreadyFormatted) }
        let newSelection = formatsSelection
            ? NSRange(location: replacement.range.location, length: (replacement.text as NSString).length)
            : NSRange(location: SQLFormatter.mapOffset(cursor.location, from: source, to: replacement.text), length: 0)
        switch editor.replace(replacement.range, in: source, with: replacement.text, actionName: "Format SQL", selecting: newSelection) {
        case .replaced:
            host.formatDidFinish(.formatted)
        case .refused:
            host.formatDidFinish(.textChanged)
        case .detached:
            guard host.text == source else { return host.formatDidFinish(.textChanged) }
            host.text = original.replacingCharacters(in: replacement.range, with: replacement.text)
            host.selection = newSelection
            host.formatDidFinish(.formatted)
        }
    }
}
