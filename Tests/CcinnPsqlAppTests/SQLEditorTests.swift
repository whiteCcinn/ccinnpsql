import AppKit
import CcinnPsqlKit
import SwiftUI
import Testing
@testable import CcinnPsql

/// An editor wired like `SQLWorkbenchView` wires it, with the binding and the model's diagnostics held
/// here, so tests can play the model's part (including lagging behind the text view).
@MainActor
private final class EditorHarness {
    var text: String
    var selection = NSRange(location: 0, length: 0)
    var diagnostics: [SQLDiagnostic] = []
    var reportedEdits: [SQLTextEdit] = []
    let textView: SQLTextView
    let coordinator: SQLEditor.Coordinator
    private let window: NSWindow

    init(_ text: String, diagnostics: [SQLDiagnostic] = []) {
        self.text = text
        self.diagnostics = diagnostics
        textView = SQLTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        coordinator = SQLEditor.Coordinator(SQLEditor(text: .constant(text), selection: .constant(selection)))
        coordinator.parent = editor
        textView.coordinator = coordinator
        textView.delegate = coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.string = text
        textView.textStorage?.delegate = coordinator
        coordinator.textView = textView
        coordinator.diagnostics = diagnostics
        window.contentView = textView
        window.makeFirstResponder(textView)
    }

    var editor: SQLEditor {
        SQLEditor(text: Binding(get: { self.text }, set: { self.text = $0 }),
                  selection: Binding(get: { self.selection }, set: { self.selection = $0 }),
                  diagnostics: diagnostics,
                  onEdit: { self.reportedEdits += $0 })
    }

    /// What SwiftUI does on every re-render of the workbench.
    func render() { coordinator.update(from: editor) }

    func type(_ string: String, at location: Int) {
        textView.setSelectedRange(NSRange(location: location, length: 0))
        selection = textView.selectedRange()
        textView.insertText(string, replacementRange: textView.selectedRange())
    }
}

