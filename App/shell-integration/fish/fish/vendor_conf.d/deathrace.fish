# Death Race for Code — fish.
#
# Loaded through XDG_DATA_DIRS, which fish reads vendor_conf.d from, so nothing of yours is
# written to. fish is the easiest of the three: it gives the exit status and the duration as
# variables, so there is no arithmetic here at all.
#
#   OSC 133;A  prompt start      OSC 133;B  prompt end
#   OSC 633;E  the command line  OSC 133;C  output start
#   OSC 133;D;<exit>;dur=<ms>

status is-interactive; or exit 0
set -q __deathrace_installed; and exit 0
set -g __deathrace_installed 1
set -g __deathrace_ran

# `;` would end the parameter and `\` is the escape itself; a line break and a tab are spelled
# out so a command written across two lines stays one line of text.
function __deathrace_escape
    string replace -a '\\' '\\\\' -- $argv[1] |
        string replace -a ';' '\x3b' |
        string replace -a \n '\x0a' |
        string replace -a \r '\x0d' |
        string replace -a \t '\x09'
end

function __deathrace_preexec --on-event fish_preexec
    set -g __deathrace_ran 1
    printf '\e]633;E;%s\a' (__deathrace_escape "$argv[1]" | string collect)
    printf '\e]133;C\a'
end

function __deathrace_postexec --on-event fish_postexec
    set -l ended $status
    # CMD_DURATION is already milliseconds, which is why fish needs no clock arithmetic.
    if set -q CMD_DURATION
        printf '\e]133;D;%d;dur=%d\a' $ended $CMD_DURATION
    else
        printf '\e]133;D;%d\a' $ended
    end
    set -g __deathrace_ran
end

# A and B bracket the prompt, so the prompt is wrapped rather than replaced: your own
# fish_prompt is copied aside and called in the middle, and keeps working exactly as it did.
#
# The wrap happens on the first prompt event, not here, and that is the whole point: this file
# is in vendor_conf.d, which fish reads *before* your config.fish. Wrapping at load time would
# copy fish's default prompt and then be thrown away the moment your config.fish defined a
# fish_prompt of its own — which is what most fish configurations do. By the time the first
# prompt event fires, your definition is the one in place.
function __deathrace_wrap_prompt --on-event fish_prompt
    functions -q __deathrace_inner_prompt; and return
    functions --copy fish_prompt __deathrace_inner_prompt
    function fish_prompt
        printf '\e]133;A\a'
        __deathrace_inner_prompt
        printf '\e]133;B\a'
    end
end
