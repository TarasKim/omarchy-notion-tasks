#!/usr/bin/env bash
# Open a Notion page in the web app, reusing one window instead of leaving a
# new one behind per task.
#
# Chromium derives an --app window's class from the whole URL, so every task
# gets its own class and there is no CLI way to navigate an existing app
# window. The closest achievable behaviour, and what this does:
#
#   already open  -> focus that window
#   otherwise     -> close the previous window for a task, then open this one
#
# The installed Notion web app (chrome-www.notion.so__*) is deliberately not
# matched, so the main Notion window is never touched.
#
# Everything here is reached from a cache that describes rows other people can
# edit, so nothing is taken on trust: the URL has to be a Notion page URL and
# nothing else, the window list is read with a deadline and a ceiling, and a
# window address has to look like an address before it reaches a dispatch.

set -uo pipefail

MAX_URL=512
MAX_CLIENTS_BYTES=2000000
HYPRCTL_TIMEOUT=5

URL="${1:-}"
[[ -n $URL ]] || { echo "usage: open-task.sh <notion-url>" >&2; exit 1; }
(( ${#URL} <= MAX_URL )) || { echo "open-task.sh: that url is too long" >&2; exit 1; }

# An exact host and an ordinary URL path, with the 32-hex page id Notion puts
# at the end of every page and database URL. Anything else — another host, a
# scheme that is not https, a shell metacharacter, whitespace — is refused
# rather than handed to a launcher.
[[ $URL =~ ^https://(www\.|app\.)?notion\.(so|com)/[A-Za-z0-9._~%/?=\&#+-]*$ ]] \
  || { echo "open-task.sh: that is not a Notion page url" >&2; exit 1; }

page_id=$(grep -oE '[0-9a-f]{32}' <<<"${URL,,}" | tail -1)
[[ -n $page_id ]] \
  || { echo "open-task.sh: that url carries no Notion page id" >&2; exit 1; }

TASK_CLASS_RE='^chrome-app\.notion\.com__'

if command -v hyprctl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  # hyprctl is fast, but it is also a process reading a socket: give it a
  # deadline, and a ceiling on how much of an answer it can give.
  clients=$(timeout "$HYPRCTL_TIMEOUT" hyprctl clients -j 2>/dev/null | head -c "$MAX_CLIENTS_BYTES")

  if [[ -n ${clients:-} ]] && jq -e 'type == "array"' >/dev/null 2>&1 <<<"$clients"; then
    # The 32-hex page id is the stable part of both the URL and the window
    # class; matching on it avoids reimplementing Chromium's slug mangling.
    # Only windows whose class is one of ours *and* carries a page id are
    # considered at all — a window this plugin did not open is not ours to
    # close.
    mapfile -t theirs < <(jq -r --arg re "$TASK_CLASS_RE" '
      .[] | select((.class // "") | test($re))
          | select((.class // "") | test("[0-9a-f]{32}"))
          | .address' <<<"$clients" | head -64)

    addr=""
    for a in ${theirs+"${theirs[@]}"}; do
      # A window address reaches a dispatch expression, so it has to be an
      # address: hex, nothing else, no matter what the compositor reported.
      [[ $a =~ ^0x[0-9a-fA-F]{1,16}$ ]] || continue
      if jq -e --arg a "$a" --arg id "$page_id" '
            any(.[]; (.address == $a) and ((.class // "") | contains($id)))' \
            >/dev/null 2>&1 <<<"$clients"; then
        addr="$a"
        break
      fi
    done

    if [[ -n $addr ]]; then
      # Quattro's Hyprland parses `hyprctl dispatch` as Lua; the bare
      # `focuswindow address:...` form is a syntax error there. Same
      # Lua-first-with-fallback shape omarchy-launch-or-focus uses.
      timeout "$HYPRCTL_TIMEOUT" hyprctl dispatch "hl.dsp.focus({ window = \"address:$addr\" })" >/dev/null 2>&1 \
        || timeout "$HYPRCTL_TIMEOUT" hyprctl dispatch focuswindow "address:$addr" >/dev/null 2>&1
      exit 0
    fi

    for a in ${theirs+"${theirs[@]}"}; do
      [[ $a =~ ^0x[0-9a-fA-F]{1,16}$ ]] || continue
      timeout "$HYPRCTL_TIMEOUT" hyprctl dispatch "hl.dsp.window.close({ window = \"address:$a\" })" >/dev/null 2>&1 \
        || timeout "$HYPRCTL_TIMEOUT" hyprctl dispatch closewindow "address:$a" >/dev/null 2>&1
    done
  fi
fi

exec omarchy-launch-webapp "$URL"