@Suite("SQL editor", .serialized)
@MainActor
struct SQLEditorTests {
    @Test func formattingIsOneUndoableEditThatEditTrackingSees() throws {
        let original = "select a, b from t where x = 'it''s'"
        let failure = SQLDiagnostic(range: 7..<8, scope: 0..<36, severity: .error, source: .server, message: "m")
        let harness = EditorHarness(original, diagnostics: [failure])
        let undo = try #require(harness.textView.undoManager)
        undo.groupsByEvent = false
        let formatted = try #require(SQLFormatter.format(original))
        undo.beginUndoGrouping()
        #expect(harness.textView.replace(NSRange(location: 0, length: (original as NSString).length), in: original, with: formatted,
                                         actionName: "Format SQL", selecting: NSRange(location: 3, length: 0)))
        undo.endUndoGrouping()
        #expect(harness.textView.string == formatted)
        #expect(harness.text == formatted, "the binding is updated like typing")
        #expect(!harness.reportedEdits.isEmpty, "edit tracking sees the replacement")
        #expect(harness.coordinator.diagnostics.isEmpty, "a marker on the reformatted statement is stale")
        #expect(harness.textView.selectedRange() == NSRange(location: 3, length: 0))
        #expect(undo.undoActionName == "Format SQL")
        undo.undo()
        #expect(harness.textView.string == original, "one ⌘Z restores the original")
        // Out-of-date ranges are refused instead of trapping.
        #expect(!harness.textView.replace(NSRange(location: 0, length: 10_000), in: original, with: "x", actionName: "Format SQL",
                                          selecting: NSRange(location: 0, length: 0)))
    }

    // A format result lands only on the exact text it was computed from: never during a composition, never on newer text.
    @Test func formattingRefusesWhileComposingOrOnChangedText() throws {
        let original = "select a from t"
        let harness = EditorHarness(original)
        let controller = SQLEditorController()
        #expect(controller.snapshot() == nil, "no editor attached yet")
        #expect(controller.replace(NSRange(location: 0, length: 1), in: original, with: "S", actionName: "Format SQL",
                                   selecting: NSRange(location: 0, length: 0)) == .detached)
        controller.textView = harness.textView
        let formatted = try #require(SQLFormatter.format(original))
        let whole = NSRange(location: 0, length: (original as NSString).length)
        // An input method re-marks committed text: the string is unchanged, but the composition must survive.
        harness.textView.setMarkedText("t", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 14, length: 1))
        #expect(harness.textView.hasMarkedText())
        #expect(harness.textView.string == original)
        #expect(controller.replace(whole, in: original, with: formatted, actionName: "Format SQL", selecting: NSRange(location: 0, length: 0)) == .refused)
        #expect(harness.textView.hasMarkedText())
        harness.textView.unmarkText()
        harness.textView.setSelectedRange(NSRange(location: 15, length: 0))
        harness.textView.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(controller.snapshot() == nil, "nothing to format while an input method composes")
        #expect(controller.replace(whole, in: original, with: formatted, actionName: "Format SQL", selecting: NSRange(location: 0, length: 0)) == .refused)
        #expect(harness.textView.hasMarkedText(), "the composition survives")
        #expect(harness.textView.string == "select a from tni")
        harness.textView.unmarkText()
        // The result was computed from older text: refused, nothing changes.
        #expect(controller.replace(whole, in: original, with: formatted, actionName: "Format SQL", selecting: NSRange(location: 0, length: 0)) == .refused)
        #expect(harness.textView.string == "select a from tni")
        let current = try #require(controller.snapshot())
        #expect(current.text == "select a from tni")
        #expect(controller.replace(NSRange(location: 0, length: 6), in: current.text, with: "SELECT", actionName: "Format SQL",
                                   selecting: NSRange(location: 0, length: 0)) == .replaced)
        #expect(harness.textView.string == "SELECT a from tni")
    }

    // A re-render while an input method composes must not overwrite the marked text.
    @Test func compositionSurvivesARenderWithLaggingText() {
        let harness = EditorHarness("SELECT 1")
        harness.textView.setSelectedRange(NSRange(location: 8, length: 0))
        harness.textView.setMarkedText(" ni", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(harness.textView.hasMarkedText())
        // The 300 ms lint lands while composing: the model's text is behind the storage.
        harness.diagnostics = SQLLinter.diagnose("SELECT (")
        harness.render()
        #expect(harness.textView.hasMarkedText())
        #expect(harness.textView.string == "SELECT 1 ni")
        // Committing reports every edit, in order, and the binding catches up.
        harness.textView.insertText(" 你", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!harness.textView.hasMarkedText())
        #expect(harness.text == "SELECT 1 你")
        var index = SQLLineIndex("SELECT 1")
        for edit in harness.reportedEdits { index.apply(edit) }
        #expect(index.length == ("SELECT 1 你" as NSString).length)
    }

    // Storage edits that get no textDidChange are reported instead of being overwritten.
    @Test func unreportedStorageEditsCatchUp() async throws {
        let harness = EditorHarness("SELECT 1")
        harness.textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: "-- c\n")
        #expect(harness.coordinator.hasPendingEdits)
        harness.render()
        #expect(harness.textView.string == "-- c\nSELECT 1")
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.text == "-- c\nSELECT 1")
        #expect(!harness.coordinator.hasPendingEdits)
    }

    // Return after a failed statement keeps its marker; typing onto its last token does not.
    @Test func returnAfterTheStatementKeepsItsMarker() {
        let failure = SQLDiagnostic(range: 14..<18, scope: 0..<25, severity: .error, source: .server, message: "Unexpected input 'shop'")
        let harness = EditorHarness("SELECT 1 FORM shop.orders", diagnostics: [failure])
        harness.type("\n", at: 25)
        #expect(harness.coordinator.diagnostics == [failure])
        let glued = EditorHarness("SELECT 1 FORM shop.orders", diagnostics: [failure])
        glued.type("x", at: 25)
        #expect(glued.coordinator.diagnostics.isEmpty)
    }

    // Text typed right before a statement only moves it when it stays a separate token.
    @Test func typingBeforeAStatement() {
        let failure = SQLDiagnostic(range: 18..<22, scope: 9..<24, severity: .error, source: .server, message: "m")
        let newline = EditorHarness("SELECT 1;SELECT x FORM t", diagnostics: [failure])
        newline.type("\n", at: 9)
        #expect(newline.coordinator.diagnostics.map(\.range) == [19..<23])
        let glued = EditorHarness("SELECT 1;SELECT x FORM t", diagnostics: [failure])
        glued.type("x", at: 9)
        #expect(glued.coordinator.diagnostics.isEmpty)
    }

    // A local marker stays put while the user types elsewhere in its statement.
    @Test func localMarkersDoNotBlinkWhileTyping() {
        let text = "SELECT count(1 FROM t"
        let harness = EditorHarness(text, diagnostics: SQLLinter.diagnose(text))
        harness.type(" ", at: 21)
        harness.type("W", at: 22)
        #expect(harness.coordinator.diagnostics.map(\.range) == [12..<13])
    }

    // An unterminated dollar quote keeps its marker while the user types the body.
    @Test func dollarQuoteMarkerStaysWhileTypingTheBody() {
        let text = "SELECT $$abc"
        let harness = EditorHarness(text, diagnostics: SQLLinter.diagnose(text))
        #expect(harness.coordinator.diagnostics.map(\.range) == [7..<9])
        harness.type("d", at: 12)
        #expect(harness.coordinator.diagnostics.map(\.range) == [7..<9])
        #expect(harness.text == "SELECT $$abcd")
        #expect(harness.reportedEdits == [SQLTextEdit(range: 12..<12, replacementLength: 1, separatorBeforeEnd: false, separatorAtStart: false)])
    }

    // Typing above a server error moves its marker with the text.
    @Test func typingAboveAnErrorMovesIt() {
        let failure = SQLDiagnostic(range: 17..<20, scope: 10..<40, severity: .error, source: .server, message: "column \"nme\" does not exist")
        let harness = EditorHarness("SELECT 1;\nSELECT nme FROM shop.customers", diagnostics: [failure])
        harness.type("-- note\n", at: 0)
        #expect(harness.coordinator.diagnostics.map(\.range) == [25..<28])
        #expect(harness.textView.string.utf16.count == 48)
    }
}

