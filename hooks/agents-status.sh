#!/usr/bin/env bash
# Tells the Agents app which sessions are waiting on the user, by writing an
# OSC 777 desktop-notification escape to the session's pty. The app parses
# these in SessionActivity.parseStatusMessage and shows a coloured dot on the
# session's sidebar row.
#
# Wired to Claude Code and Codex lifecycle hooks, which share an event
# vocabulary and a JSON-on-stdin payload, so one script serves both:
#   Stop / Notification(idle_prompt)   -> your-turn  (gold dot: finished, your move)
#   Notification(permission_prompt)    -> blocked    (red dot: stuck waiting on you)
#   PermissionRequest                  -> blocked    (Codex's spelling of the same)
#   UserPromptSubmit / Pre+PostToolUse -> clear      (no dot: working)
#   SessionStart                       -> clear      (and resets transition state)
#
# PreToolUse fires before the permission prompt and PostToolUse after the tool
# runs, so resetting on tool use clears the red once the user unblocks the
# agent — a permission approval is not a UserPromptSubmit, so nothing else
# would clear it.
#
# The hook is entirely OPTIONAL. Without it the app still lights up sessions
# from ordinary OSC 9/777 desktop notifications, classified by keyword. What
# the hook buys is fidelity: a session that speaks this protocol is trusted
# over classification for the rest of its life, so its red pulse survives the
# user selecting the session and only clears when the agent says so.
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
sid=$(printf '%s' "$input" | jq -r '.session_id // empty')

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

# Where the last emitted state is remembered, so only transitions go out (see
# emit_status below). Keyed on the agent's own session id, which both Claude
# Code and Codex put in the hook payload; the pty device name is the fallback
# for any agent that doesn't. That fallback is the weaker of the two — ptys get
# recycled — which is why SessionStart resets the file below.
STATE_DIR="${TMPDIR:-/tmp}/agents-status"
STATE_FILE="$STATE_DIR/${sid:-${DEV##*/}}"

# OSC 777: ESC ] 777 ; notify ; <title> ; <body> BEL. The "agents:status"
# title is the magic the app matches on, so a genuine desktop notification
# from anything else running in this shell is never read as a status update.
#
# Only state TRANSITIONS are emitted. This hook runs on every single tool
# call, and the old unconditional emit meant a long agent turn wrote hundreds
# of identical "clear" escapes down the pty. Ghostty rate-limits desktop
# notifications to about one a second and suppresses identical content anyway,
# so most of those were being dropped before they ever reached the app — the
# repeats bought nothing and were never the mechanism keeping the indicator
# correct.
#
# The emit happens BEFORE the state file is written, deliberately: if the
# write to the pty fails, nothing is recorded and the next event retries,
# rather than the script convincing itself it already sent a state the app
# never saw.
emit_status() {
    [ "$(cat "$STATE_FILE" 2>/dev/null)" = "$1" ] && return 0
    printf '\033]777;notify;agents:status;%s\a' "$1" > "$DEV" 2>/dev/null
    mkdir -p "$STATE_DIR" 2>/dev/null && printf '%s' "$1" > "$STATE_FILE" 2>/dev/null
}

case "$event" in
    # Resets the remembered state before emitting, so a fresh session always
    # gets one real escape out even if a stale file is sitting on its key —
    # which is what keeps the pty-name fallback above honest across a recycled
    # pty. Nothing is showing at session start anyway, so the emit costs
    # nothing and leaves both sides provably agreeing from the first event.
    SessionStart)
        rm -f "$STATE_FILE" 2>/dev/null
        emit_status clear
        ;;
    UserPromptSubmit|PreToolUse|PostToolUse)
        emit_status clear
        ;;
    Stop)
        emit_status your-turn
        ;;
    # Codex's equivalent of Claude Code's Notification(permission_prompt): a
    # first-class event rather than a subtype, and the only place Codex
    # reports being blocked at all.
    PermissionRequest)
        emit_status blocked
        ;;
    Notification)
        case "$ntype" in
            permission_prompt) emit_status blocked ;;
            idle_prompt)       emit_status your-turn ;;
        esac
        ;;
esac

exit 0
