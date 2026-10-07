"""A swift-testing expectation's message is a `Comment?`, so it must be a string literal.

A literal converts; a `String` expression does not. So `#expect(ok, run.text)`,
`#expect(ok, "a" + "b")` and `String(describing:)` are all rejected by the compiler — and
`DeathRaceAppTests` is compiled only by a macOS runner, so getting this wrong there costs a
whole CI round. It cost two in one evening, which is why this exists.

Decided rather than guessed: each `#expect`/`#require` call is found, bracket-matched across
however many lines it spans, split on top-level commas, and its last argument checked. Only
what is certainly a `String` is reported — a top-level `+`, a bare identifier or member chain,
or `String(...)` — so a call that returns a `Comment`, such as `BuiltBinary.missing("legendsd")`,
still passes. Quiet enough to be worth trusting.
"""
import pathlib, re, sys

# From this script's own location, never the working directory: `make lint` runs from the
# repository root, where `Tests` does not exist, and a cwd-relative root would have made this a
# no-op that reported nothing and passed. `check-imports.py` was exactly that for weeks.
root = pathlib.Path(__file__).resolve().parent.parent / "Packages/DeathRaceKit/Tests"
if not root.is_dir():
    sys.exit(f"check-expect-messages: no tests at {root}")


def skip_interpolation(text, i):
    """The index of the `)` closing a `\\(` that starts at `i`, or the last index."""
    depth, j = 0, i
    while j < len(text):
        if text[j] == "(":
            depth += 1
        elif text[j] == ")":
            depth -= 1
            if depth == 0:
                return j
        j += 1
    return len(text) - 1


def walk(text, on_char):
    """Over `text` outside string literals, so a comma or brace in a message is not structure."""
    depth, instring, escaped, i = 0, False, False, 0
    while i < len(text):
        c = text[i]
        if instring:
            if escaped:
                escaped = False
                if c == "(":
                    i = skip_interpolation(text, i)
            elif c == "\\":
                escaped = True
            elif c == '"':
                instring = False
        else:
            # Asked before the depth moves, so the parenthesis that closes the call is seen at
            # depth 0 rather than -1. An elif chain here consumed it instead, which let the
            # scan run past the end of every call.
            if on_char(c, depth, i):
                return i
            if c == '"':
                instring = True
            elif c in "([{":
                depth += 1
            elif c in ")]}":
                depth -= 1
        i += 1
    return None


def top_level_split(text):
    parts, start = [], 0
    while True:
        at = walk(text[start:], lambda c, depth, _: c == "," and depth == 0)
        if at is None:
            parts.append(text[start:])
            return [p.strip() for p in parts]
        parts.append(text[start : start + at])
        start += at + 1


def is_literal(argument):
    """One string literal and nothing else: interpolation yes, concatenation no."""
    if not (argument.startswith('"') and argument.endswith('"')):
        return False
    i, escaped = 1, False
    while i < len(argument):
        c = argument[i]
        if escaped:
            escaped = False
            if c == "(":
                i = skip_interpolation(argument, i)
        elif c == "\\":
            escaped = True
        elif c == '"':
            # The literal ends here, so it is the whole argument only if nothing follows.
            return i == len(argument) - 1
        i += 1
    return False


def arguments(text, after):
    """The call's arguments, given the index just past its opening parenthesis."""
    end = walk(text[after:], lambda c, depth, _: c == ")" and depth == 0)
    return top_level_split(text[after : after + end if end is not None else len(text)])


found = []
for file in sorted(root.rglob("*.swift")):
    source = file.read_text()
    for call in re.finditer(r"#(expect|require)\(", source):
        args = arguments(source, call.end())
        if len(args) < 2:
            continue
        last = args[-1]
        if is_literal(last):
            continue
        # A labelled argument is not the message at all (`sourceLocation:`).
        if re.match(r"^[A-Za-z_]\w*\s*:", last) and "(" not in last.split(":")[0]:
            continue
        # The one Comment-typed property in this package; it compiles on Linux every run.
        if last.endswith(".missing"):
            continue
        certainly_a_string = (
            re.fullmatch(r"[A-Za-z_][\w.]*(\?\.[\w.]+)*", last) is not None
            or last.startswith("String(")
            or walk(last, lambda c, depth, _: c == "+" and depth == 0) is not None)
        if certainly_a_string:
            line = source[: call.start()].count("\n") + 1
            found.append(f"{file.relative_to(root.parent)}:{line}: {last[:80]}")

for one in found:
    print(f"expectation message is not a string literal: {one}")
print(f"{len(found)} expectation message(s) that cannot convert to Comment")
sys.exit(1 if found else 0)