/// A tab's text when no editor is attached, and what Format SQL reported.
@MainActor
private final class FormatHost: SQLFormatHost {
    var text: String
    var selection: NSRange
    var outcomes: [SQLFormatRunner.Outcome] = []

    init(_ text: String) {
        self.text = text
        selection = NSRange(location: 0, length: 0)
    }

    func formatDidFinish(_ outcome: SQLFormatRunner.Outcome) { outcomes.append(outcome) }
}

@Suite("Format SQL", .serialized)
@MainActor
struct SQLFormatRunnerTests {
    private func attached(_ text: String, formatter: SQLFormatRunner.Formatter? = nil) -> (EditorHarness, FormatHost, SQLFormatRunner) {
        let harness = EditorHarness(text)
        let controller = SQLEditorController()
        controller.textView = harness.textView
        let host = FormatHost(text)
        let runner = formatter.map { SQLFormatRunner(editor: controller, host: host, formatter: $0) } ?? SQLFormatRunner(editor: controller, host: host)
        return (harness, host, runner)
    }

    @Test func aFormatIsAppliedAndReported() async {
        let (harness, host, runner) = attached("select a,b from t")
        await runner.format(options: SQLFormatOptions())?.value
        #expect(harness.textView.string == "SELECT\n  a,\n  b\nFROM t")
        #expect(host.outcomes == [.formatted])
        #expect(!runner.isRunning)
        await runner.format(options: SQLFormatOptions())?.value
        #expect(host.outcomes == [.formatted, .alreadyFormatted], "nothing to change is said, not silent")
    }

