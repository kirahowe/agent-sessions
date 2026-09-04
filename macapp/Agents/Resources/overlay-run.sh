#!/bin/sh
# Runs a review command as the process of an Agents overlay surface and
# tells the app when it has ended, through the terminal itself.
#
# Ghostty holds a surface open once a command it was spawned with exits —
# wait-after-command is forced on for any surface configured with a
# command — so the surface closing is not a signal the app can wait for:
# nothing closes until a key is pressed. What the app can observe is the
# terminal stream, and the one thing in it that is delivered verbatim and
# cannot be produced by accident is a title. The app hands this wrapper a
# token that is fresh for this one review; once the review has ended the
# wrapper sets the terminal title to it (OSC 2), libghostty reports that
# title to the app, and the app tears the overlay down on the match. A
# child of the review setting its own title, or emitting shell-integration
# marks, cannot end the review early: it does not know the token. The exit
# status is passed through so the wrapper is transparent to whatever
# spawned it. See OverlayCenter.swift.
#
# The token must also be written when the review is killed rather than
# exiting: a Ctrl-C before the TUI has put the tty in raw mode, or a TERM
# to the process group, reaches this shell as well as the review. Without
# the traps the shell dies by the signal with the title unset, and the
# surface then sits at Ghostty's "Process exited" line — with the launcher
# still blocked — until a further keypress. A trapped signal is delivered
# once the foreground command has ended, so the handler writes the token
# for the signal that ended it. The traps stay installed to the very end:
# a signal landing between the review's exit and the title write must not
# reopen that hole. (Uncatchable signals still need the keypress; the app
# keeps the surface-close fallback for that.)
#
# usage: overlay-run.sh <token> <command> [args...]
token=$1
shift
finished() { printf '\033]2;%s\a' "$token"; }
trap 'finished; exit 130' INT
trap 'finished; exit 143' TERM
trap 'finished; exit 129' HUP
"$@"
rc=$?
finished
exit "$rc"
