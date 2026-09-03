#!/usr/bin/env bash
# Tells the Agents app what the agent hosting this hook is doing, over the
# app's control socket: one line of JSON per hook event, carrying the two
# facts the sidebar and the restore banner are built from.
#
#   status  — is the agent waiting on the user? Drives the coloured dot on
#             the session's row (SessionAttention in the app):
#               Stop / Notification(idle_prompt)   -> your-turn  (gold: finished, your move)
#               Notification(permission_prompt)    -> blocked    (red: stuck waiting on you)
#               PermissionRequest                  -> blocked    (Codex's spelling of the same)
#               SessionStart / UserPromptSubmit /
#               PreToolUse / PostToolUse           -> clear      (no dot: working)
#             PreToolUse fires before the permission prompt and PostToolUse
#             after the tool runs, so a tool-use event is what clears the
#             red once the user unblocks the agent — approving a permission
#             prompt is not a UserPromptSubmit, so nothing else would.
#
#   session — which harness this is ("claude" or "codex"), under which of
#             its own session ids, plus a preview of the prompt when the
#             event carries one (UserPromptSubmit), plus the harness's
#             configuration home when its environment set one (CLAUDE_CONFIG_DIR,
#             CODEX_HOME). After the app restarts, this is what lets a
#             restored row greet the user with
#                 Last Claude Code session: <title>
#                 ❯ claude --resume <id>
#             — the command typed and waiting for Enter — instead of a bare
#             shell. The home matters because the harness keeps its sessions
#             under it: without CODEX_HOME=… in front, `codex resume <id>`
#             in a fresh shell would look in ~/.codex and find nothing.
#
# Wired to Claude Code and Codex lifecycle hooks, which share an event
# vocabulary and a JSON-on-stdin payload, so one script serves both. The
# harness is identified by walking up the process tree to the nearest
# ancestor named "claude*" or "codex*", with $CLAUDECODE as a fallback; when
# neither identifies one, the line carries status only.
#
# A harness running INSIDE another harness's pane — `codex exec` launched
# by Claude Code's Bash tool for a review, `claude -p` spawned by a script
# an agent is running — says nothing at all. Nearest-ancestor wins for
# identity, but the pane belongs to the outer agent: the inner one's
# events would relabel the row's resume record with a one-shot session
# nobody wants back, and its status would flicker over the outer agent's.
# So the walk keeps going after the first match, and a second harness
# further up means exit without reporting.
#
# Wire format — see ControlServer.decide in the app for the contract:
#   {"cmd":"session-event","session":$AGENTS_SESSION_ID,"pane":$AGENTS_PANE_ID,
#    "event":<hook_event_name>,"status":"clear"|"your-turn"|"blocked",
#    "agent":"claude"|"codex","agent_session_id":<session_id>,
#    "agent_home":<CLAUDE_CONFIG_DIR|CODEX_HOME>,"prompt":<preview>}
# status, agent/agent_session_id, agent_home and prompt are each omitted
# when unknown. The app answers {"ok":true} or {"ok":false,"error":...} and
# closes. Waiting for the reply is what makes the write synchronous: the
# event is in the app before the agent's next step.
#
# Why a socket and not the terminal. Earlier versions wrote OSC 777
# desktop-notification escapes to the session's pty and let the app's
# terminal deliver them. Ghostty throttles those app-wide — one notification
# per second across every surface, identical content suppressed for five
# seconds — so the session announcement that followed a status escape by a
# few microseconds was dropped every single time, and two agents reporting
# within a second of each other lost one of the reports. Nothing here could
# tell: the write to the pty had succeeded. A socket line is never
# throttled, never deduplicated, needs no pty discovery (hooks run without a
# controlling terminal), carries the prompt preview without the ~2 KB OSC
# size limit, and gets an answer. The app still accepts the old OSC forms
# from other emitters; this script no longer produces them.
#
# Every event is sent, unconditionally. The app deduplicates on its side —
# a repeated status is a no-op in its reducer, an unchanged announcement
# skips the save — so there is no state to keep here, and no way for a lost
# event to be remembered as delivered.
#
# Gated on the environment the app stamps into every pane it spawns (see
# TerminalCenter.sessionEnvVars): this hook is registered globally in the
# user's Claude Code settings, so it also runs for sessions hosted in iTerm2
# and every other terminal, where those variables are absent and there is
# no app to talk to.
#
# Diagnostics go to ~/Library/Logs/Agents/hook.log, and only when something
# is wrong: a pane with no AGENTS_PANE_ID (the app that spawned it predates
# this script's protocol — update the app), a refusal from the app, or no
# answer at all. Consecutive identical lines are collapsed, since a stale
# app would otherwise produce one per tool call. Set AGENTS_HOOK_DEBUG=1 to
# log every decision, including the nested-harness ones.
#
# Bash + jq rather than babashka (which the rest of this repo uses): hooks
# run on every tool call, so process startup cost is paid constantly. `nc`
# is macOS's own BSD netcat, which speaks AF_UNIX with -U.

# Stdin is drained FIRST, before any early exit: Claude Code writes the hook
# payload into this process's stdin, and exiting before reading it leaves
# the parent writing into a pipe with no reader — an EPIPE on every tool
# call in every terminal that isn't this app.
input=$(cat)

[ -n "${AGENTS_APP:-}" ] || exit 0

