#!/usr/bin/env bash
# Create a task in one of the configured Notion databases and refresh cache.
#
#   create-task.sh --dest KEY --title TEXT
#                  [--priority NAME] [--due WHEN]
#                  [--select NAME=VALUE]... [--relation NAME=PAGE_ID]...
#                  [--notes TEXT]
#
# KEY is a project key from ~/.config/omarchy/notion-tasks.json. Which property
# holds the title, the status, the date and the owner is not passed in: it is
# read from the cache that fetch.sh already built from the board schema.
#
# --due accepts today | tomorrow | +Nd | YYYY-MM-DD.
# Prints the created page URL on success; anything on stderr is shown by the
# widget, so messages here are user-facing.

set -uo pipefail

NOTION_VERSION="2022-06-28"
ENV_FILE="$HOME/.config/omarchy/notion-tasks.env"
CONFIG_FILE="$HOME/.config/omarchy/notion-tasks.json"
CACHE="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/notion-tasks.json"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/notion-lib.sh"

die() { echo "$1" >&2; exit 1; }

dest="" title="" priority="" due="" notes=""
selects=() relations=()
while (($#)); do
  case "$1" in
    --dest)     dest="${2:-}"; shift 2 ;;
    --title)    title="${2:-}"; shift 2 ;;
    --priority) priority="${2:-}"; shift 2 ;;
    --due)      due="${2:-}"; shift 2 ;;
    --notes)    notes="${2:-}"; shift 2 ;;
    --select)   selects+=("${2:-}"); shift 2 ;;
    --relation) relations+=("${2:-}"); shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n $title ]] || die "task needs a title"
[[ -n $dest ]]  || die "task needs a destination project"

command -v jq >/dev/null 2>&1 || die "jq is not installed"
command -v curl >/dev/null 2>&1 || die "curl is not installed"
[[ -f $LIB ]] || die "missing notion-lib.sh next to create-task.sh"
[[ -f $ENV_FILE ]] || die "missing $ENV_FILE"

# shellcheck source=notion-lib.sh
NOTION_ENV_FILE="$ENV_FILE"; source "$LIB"
NOTION_TOKEN=$(notion_read_token) || die "NOTION_TOKEN not set"

TMP=$(mktemp -d) || die "could not create a temp directory"
trap 'rm -rf "$TMP"' EXIT
# The token travels to curl in a file, never as an argument. See notion-lib.sh.
AUTH=$(notion_auth_file "$TMP" "$NOTION_TOKEN") || die "could not stage the auth header"

# The cache carries the inferred schema, so creating a task costs no extra
# schema request. It is written by fetch.sh before the widget can offer a
# capture form at all, so it is always there by the time this runs.
[[ -s $CACHE ]] || die "no cache yet — run fetch.sh first"
src=$(jq -c --arg k "$dest" '.sources[]? | select(.key == $k)' "$CACHE")
[[ -n $src ]] || die "unknown project: $dest"

db=$(jq -r '.database // ""' <<<"$src")
[[ -n $db ]] || die "project $dest has no database id"
db=$(notion_normalize_id "$db") || die "project $dest has a malformed database id"

pTitle=$(jq -r '.props.title // ""' <<<"$src")
pStatus=$(jq -r '.props.status // ""' <<<"$src")
pDate=$(jq -r '.props.date // ""' <<<"$src")
pPrio=$(jq -r '.props.priority // ""' <<<"$src")
pOwner=$(jq -r '.props.owner // ""' <<<"$src")
me=$(jq -r '.me // ""' "$CACHE")

[[ -n $pTitle ]] || die "project $dest has no title property"

# The first status the board files under To-do — its own idea of "new", which
# is "To Do" on one board here and "Not started" on the other.
newStatus=$(jq -r '[ .statuses[]? | select(.group == "To-do") ][0].name // ""' <<<"$src")

# today | tomorrow | +Nd | YYYY-MM-DD -> YYYY-MM-DD
resolve_due() {
  local raw="$1"
  [[ -n $raw ]] || return 0
  case "$raw" in
    today)      date -d today +%F ;;
    tomorrow)   date -d tomorrow +%F ;;
    +[0-9]*d)   date -d "+${raw:1:${#raw}-2} days" +%F ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) printf '%s' "$raw" ;;
    *)          date -d "$raw" +%F 2>/dev/null || return 1 ;;
  esac
}

due_date=""
if [[ -n $due ]]; then
  due_date=$(resolve_due "$due") || die "could not read due date: $due"
fi

props=$(jq -n --arg t "$title" --arg p "$pTitle" '{ ($p): { title: [ { text: { content: $t } } ] } }')

add() { props=$(jq "$@" <<<"$props"); }

[[ -n $pStatus && -n $newStatus ]] && \
  add --arg k "$pStatus" --arg v "$newStatus" '. + {($k): {status: {name: $v}}}'
[[ -n $pPrio && -n $priority ]] && \
  add --arg k "$pPrio" --arg v "$priority" '. + {($k): {select: {name: $v}}}'
[[ -n $pDate && -n $due_date ]] && \
  add --arg k "$pDate" --arg v "$due_date" '. + {($k): {date: {start: $v}}}'
# Owned by you, so a captured task lands in the widget's default "mine" view
# instead of disappearing into a team backlog.
[[ -n $pOwner && -n $me ]] && \
  add --arg k "$pOwner" --arg v "$me" '. + {($k): {people: [{object: "user", id: $v}]}}'
[[ -n $notes ]] && \
  add --arg v "$notes" '. + {"Notes": {rich_text: [{text: {content: $v}}]}}'

for pair in ${selects+"${selects[@]}"}; do
  [[ $pair == *=* ]] || die "--select needs NAME=VALUE, got: $pair"
  add --arg k "${pair%%=*}" --arg v "${pair#*=}" '. + {($k): {select: {name: $v}}}'
done

for pair in ${relations+"${relations[@]}"}; do
  [[ $pair == *=* ]] || die "--relation needs NAME=PAGE_ID, got: $pair"
  add --arg k "${pair%%=*}" --arg v "${pair#*=}" '. + {($k): {relation: [{id: $v}]}}'
done

payload=$(jq -n --arg db "$db" --argjson props "$props" '{parent: {database_id: $db}, properties: $props}')

resp=$(curl -sS --max-time 20 -X POST "https://api.notion.com/v1/pages" \
  -H @"$AUTH" \
  -H "Notion-Version: $NOTION_VERSION" \
  -H "Content-Type: application/json" \
  -d "$payload") || die "could not reach Notion"

if [[ $(jq -r '.object // ""' <<<"$resp") == "error" ]]; then
  msg=$(jq -r '.message // "unknown error"' <<<"$resp")
  if [[ $(jq -r '.code // ""' <<<"$resp") == "restricted_resource" ]]; then
    msg="$msg (does the integration have Insert content capability?)"
  fi
  die "Notion rejected the task: $msg"
fi

url=$(jq -r '.url // ""' <<<"$resp")
[[ -n $url ]] || die "Notion returned no page url"

# Refresh so the new task appears without waiting for the poll interval.
bash "$HERE/fetch.sh" >/dev/null 2>&1 || true

echo "$url"
