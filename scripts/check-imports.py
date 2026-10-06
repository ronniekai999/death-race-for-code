"""Every top-level type a macOS-only file names unqualified must come from a module it imports.

`swiftc -parse` is syntax only, so a type that is simply not in scope parses here and fails
on a macOS runner, which is how Phase 7 lost a round. This maps every top-level public type
in the package to its module and checks each macOS-only file's unqualified uses against its
own imports. Nested types are left out (they are always reached through their parent), as are
comments and string literals.
"""
import pathlib, re, sys, collections

root = pathlib.Path("Sources")

def strip(text):
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    text = re.sub(r"//[^\n]*", " ", text)
    text = re.sub(r'"""(?:.|\n)*?"""', ' "" ', text)
    return re.sub(r'"(?:\\.|[^"\\\n])*"', ' "" ', text)

# Top-level only: the keyword starts at column 0 after an access modifier.
TOP = re.compile(
    r"^(?:public|package)\s+(?:final\s+|indirect\s+)?"
    r"(?:class|struct|enum|protocol|actor|typealias)\s+([A-Z]\w*)", re.M)
ANY = re.compile(
    r"^\s*(?:(?:public|package|internal|private|fileprivate)\s+)?(?:final\s+|indirect\s+)?"
    r"(?:class|struct|enum|protocol|actor|typealias|extension)\s+([A-Z]\w*)", re.M)

owner = collections.defaultdict(set)
for f in root.rglob("*.swift"):
    module = f.relative_to(root).parts[0]
    for name in TOP.findall(strip(f.read_text())):
        owner[name].add(module)

MACOS = ["DeathRaceApp", "TerminalUI", "RenderKit", "LegendsUI", "DeathRace"]
# Names an Apple framework also declares, where the import that resolves them is the SDK's.
# This script cannot read the SDK, so a collision with one of our own type names is listed
# here rather than reported every run.
SDK = {"Group"}
bad = []
for target in MACOS:
    for f in sorted((root / target).rglob("*.swift")):
        text = strip(f.read_text())
        imports = set(re.findall(r"^\s*import\s+(\w+)", text, re.M)) | {target}
        local = set(ANY.findall(text))
        # Unqualified uses only: not preceded by a dot.
        for name in sorted(set(re.findall(r"(?<![.\w])([A-Z]\w*)", text))):
            if name in local or name in SDK or name not in owner or owner[name] & imports:
                continue
            bad.append(f"{f}: names {name}, declared in {'/'.join(sorted(owner[name]))}, not imported")

for line in bad:
    print(line)
print(f"\n{len(bad)} unreachable type name(s)")
sys.exit(1 if bad else 0)
