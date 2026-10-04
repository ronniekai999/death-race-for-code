import Testing
import Vault

@testable import AppCore

@Suite("Wishing Well")
struct WishingWellTests {
    @Test func theButtonsSayHowManyPanes() {
        #expect(WishingWell.insertTitle(panes: 1) == "Insert")
        #expect(WishingWell.runTitle(panes: 1) == "Run")
        #expect(WishingWell.insertTitle(panes: 3) == "Insert in 3 panes")
        #expect(WishingWell.runTitle(panes: 3) == "Run in 3 panes")
    }

    @Test func aListShowsTheFirstLine() {
        #expect(WishingWell.preview("sudo systemctl restart caddy") == "sudo systemctl restart caddy")
        #expect(WishingWell.preview("cd /srv/api\ngit pull\nmake") == "cd /srv/api …")
        #expect(WishingWell.preview("ls\n\n") == "ls")
        #expect(WishingWell.preview(String(repeating: "a", count: 90), limit: 10) == "aaaaaaaaaa …")
    }

    @Test func aSavedSelectionKeepsItsBracesAndLosesItsEdges() {
        #expect(WishingWell.snippetText(fromSelection: "\n  make test   \n\n") == "  make test")
        #expect(WishingWell.snippetText(fromSelection: "cd /srv \nmake\n") == "cd /srv\nmake")
        let docker = WishingWell.snippetText(fromSelection: "docker inspect -f '{{.State.Status}}' api")
        #expect(docker == "docker inspect -f '\\{{.State.Status}}' api")
        // As saved, it types exactly what was selected, with no field to fill.
        let fill = SnippetFill(docker)
        #expect(fill.fields.isEmpty)
        #expect(fill.command == "docker inspect -f '{{.State.Status}}' api")
        // A backslash before the braces in the selection survives too.
        #expect(SnippetFill(WishingWell.snippetText(fromSelection: "echo \\{{x}}")).command == "echo \\{{x}}")
    }

    @Test func aSavedSelectionIsNamedForItsFirstLine() {
        #expect(WishingWell.suggestedName(for: "sudo systemctl restart caddy\n") == "sudo systemctl restart caddy")
        #expect(WishingWell.suggestedName(for: "\n\n  journalctl   -fu api\nmore") == "journalctl -fu api")
        #expect(
            WishingWell.suggestedName(for: "kubectl --context production get pods --namespace api", limit: 30)
                == "kubectl --context production")
        #expect(WishingWell.suggestedName(for: String(repeating: "x", count: 50), limit: 10) == "xxxxxxxxxx")
        #expect(WishingWell.suggestedName(for: "  \n ") == "Snippet")
    }

    @Test func fieldsStartAtTheirDefaultsAndRunWaitsForAll() {
        var fill = SnippetFill("./deploy.sh {{env:prod|staging}} --version {{version=2.4.1}} --note {{note}}")
        #expect(fill.fields.map(\.name) == ["env", "version", "note"])
        #expect(fill.command == "./deploy.sh prod --version 2.4.1 --note ")
        #expect(!fill.isComplete)
        fill.values["note"] = "hotfix"
        fill.values["env"] = "staging"
        #expect(fill.isComplete)
        #expect(fill.command == "./deploy.sh staging --version 2.4.1 --note hotfix")
        fill.values["version"] = "  "
        #expect(!fill.isComplete)
    }

    @Test func hearMeCallingFindsSnippetsByTheirCommands() {
        let deploy = Snippet(id: SnippetID(rawValue: "s1"), name: "deploy", text: "./deploy.sh {{env:prod|staging}}")
        let logs = Snippet(id: SnippetID(rawValue: "s2"), name: "tail api logs", text: "journalctl -fu api")
        let items = PaletteSearch.snippets(vault: Vault(snippets: [deploy, logs]))
        #expect(items.map(\.id) == ["snippet.s1", "snippet.s2"])
        #expect(items.map(\.kind) == [.snippet, .snippet])
        #expect(items.first?.detail == "./deploy.sh {{env:prod|staging}}")
        #expect(items.first?.alternate == "Run")
        #expect(PaletteSearch.search("journalctl", in: items).map(\.item.id) == ["snippet.s2"])
    }
}
