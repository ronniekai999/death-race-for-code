import Testing
import VTCore

@testable import SurfaceCore

@Suite("What's typed, as each pane's program wants it")
struct TypedInputTests {
    func modes(applicationCursorKeys: Bool = false, bracketedPaste: Bool = false) -> TerminalModes {
        var modes = TerminalModes()
        modes.applicationCursorKeys = applicationCursorKeys
        modes.bracketedPaste = bracketedPaste
        return modes
    }

    @Test func anArrowFollowsEachProgramsCursorMode() {
        let up = TypedInput.key(KeyEvent(.up))
        #expect(up.bytes(modes: modes(), kittyFlags: 0).bytes == Array("\u{1B}[A".utf8))
        #expect(up.bytes(modes: modes(applicationCursorKeys: true), kittyFlags: 0).bytes == Array("\u{1B}OA".utf8))
    }

    @Test func aKeyFollowsEachProgramsKeyboardProtocol() {
        let ctrlC = TypedInput.key(KeyEvent(.character("c"), modifiers: .control, text: "c"))
        #expect(ctrlC.bytes(modes: modes(), kittyFlags: 0).bytes == [0x03])
        // A program that asked the Kitty protocol to disambiguate gets its own form.
        #expect(ctrlC.bytes(modes: modes(), kittyFlags: 1).bytes == Array("\u{1B}[99;5u".utf8))
    }

    @Test func releasesAndModifiersAreReports() {
        let release = TypedInput.key(KeyEvent(.character("a"), action: .release, text: "a"))
        #expect(release.bytes(modes: modes(), kittyFlags: 0).bytes.isEmpty)
        #expect(release.bytes(modes: modes(), kittyFlags: 0b1011).isReport)
        #expect(
            TypedInput.key(KeyEvent(.character("a"), text: "a")).bytes(modes: modes(), kittyFlags: 0).isReport == false)
    }

    @Test func aPasteIsBracketedOnlyWhereAsked() {
        let paste = TypedInput.paste("ls\nrm -rf ~")
        #expect(paste.bytes(modes: modes(), kittyFlags: 0).bytes == Array("ls\rrm -rf ~".utf8))
        #expect(
            paste.bytes(modes: modes(bracketedPaste: true), kittyFlags: 0).bytes
                == Array("\u{1B}[200~ls\nrm -rf ~\u{1B}[201~".utf8))
        #expect(TypedInput.text("é").bytes(modes: modes(), kittyFlags: 1).bytes == Array("é".utf8))
    }

    @Test func aSnippetIsInsertedWholeAndRunWithReturn() {
        #expect(TypedInput.snippet("tmux new -A -s main", run: false) == [.paste("tmux new -A -s main")])
        let run = TypedInput.snippet("make test", run: true)
        let bytes = run.flatMap { $0.bytes(modes: modes(bracketedPaste: true), kittyFlags: 0).bytes }
        #expect(bytes == Array("\u{1B}[200~make test\u{1B}[201~\r".utf8))
    }
}
