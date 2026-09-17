#!/usr/bin/env bash
# Print the task cache for the widget, or nothing.
#
# The widget used to read the cache file itself. It is a long-lived process
# that cannot open a file the careful way — no deadline on the open, no way to
# refuse a FIFO or a symlink, no ceiling on what it reads — so it no longer
# reads files at all: it runs this, which does all three, and normalises the
# document through the same bounds.jq that fetch.sh publishes through.
#
# That makes every route into the model the same route. A cache that someone
# replaced between two refreshes is held to the same schema, the same string
# lengths and the same array ceilings as one this plugin wrote.
#
# Prints the JSON document on stdout, or nothing at all. Never partial: the
# widget keeps what it has rather than rendering half a task list.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/notion-lib.sh"
BOUNDS="$HERE/bounds.jq"

[[ -f $LIB && -f $BOUNDS ]] || exit 1
# shellcheck source=notion-lib.sh
source "$LIB"
notion_bound_run "${NOTION_READ_DEADLINE:-20}" "$HERE/read-cache.sh" "$@"

command -v jq >/dev/null 2>&1 || exit 1

umask 077
TMP=$(mktemp -d) || exit 1
notion_trap_group "$TMP"

notion_open_dir "$NOTION_STATE_DIR" STATE_FD || exit 1

RAW="$TMP/raw.json"
notion_read_file "$(notion_dir_at "$STATE_FD")/$NOTION_CACHE_NAME" "$NOTION_MAX_CACHE_BYTES" >"$RAW" \
  || exit 1

OUT="$TMP/out.json"
jq -c -f <(cat "$BOUNDS"; echo bounded) "$RAW" >"$OUT" 2>/dev/null || exit 1
(( $(stat -c '%s' "$OUT") <= NOTION_MAX_CACHE_BYTES )) || exit 1

cat "$OUT"
