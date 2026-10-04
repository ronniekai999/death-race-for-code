import Testing

@testable import Vault

@Suite("Snippet templates")
struct SnippetTemplateTests {
    typealias Placeholder = SnippetTemplate.Placeholder

    @Test func theThreeKindsOfPlaceholder() {
        let template = SnippetTemplate("./deploy.sh {{env:prod|staging}} --version {{version=2.4.1}} --by {{who}}")
        #expect(
            template.placeholders == [
                Placeholder(name: "env", choices: ["prod", "staging"]),
                Placeholder(name: "version", defaultValue: "2.4.1"),
                Placeholder(name: "who"),
            ])
        #expect(template.render() == "./deploy.sh prod --version 2.4.1 --by ")
        #expect(
            template.render(["env": "staging", "version": "2.5.0", "who": "ronnie"])
                == "./deploy.sh staging --version 2.5.0 --by ronnie")
    }

    @Test func plainTextHasNoPlaceholders() {
        let template = SnippetTemplate("sudo systemctl restart caddy")
        #expect(template.placeholders.isEmpty)
        #expect(template.parts == [.text("sudo systemctl restart caddy")])
        #expect(template.render() == "sudo systemctl restart caddy")
    }

    @Test func aNameUsedTwiceIsOneField() {
        let template = SnippetTemplate("cp {{file=a.txt}} {{file}}.bak")
        #expect(template.placeholders == [Placeholder(name: "file", defaultValue: "a.txt")])
        #expect(template.render() == "cp a.txt a.txt.bak")
        #expect(template.render(["file": "b"]) == "cp b b.bak")
    }

    @Test func spacesAroundNamesAndValuesDontCount() {
        let template = SnippetTemplate("{{ env : prod | staging }} {{ version = 1.0 }}")
        #expect(
            template.placeholders == [
                Placeholder(name: "env", choices: ["prod", "staging"]),
                Placeholder(name: "version", defaultValue: "1.0"),
            ])
    }

    @Test func whicheverOfEqualsOrColonComesFirstDecides() {
        #expect(SnippetTemplate("{{a=b:c}}").placeholders == [Placeholder(name: "a", defaultValue: "b:c")])
        #expect(SnippetTemplate("{{a:b=c|d}}").placeholders == [Placeholder(name: "a", choices: ["b=c", "d"])])
        #expect(SnippetTemplate("{{a:}}").placeholders == [Placeholder(name: "a")])
    }

    @Test func escapedBracesAndBrokenPlaceholdersStayText() {
        #expect(SnippetTemplate(#"echo \{{literal}}"#).render() == "echo {{literal}}")
        #expect(SnippetTemplate(#"echo \{{literal}}"#).placeholders.isEmpty)
        #expect(SnippetTemplate("awk '{{print}}'").render(["print": "X"]) == "awk 'X'")
        for text in ["{{}}", "{{ }}", "{{unclosed", "{{=value}}", "x }} y", "{{a{b}}"] {
            #expect(SnippetTemplate(text).placeholders.isEmpty, "\(text)")
            #expect(SnippetTemplate(text).render() == text, "\(text)")
        }
    }

    @Test func aNameIsAtMost64Characters() {
        let long = String(repeating: "n", count: 65)
        #expect(SnippetTemplate("{{\(long)}}").placeholders.isEmpty)
        #expect(SnippetTemplate("{{\(long.dropLast())}}").placeholders.count == 1)
    }

    @Test func placeholdersNextToEachOther() {
        let template = SnippetTemplate("{{user}}@{{host=db}}")
        #expect(template.render(["user": "r"]) == "r@db")
        #expect(template.parts.count == 3)
    }
}
