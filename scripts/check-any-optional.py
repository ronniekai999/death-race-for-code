"""`any P?` is a compile error, and `swiftc -parse` accepts it.

The optional of an existential has to be written `(any P)?`. Writing `any P?` is rejected by
the compiler in Swift 5, Swift 6 and the default language mode alike, and it is rejected for a
*type*-level reason — so `swiftc -parse`, which is syntax only, passes it straight through.
That makes it invisible to every check this repo runs on Linux, and the macOS-only targets are
where it then lands: the Build step is the first thing that sees it, which is a whole CI round
for two missing brackets. It cost one, which is why this exists.

Decidable rather than heuristic, which is the bar `check-expect-messages.py` set and the bar a
switch-exhaustiveness script could not clear: the construct is *always* an error, so there is
no legitimate occurrence to tell it apart from. The only thing to be careful of is a mention of
it in a comment or a string — including in this file's own docstring — so comments and string
literals are stripped before the search.
"""
import pathlib, re, sys

# From this script's own location, never the working directory: `make lint` runs from the
# repository root. `check-imports.py` was a cwd-relative no-op for weeks.
root = pathlib.Path(__file__).resolve().parent.parent / "Packages/DeathRaceKit"
if not root.is_dir():
    sys.exit(f"check-any-optional: no package at {root}")

# `any` then a type name then `?`, with no `(` opening the existential. A generic argument list
# or a member chain may sit between: `any Sequence<Int>?`, `any Foo.Bar?`.
offender = re.compile(r"\bany\s+[A-Z][\w.]*(?:<[^<>\n]*>)?\s*\?")


def without_comments_or_strings(source):
    """`source` with comments and string literals blanked, keeping every line's numbering."""
    out, i, n = [], 0, len(source)
    while i < n:
        two = source[i : i + 2]
        if two == "//":
            end = source.find("\n", i)
            end = n if end < 0 else end
            out.append(" " * (end - i))
            i = end
        elif two == "/*":
            depth, j = 1, i + 2
            while j < n and depth:
                if source[j : j + 2] == "/*":
                    depth, j = depth + 1, j + 2
                elif source[j : j + 2] == "*/":
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            out.append("".join(c if c == "\n" else " " for c in source[i:j]))
            i = j
        elif source.startswith('"""', i):
            end = source.find('"""', i + 3)
            end = n if end < 0 else end + 3
            out.append("".join(c if c == "\n" else " " for c in source[i:end]))
            i = end
        elif source[i] == '"':
            j, escaped = i + 1, False
            while j < n and (escaped or source[j] != '"'):
                escaped = not escaped and source[j] == "\\"
                j += 1
            out.append(" " * (min(j + 1, n) - i))
            i = min(j + 1, n)
        else:
            out.append(source[i])
            i += 1
    return "".join(out)


found = []
for file in sorted(root.rglob("*.swift")):
    source = file.read_text()
    for match in offender.finditer(without_comments_or_strings(source)):
        line = source[: match.start()].count("\n") + 1
        text = source.splitlines()[line - 1].strip()
        found.append(f"{file.relative_to(root.parent.parent)}:{line}: {text[:100]}")

for one in found:
    print(f"an optional existential must be written (any P)?: {one}")
print(f"{len(found)} `any P?` that the compiler will reject")
sys.exit(1 if found else 0)