    // Every way a format can be refused tells the user why.
    @Test func aRefusedFormatIsNeverSilent() async {
        // An input method is composing: nothing starts.
        let (composing, composingHost, composingRunner) = attached("select a from t")
        composing.textView.setSelectedRange(NSRange(location: 15, length: 0))
        composing.textView.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(composingRunner.format(options: SQLFormatOptions()) == nil)
        #expect(composingHost.outcomes == [.composing])
        #expect(composing.textView.hasMarkedText())

        // Edited while formatting: the running format stops and says so.
        let (edited, editedHost, editedRunner) = attached("select a from t")
        let task = editedRunner.format(options: SQLFormatOptions())
        editedRunner.cancel(reportingChange: true)
        await task?.value
        #expect(editedHost.outcomes == [.textChanged])
        #expect(edited.textView.string == "select a from t")

        // The text changed without an edit notification: the editor refuses the stale result.
        let (replaced, replacedHost, replacedRunner) = attached("select a from t")
        let stale = replacedRunner.format(options: SQLFormatOptions())
        replaced.textView.string = "select 2"
        await stale?.value
        #expect(replacedHost.outcomes == [.textChanged])
        #expect(replaced.textView.string == "select 2")

        // The formatter's own refusals.
        let failures: [(SQLFormatError, SQLFormatRunner.Outcome)] = [
            (.notEquivalent, .notEquivalent), (.tooComplex, .tooComplex), (.invalidSelection, .invalidSelection), (.cancelled, .textChanged),
            (.versionDependent, .versionDependent), (.nulCharacter, .nulCharacter),
        ]
        for (error, outcome) in failures {
            let (harness, host, runner) = attached("select a from t", formatter: { _, _, _ in .failure(error) })
            await runner.format(options: SQLFormatOptions())?.value
            #expect(host.outcomes == [outcome], "\(error)")
            #expect(harness.textView.string == "select a from t")
        }

        // Closing the tab stops a format without a message.
        let (_, closedHost, closedRunner) = attached("select a from t")
        let closing = closedRunner.format(options: SQLFormatOptions())
        closedRunner.cancel(reportingChange: false)
        await closing?.value
        #expect(closedHost.outcomes.isEmpty)
    }

    // A tab without an editor yet (opened from launch arguments) formats its own text, only if it did not change.
    @Test func withoutAnEditorTheTabTextIsFormatted() async {
        let host = FormatHost("select a,b from t")
        let runner = SQLFormatRunner(editor: SQLEditorController(), host: host)
        await runner.format(options: SQLFormatOptions())?.value
        #expect(host.text == "SELECT\n  a,\n  b\nFROM t")
        #expect(host.outcomes == [.formatted])

        let changing = FormatHost("select a,b from t")
        let changingRunner = SQLFormatRunner(editor: SQLEditorController(), host: changing)
        let task = changingRunner.format(options: SQLFormatOptions())
        changing.text = "select 1"
        await task?.value
        #expect(changing.text == "select 1")
        #expect(changing.outcomes == [.textChanged])
    }

    @Test func everyOutcomeHasAStatusExceptAnAppliedFormat() {
        let refusals: [SQLFormatRunner.Outcome] = [.composing, .textChanged, .notEquivalent, .tooComplex, .versionDependent, .nulCharacter, .invalidSelection]
        for outcome in refusals {
            #expect(outcome.status?.isError == true, "\(outcome)")
            #expect(outcome.status.map { !$0.message.isEmpty } == true)
        }
        #expect(SQLFormatRunner.Outcome.alreadyFormatted.status?.isError == false)
        #expect(SQLFormatRunner.Outcome.formatted.status == nil, "the edit shows itself")
    }
}
