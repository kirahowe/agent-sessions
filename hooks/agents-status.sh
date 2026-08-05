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

input=$(cat)
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
