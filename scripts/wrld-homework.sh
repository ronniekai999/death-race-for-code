#!/bin/bash
# What macOS's Secure Enclave SSH tools print on this Mac, for Death Race's tests.
#
# Death Race creates Secure Enclave keys with `sc_auth` and hands them to ssh with
# `ssh-keygen -K`. Neither can run on CI, so this records how they behave here: the
# outputs become test fixtures, and the parsing is written against them.
#
# It is careful with your keys:
# - it makes two throwaway identities labelled "Death Race homework …", with no Touch ID;
# - it downloads key handles into an empty temporary folder, never into ~/.ssh;
# - it deletes only the identities it made, and asks before making them.
# Nothing it records is secret: command output, hashes, and the public keys of every Secure
# Enclave SSH identity on this Mac (ssh-keygen -K downloads them all), yours included.
#
# Usage: scripts/wrld-homework.sh   (writes wrld-homework.txt in the current folder)

set -u
report="$PWD/wrld-homework.txt"
label="Death Race homework $(date +%Y%m%d-%H%M%S)"
work="$(mktemp -d "${TMPDIR:-/tmp}/wrld-homework.XXXXXX")"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "This is for macOS." >&2
    exit 1
fi

echo "This makes two throwaway Secure Enclave identities labelled \"$label\","
echo "downloads their handles into $work, records what the tools print, and deletes them."
printf "Go ahead? [y/N] "
read -r answer
case "$answer" in y | Y | yes) ;; *) echo "Nothing done."; exit 0 ;; esac

: >"$report"
run() {
    {
        echo "\$ $*"
        "$@" 2>&1
        echo "[exit $?]"
        echo
    } >>"$report"
}

{
    echo "# wrld-homework, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
} >>"$report"
run sw_vers
run uname -m
run /usr/bin/ssh -V
run cat /etc/ssh/ssh_config
run ls /etc/ssh/ssh_config.d
run /usr/sbin/sc_auth help
run /usr/sbin/sc_auth list-ctk-identities
run /usr/sbin/sc_auth list-ctk-identities -t ssh

run /usr/sbin/sc_auth create-ctk-identity -l "$label A" -k p-256-ne -t none
run /usr/sbin/sc_auth create-ctk-identity -l "$label B" -k p-256-ne -t none
run /usr/sbin/sc_auth list-ctk-identities
run /usr/sbin/sc_auth list-ctk-identities -t ssh

# The handles, with no terminal: ssh-keygen reads its PIN prompt from standard input.
(
    cd "$work" || exit 1
    {
        echo "\$ (in an empty folder) printf '\\n\\n\\n' | SSH_ASKPASS_REQUIRE=never ssh-keygen -w /usr/lib/ssh-keychain.dylib -K -N \"\""
        printf '\n\n\n' | SSH_ASKPASS_REQUIRE=never /usr/bin/ssh-keygen -w /usr/lib/ssh-keychain.dylib -K -N "" 2>&1
        echo "[exit $?]"
        echo
        echo "\$ ls -la"
        ls -la
        echo
        for pub in ./*.pub; do
            [ -e "$pub" ] || continue
            echo "\$ cat $pub"
            cat "$pub"
            echo "\$ ssh-keygen -l -f $pub"
            /usr/bin/ssh-keygen -l -f "$pub" 2>&1
            echo
        done
    } >>"$report"
)

# Delete what this made: the lines naming our label, and the 40-hex hash on each.
deleted=0
while IFS= read -r line; do
    hash="$(printf '%s\n' "$line" | grep -oE '[0-9A-Fa-f]{40}' | head -1)"
    if [ -n "$hash" ]; then
        run /usr/sbin/sc_auth delete-ctk-identity -h "$hash"
        deleted=$((deleted + 1))
    fi
done < <(/usr/sbin/sc_auth list-ctk-identities 2>/dev/null | grep -F "$label")
run /usr/sbin/sc_auth list-ctk-identities
rm -rf "$work"

if [ "$deleted" -lt 2 ]; then
    echo
    echo "Couldn't find both homework identities to delete. The report shows how they're listed;"
    echo "delete any left with: sc_auth delete-ctk-identity -h <hash>"
fi
echo
echo "Wrote $report. Attach it to the pull request (nothing in it is secret)."