log_dir="$HOME/Library/Logs/Agents"
# One line, timestamped, unless it repeats the previous line's message.
log() {
    mkdir -p "$log_dir" 2>/dev/null || return 0
    local msg="$*" last=""
    [ -f "$log_dir/hook.log" ] && last=$(tail -n 1 "$log_dir/hook.log" 2>/dev/null | cut -d' ' -f2-)
    [ "$last" = "$msg" ] && return 0
    printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$msg" >> "$log_dir/hook.log"
}
debug() { [ -n "${AGENTS_HOOK_DEBUG:-}" ] && log "debug: $*"; return 0; }

sock="${AGENTS_CONTROL_SOCK:-}"
session="${AGENTS_SESSION_ID:-}"
pane="${AGENTS_PANE_ID:-}"
if [ -z "$pane" ]; then
    # AGENTS_APP without AGENTS_PANE_ID: an Agents build older than this
    # script's protocol spawned the pane. Nothing to talk to — the app would
    # refuse the verb — but that is the one silence worth explaining.
    log "no AGENTS_PANE_ID in this pane: the Agents app that spawned it predates the socket hook (update the app)"
    exit 0
fi
{ [ -n "$sock" ] && [ -n "$session" ]; } || exit 0
[ -S "$sock" ] || { log "no control socket at $sock (app quit?)"; exit 0; }

event=$(printf '%s' "$input" | jq -r '.hook_event_name // empty')
ntype=$(printf '%s' "$input" | jq -r '.notification_type // empty')
sid=$(printf '%s' "$input" | jq -r '.session_id // empty')
[ -n "$event" ] || exit 0

# The harness whose child we are. The NEAREST matching ancestor names the
# harness, so the real chain — bash(hook) -> /opt/homebrew/bin/claude ->
# -/bin/zsh -> login -> Agents — resolves at the second hop; a further
# match above it means this harness is nested inside another's pane (see
# the header). `ps -o comm=` on macOS prints the executable's path (a login
# shell prints "-/bin/zsh"); the basename is what gets matched.
AGENT=""
NESTED_IN=""
find_agent() {
    local pid=$$ c base
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
        { [ -z "$pid" ] || [ "$pid" = "0" ] || [ "$pid" = "1" ]; } && break
        c=$(ps -o comm= -p "$pid" 2>/dev/null)
        base=${c##*/}
        case "$base" in
            claude*|codex*)
                if [ -z "$AGENT" ]; then
                    AGENT=${base%%[!a-z]*}
                else
                    NESTED_IN=${base%%[!a-z]*}
                    return
                fi
                ;;
        esac
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    done
}
find_agent
if [ -n "$NESTED_IN" ]; then
    debug "$event: $AGENT session $sid is nested inside $NESTED_IN; not reported"
    exit 0
fi
# Claude Code stamps CLAUDECODE=1 into every child's environment, so its
# presence is still good evidence when the walk came up empty (Codex has no
# equivalent marker). With neither, the line goes out without a session.
if [ -z "$AGENT" ] && [ -n "${CLAUDECODE:-}" ]; then
    AGENT="claude"
fi

# The harness's configuration home, when its environment names one. Only
# the harness's OWN variable: a CLAUDE_CONFIG_DIR inherited by a Codex
# session says nothing about where Codex keeps its sessions.
home=""
case "$AGENT" in
    claude) home="${CLAUDE_CONFIG_DIR:-}" ;;
    codex)  home="${CODEX_HOME:-}" ;;
esac

status=""
case "$event" in
    SessionStart|UserPromptSubmit|PreToolUse|PostToolUse) status="clear" ;;
    Stop)              status="your-turn" ;;
    PermissionRequest) status="blocked" ;;
    Notification)
        case "$ntype" in
            permission_prompt) status="blocked" ;;
            idle_prompt)       status="your-turn" ;;
        esac
        ;;
esac

# `-c` keeps the whole request on one line, which is the framing the app's
# reader expects. The prompt (.prompt, or .query as a fallback field name)
# is sliced to its first 200 codepoints: the app caps it there anyway, and a
# pasted novel has no business in a banner heading.
body=$(printf '%s' "$input" | jq -c \
    --arg session "$session" --arg pane "$pane" --arg event "$event" \
    --arg status "$status" --arg agent "$AGENT" --arg sid "$sid" --arg home "$home" '
    {cmd: "session-event", session: $session, pane: $pane, event: $event}
    + (if $status != "" then {status: $status} else {} end)
    + (if $agent != "" and $sid != "" then {agent: $agent, agent_session_id: $sid} else {} end)
    + (if $agent != "" and $sid != "" and $home != "" then {agent_home: $home} else {} end)
    + ((if (.prompt | type) == "string" then .prompt
        elif (.query | type) == "string" then .query
        else null end) as $q
       | if $q != null then {prompt: $q[0:200]} else {} end)
    ' 2>/dev/null) || exit 0
[ -n "$body" ] || exit 0

# -w 2: give up after two idle seconds rather than stall the agent behind an
# app that stopped answering. The reply is not needed here beyond
# diagnostics; the connection staying open until the app has applied the
# event is.
reply=$(printf '%s\n' "$body" | nc -U -w 2 "$sock" 2>/dev/null)
case "$reply" in
    *'"ok":true'*) debug "$event: ${AGENT:-no-agent} $sid -> ok" ;;
    "")            log "$event: no reply from the app at $sock" ;;
    *)             log "$event: refused: $reply" ;;
esac

exit 0
