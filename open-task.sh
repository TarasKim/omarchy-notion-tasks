#!/usr/bin/env bash
# Open a Notion page in the web app, reusing one window instead of leaving a
# new one behind per task.
#
# Chromium derives an --app window's class from the whole URL, so every task
# gets its own class and there is no CLI way to navigate an existing app
# window. The closest achievable behaviour, and what this does:
#
#   already open  -> focus that window
#   otherwise     -> close previous task windows, then open this one
#
# The installed Notion web app (chrome-www.notion.so__*) is deliberately not
# matched, so the main Notion window is never touched.

set -uo pipefail

URL="${1:-}"
[[ -n $URL ]] || { echo "usage: open-task.sh <notion-url>" >&2; exit 1; }

TASK_CLASS_RE='^chrome-app\.notion\.com__'

if command -v hyprctl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  clients=$(hyprctl clients -j 2>/dev/null)

  if [[ -n ${clients:-} ]] && jq -e 'type == "array"' >/dev/null 2>&1 <<<"$clients"; then
    # The 32-hex page id is the stable part of both the URL and the window
    # class; matching on it avoids reimplementing Chromium's slug mangling.
    page_id=$(grep -oE '[0-9a-f]{32}' <<<"$URL" | tail -1)

    if [[ -n $page_id ]]; then
      addr=$(jq -r --arg re "$TASK_CLASS_RE" --arg id "$page_id" '
        .[] | select((.class // "") | test($re))
            | select((.class // "") | contains($id))
            | .address' <<<"$clients" | head -1)

      if [[ -n ${addr:-} && $addr != "null" ]]; then
        # Quattro's Hyprland parses `hyprctl dispatch` as Lua; the bare
        # `focuswindow address:...` form is a syntax error there. Same
        # Lua-first-with-fallback shape omarchy-launch-or-focus uses.
        hyprctl dispatch "hl.dsp.focus({ window = \"address:$addr\" })" >/dev/null 2>&1 \
          || hyprctl dispatch focuswindow "address:$addr" >/dev/null 2>&1
        exit 0
      fi
    fi

    while read -r addr; do
      [[ -n $addr && $addr != "null" ]] || continue
      hyprctl dispatch "hl.dsp.window.close({ window = \"address:$addr\" })" >/dev/null 2>&1 \
        || hyprctl dispatch closewindow "address:$addr" >/dev/null 2>&1
    done < <(jq -r --arg re "$TASK_CLASS_RE" '
      .[] | select((.class // "") | test($re)) | .address' <<<"$clients")
  fi
fi

exec omarchy-launch-webapp "$URL"
