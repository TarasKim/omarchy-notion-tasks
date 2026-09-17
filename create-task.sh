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
#
# Every argument is bounded before it is used. They arrive from a form in a
# long-lived process, and an argv is the one payload that cannot be trimmed
# after the fact — so the limits are applied here, at the edge, and again as a
# ceiling on the assembled request body.

set -uo pipefail

NOTION_VERSION="2022-06-28"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/notion-lib.sh"

[[ -f $LIB ]] || { echo "missing notion-lib.sh next to create-task.sh" >&2; exit 1; }
# shellcheck source=notion-lib.sh
source "$LIB"
notion_bound_run "${NOTION_CREATE_DEADLINE:-120}" "$HERE/create-task.sh" "$@"

die() { echo "$1" >&2; exit 1; }

MAX_TITLE=300
MAX_NOTES=2000
MAX_FIELD=200
MAX_PAIRS=20
MAX_PAYLOAD_BYTES=32768

# A field that arrived over an argv, cut to length and refused if it carries
# anything that is not text.
field() {
  local name="$1" value="$2" max="$3"
  (( ${#value} <= max )) || die "$name is too long (limit $max characters)"
  [[ $value != *[$'\x01'-$'\x1f\x7f']* ]] || die "$name contains control characters"
  printf '%s' "$value"
}

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
    *) die "unknown argument" ;;
  esac
done

[[ -n $title ]] || die "task needs a title"
[[ -n $dest ]]  || die "task needs a destination project"
[[ $dest =~ ^[A-Za-z0-9_-]{1,64}$ ]] || die "that is not a project key"
(( ${#selects[@]} <= MAX_PAIRS )) || die "too many select fields"
(( ${#relations[@]} <= MAX_PAIRS )) || die "too many relation fields"

title=$(field "The title" "$title" $MAX_TITLE) || exit 1
notes=$(field "The notes" "$notes" $MAX_NOTES) || exit 1
priority=$(field "The priority" "$priority" $MAX_FIELD) || exit 1
due=$(field "The due date" "$due" 64) || exit 1

command -v jq >/dev/null 2>&1 || die "jq is not installed"
command -v curl >/dev/null 2>&1 || die "curl is not installed"

umask 077
TMP=$(mktemp -d) || die "could not create a temp directory"
notion_trap_group "$TMP"

NOTION_TOKEN=$(notion_read_token) || die "no usable NOTION_TOKEN — run setup.sh"
# The token travels to curl in a file, never as an argument. See notion-lib.sh.
AUTH=$(notion_auth_file "$TMP" "$NOTION_TOKEN") || die "could not stage the auth header"

# The cache carries the inferred schema, so creating a task costs no extra
# schema request. It is read the same way fetch.sh writes it: through a
# verified descriptor on its own directory, with a ceiling on its size.
notion_open_dir "$NOTION_STATE_DIR" STATE_FD || die "no cache yet — run fetch.sh first"
CACHE="$TMP/cache.json"
notion_read_file "$(notion_dir_at "$STATE_FD")/$NOTION_CACHE_NAME" "$NOTION_MAX_CACHE_BYTES" >"$CACHE" \
  || die "no usable cache yet — run fetch.sh first"

src=$(jq -c --arg k "$dest" '.sources[]? | select(.key == $k)' "$CACHE")
[[ -n $src ]] || die "unknown project"

db=$(jq -r '.database // ""' <<<"$src")
db=$(notion_normalize_id "$db") || die "that project has a malformed database id"

pTitle=$(jq -r '.props.title // ""' <<<"$src")
pStatus=$(jq -r '.props.status // ""' <<<"$src")
pDate=$(jq -r '.props.date // ""' <<<"$src")
pPrio=$(jq -r '.props.priority // ""' <<<"$src")
pOwner=$(jq -r '.props.owner // ""' <<<"$src")
me=$(jq -r '.me // ""' "$CACHE")

[[ -n $pTitle ]] || die "that project has no title property"

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
  due_date=$(resolve_due "$due") || die "could not read that due date"
  [[ $due_date =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "could not read that due date"
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
  [[ $pair == *=* ]] || die "a select field was malformed"
  name=$(field "A select field name" "${pair%%=*}" $MAX_FIELD) || exit 1
  value=$(field "A select field value" "${pair#*=}" $MAX_FIELD) || exit 1
  [[ -n $name ]] || die "a select field was malformed"
  add --arg k "$name" --arg v "$value" '. + {($k): {select: {name: $v}}}'
done

for pair in ${relations+"${relations[@]}"}; do
  [[ $pair == *=* ]] || die "a relation field was malformed"
  name=$(field "A relation field name" "${pair%%=*}" $MAX_FIELD) || exit 1
  # The other half is a page id, so it is checked as one rather than as text.
  value=$(notion_normalize_id "${pair#*=}") || die "a relation points at something that is not a page id"
  [[ -n $name ]] || die "a relation field was malformed"
  add --arg k "$name" --arg v "$value" '. + {($k): {relation: [{id: $v}]}}'
done

PAYLOAD="$TMP/payload.json"
jq -n --arg db "$db" --argjson props "$props" \
  '{parent: {database_id: $db}, properties: $props}' >"$PAYLOAD" \
  || die "could not build the request"
(( $(stat -c '%s' "$PAYLOAD") <= MAX_PAYLOAD_BYTES )) || die "that task is too large to send"

RESP="$TMP/resp.json"
# -f is off here on purpose: Notion's own error body is the message worth
# showing, and curl would throw it away. The size ceiling still applies.
NOTION_CURL_FAIL_SOFT=1 notion_curl "$RESP" -X POST "https://api.notion.com/v1/pages" \
  -H @"$AUTH" \
  -H "Notion-Version: $NOTION_VERSION" \
  -H "Content-Type: application/json" \
  --data-binary @"$PAYLOAD" || die "could not reach Notion"

if [[ $(jq -r '.object // ""' "$RESP") == "error" ]]; then
  msg=$(jq -r '(.message // "unknown error") | .[0:300]' "$RESP")
  if [[ $(jq -r '.code // ""' "$RESP") == "restricted_resource" ]]; then
    msg="$msg (does the integration have Insert content capability?)"
  fi
  die "Notion rejected the task: $msg"
fi

url=$(jq -r '.url // ""' "$RESP")
[[ $url =~ ^https://(www\.)?notion\.so/[A-Za-z0-9._~%/?=\&#+-]{1,500}$ ]] \
  || die "Notion returned no usable page url"

# Refresh so the new task appears without waiting for the poll interval. It
# gets a budget of its own rather than the remains of this one.
notion_run_helper "$HERE/fetch.sh" >/dev/null 2>&1 || true

echo "$url"
