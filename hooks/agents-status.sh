#!/usr/bin/env bash
# Tells the Agents app which sessions are waiting on the user, by writing an
# OSC 777 desktop-notification escape to the session's pty. The app parses
# these in SessionActivity.parseStatusMessage and shows a coloured dot on the
# session's sidebar row.
#
# Wired to Claude Code hooks:
#   Stop / Notification(idle_prompt)   -> your-turn  (gold dot: finished, your move)
#   Notification(permission_prompt)    -> blocked    (red dot: stuck waiting on you)
#   UserPromptSubmit / Pre+PostToolUse -> clear      (no dot: working)
#
# PreToolUse fires before the permission prompt and PostToolUse after the tool
# runs, so resetting on tool use clears the red once the user unblocks the
# agent — a permission approval is not a UserPromptSubmit, so nothing else
# would clear it.
#
# Claude Code runs hooks WITHOUT a controlling terminal, so /dev/tty is
# unusable. We discover the pty by walking up the process tree to the first
# ancestor with a real tty, then write the escape there.
#
# Bash + jq rather than babashka (which the rest of this repo uses): hooks run
# on every tool call, so process startup cost is paid constantly, and this
# needs no jj/JSON-envelope machinery that would justify it.
#
# Gated on $AGENTS_APP: this hook is registered globally in the user's Claude
# Code settings, so it also runs for sessions hosted in iTerm2 and every other
# terminal, not just this app — see the guard below for why that matters.

input=$(cat)

# Stdin is drained FIRST, above, and only then do we decide whether to bail:
# Claude Code writes the hook payload into this process's stdin, so exiting
# before reading it leaves the parent writing into a pipe with no reader. The
# wasted `cat` on the (common) non-app path is far cheaper than risking an
# EPIPE on every tool call in every terminal that isn't this app.
#
# This hook runs for every session regardless of which terminal is hosting it
# — iTerm2, Terminal.app, a plain tmux pane, anything. $AGENTS_APP is stamped
# into the environment of every surface this app spawns (see
# TerminalCenter.sessionEnvVars), so its presence is how this script tells
# "I'm running inside the Agents app" apart from "I'm running somewhere else
# that merely also runs Claude Code." Without this guard, the OSC 777 escape
# below would reach terminals that treat a desktop-notification escape as a
# REAL system notification, popping one on every single tool call — a
# notification storm, not a quiet sidebar dot.
if [ -z "${AGENTS_APP:-}" ]; then
    exit 0
fi

event=$(printf '%s' "$input" | jq -r '.hook_event_name // empty')
ntype=$(printf '%s' "$input" | jq -r '.notification_type // empty')

# Resolve the controlling terminal device of the hosting session.
find_tty() {
    local pid=$$ t
    for _ in 1 2 3 4 5 6 7 8; do
        { [ -z "$pid" ] || [ "$pid" = "0" ]; } && break
        t=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
        if [ -n "$t" ] && [ "$t" != "??" ]; then
            echo "/dev/$t"
            return 0
        fi
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    done
    return 1
}

DEV=$(find_tty) || exit 0
[ -w "$DEV" ] || exit 0

# OSC 777: ESC ] 777 ; notify ; <title> ; <body> BEL. The "agents:status"
# title is the magic the app matches on, so a genuine desktop notification
# from anything else running in this shell is never read as a status update.
emit_status() {
    printf '\033]777;notify;agents:status;%s\a' "$1" > "$DEV" 2>/dev/null
}

case "$event" in
    UserPromptSubmit|PreToolUse|PostToolUse)
        emit_status clear
        ;;
    Stop)
        emit_status your-turn
        ;;
    Notification)
        case "$ntype" in
            permission_prompt) emit_status blocked ;;
            idle_prompt)       emit_status your-turn ;;
        esac
        ;;
esac

exit 0
