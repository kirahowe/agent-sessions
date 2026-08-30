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
# A second, independent protocol rides the same OSC 777 channel under the
# title "agents:session": it announces the session's identity so that after
# the app (or the terminal) restarts, it can offer a "resume last session"
# hint with the exact command to type. The body is a compact JSON object:
#   {"event":<hook_event_name>,"v":1,"agent":"claude"|"codex","session_id":<sid>,"query":<prompt preview>}
# "agent" comes from walking the same process tree used to find the pty (see
# find_tty_and_agent) — the nearest ancestor named "claude*" or "codex*" wins,
# with $CLAUDECODE as a fallback when no ancestor matches, and no announcement
# at all when neither identifies a harness. "query" is only present when the
# payload carries a string prompt (.prompt, or .query as a fallback field
# name), truncated to its first 200 codepoints: most terminals silently drop
# any OSC sequence over roughly 2048 bytes, and a raw prompt could easily blow
# past that on its own, so the cap keeps the whole envelope comfortably inside
# the limit no matter what the user typed.
#
# SessionStart and UserPromptSubmit always announce — SessionStart because
# it's the natural place to (re)establish identity, UserPromptSubmit because
# it's the only event carrying a prompt preview. Every other event announces
# only the FIRST time it fires for a given session id, tracked with a marker
# file next to the status state file: some real-world hook configs register
# only a subset of events (PreToolUse/PostToolUse alone, say), so whichever
# event happens to fire first for a session still has to be able to announce
# it rather than assuming SessionStart or UserPromptSubmit already ran.
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

# Resolve the controlling terminal device of the hosting session, and along
# the same walk, the harness (Claude Code or Codex) whose child we're running
# as — needed for the session-announcement protocol above. Both facts come
# from the same per-ancestor `ps` call, so one walk does double duty instead
# of climbing the tree twice.
#
# Agent detection reads `ps -o comm=`, which on macOS prints the executable's
# path (e.g. "/opt/homebrew/bin/claude"; a login shell prints "-/bin/zsh").
# The basename is matched against "claude*"/"codex*", and the NEAREST
# matching ancestor wins: the real chain runs
#   bash(hook) -> /opt/homebrew/bin/claude -> -/bin/zsh -> /usr/bin/login -> Agents
# so the harness itself is found long before the walk would otherwise reach
# something unrelated further up.
find_tty_and_agent() {
    local pid=$$ t c base
    for _ in 1 2 3 4 5 6 7 8; do
        { [ -z "$pid" ] || [ "$pid" = "0" ] || [ "$pid" = "1" ]; } && break
        if [ -z "$DEV" ]; then
            t=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
            [ -n "$t" ] && [ "$t" != "??" ] && DEV="/dev/$t"
        fi
        if [ -z "$AGENT" ]; then
            c=$(ps -o comm= -p "$pid" 2>/dev/null)
            base=${c##*/}
            case "$base" in
                claude*) AGENT="claude" ;;
                codex*)  AGENT="codex" ;;
            esac
        fi
        [ -n "$DEV" ] && [ -n "$AGENT" ] && break
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    done
}

DEV=""
AGENT=""
find_tty_and_agent
[ -n "$DEV" ] || exit 0
[ -w "$DEV" ] || exit 0

# Fallback when no ancestor matched a known harness: Claude Code stamps
# CLAUDECODE=1 into every child's environment, so its presence is still good
# evidence even when the walk above came up empty (Codex has no equivalent
# marker, so there is nothing symmetric to check for it). If neither the walk
# nor this variable identifies a harness, the session announcement below is
# skipped outright rather than guessed at.
if [ -z "$AGENT" ] && [ -n "${CLAUDECODE:-}" ]; then
    AGENT="claude"
fi

# Where the last emitted state is remembered, so only transitions go out (see
# emit_status below). Keyed on the agent's own session id, which both Claude
# Code and Codex put in the hook payload; the pty device name is the fallback
# for any agent that doesn't. That fallback is the weaker of the two — ptys get
# recycled — which is why SessionStart resets the file below.
STATE_DIR="${TMPDIR:-/tmp}/agents-status"
STATE_FILE="$STATE_DIR/${sid:-${DEV##*/}}"

# Marker for the session-announcement protocol's first-sighting rule (see
# header). Unlike STATE_FILE this has no pty-name fallback — announcement is
# skipped entirely when sid is empty, so the key only ever needs to be a
# session id.
SESSION_MARKER="$STATE_DIR/${sid}.session"

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
    printf '\033]777;notify;agents:status;%s\a' "$1" > "$DEV" 2>/dev/null || return 0
    mkdir -p "$STATE_DIR" 2>/dev/null && printf '%s' "$1" > "$STATE_FILE" 2>/dev/null
}

# OSC 777 title "agents:session": see the header for the wire format. Same
# escape mechanism as emit_status above, different title, so a client can
# subscribe to either without needing to parse the other's payload.
#
# `jq -ac`: `-c` keeps the body one line, so a newline embedded in a user
# prompt can never be mistaken for the BEL that terminates the OSC sequence;
# `-a` guarantees no raw multibyte or control byte reaches the pty inside the
# escape, since jq \u-escapes them instead. The query, when present, is
# sliced to its first 200 codepoints for the size reason given in the header.
#
# Like emit_status, the marker file is written only AFTER the escape write
# succeeds — a failed write must not be recorded as sent, or a later event
# would wrongly believe this session was already announced.
emit_session() {
    local body
    body=$(printf '%s' "$input" | jq -ac \
        --arg event "$event" \
        --arg agent "$AGENT" \
        --arg sid "$sid" \
        '
        (if (.prompt | type) == "string" then .prompt
         elif (.query | type) == "string" then .query
         else null end) as $q
        | {event: $event, v: 1, agent: $agent, session_id: $sid}
        + (if $q != null then {query: $q[0:200]} else {} end)
        ' 2>/dev/null) || return 0
    [ -n "$body" ] || return 0
    printf '\033]777;notify;agents:session;%s\a' "$body" > "$DEV" 2>/dev/null || return 0
    mkdir -p "$STATE_DIR" 2>/dev/null && printf 'sent' > "$SESSION_MARKER" 2>/dev/null
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

# Session announcement runs independently of the status case above — for
# every event, not just the ones status cares about — because whichever event
# fires FIRST for a session is the one responsible for announcing it (see
# header for why that has to be event-agnostic). Skipped outright when there
# is no session id to key on, or no harness was identified.
if [ -n "$sid" ] && [ -n "$AGENT" ]; then
    case "$event" in
        SessionStart)
            rm -f "$SESSION_MARKER" 2>/dev/null
            emit_session
            ;;
        UserPromptSubmit)
            emit_session
            ;;
        *)
            [ -f "$SESSION_MARKER" ] || emit_session
            ;;
    esac
fi

exit 0
