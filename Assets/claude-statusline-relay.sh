#!/bin/sh
# Token Bar relay for Claude Code's status line.
#
# Claude Code pipes its status JSON to the configured status-line command after
# every turn. This relay stores that JSON privately for Token Bar, which reads
# rate_limits presence as connection evidence, then hands the
# same JSON to an optional existing status-line command given as the arguments.
# Identity-free relay readings are not accepted as account quota. Connect passes
# /bin/sh -c and the original command as one argument to retain shell syntax.
# With no arguments it prints a short line of its own so the status line is not
# blank. Token Bar's Connect Claude Code button writes the settings entry:
#
#   "statusLine": {"type": "command",
#     "command": "\"$HOME/Library/Application Support/CodexTokenBar/claude-statusline-relay.sh\""}
#
#   an existing status line is kept by naming its command after the relay:
#     "command": "'…/claude-statusline-relay.sh' /bin/sh -c '~/.claude/scripts/statusline.sh'"
#
# The file is written 0600 under Token Bar's private support directory. Set
# TOKEN_BAR_CLAUDE_STATUSLINE to relocate it. The relay never fails the status line.
set -u
umask 077
target="${TOKEN_BAR_CLAUDE_STATUSLINE:-$HOME/Library/Application Support/CodexTokenBar/claude-statusline.json}"
input=$(cat)
if [ -n "$input" ]; then
  mkdir -p "$(dirname "$target")" 2>/dev/null
  tmp="$target.$$.tmp"
  if printf '{"received_at_ms":%s,"statusline":%s}\n' "$(( $(date +%s) * 1000 ))" "$input" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$target" 2>/dev/null || rm -f "$tmp"
  fi
fi
if [ "$#" -gt 0 ]; then
  printf '%s' "$input" | "$@"
  exit 0
fi
# Default line: model, context, Claude five-hour remaining. jq if present, else JXA.
if command -v jq >/dev/null 2>&1; then
  printf '%s' "$input" | jq -r '[(.model.display_name // .model.id // empty),
    (.context_window.used_percentage | select(. != null) | "ctx \(floor)%"),
    (.rate_limits.five_hour.used_percentage | select(. != null) | "Claude 5h \(100 - . | floor)% left")]
    | join(" · ")' 2>/dev/null
elif command -v osascript >/dev/null 2>&1; then
  TOKEN_BAR_STATUS_JSON="$input" osascript -l JavaScript -e '
    const d = JSON.parse($.NSProcessInfo.processInfo.environment.objectForKey("TOKEN_BAR_STATUS_JSON").js);
    const p = d.context_window && d.context_window.used_percentage;
    const r = d.rate_limits && d.rate_limits.five_hour;
    [d.model && (d.model.display_name || d.model.id), p != null ? "ctx " + Math.floor(p) + "%" : null,
     r ? "Claude 5h " + Math.floor(Math.max(0, 100 - r.used_percentage)) + "% left" : null].filter(Boolean).join(" · ")' 2>/dev/null
fi
exit 0
