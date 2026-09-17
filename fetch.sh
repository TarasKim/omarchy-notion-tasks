#!/usr/bin/env bash
# Write open tasks from every configured Notion database into the JSON cache
# the omarchy-shell widget reads.
#
# Which databases those are lives in ~/.config/omarchy/notion-tasks.json (run
# setup.sh to build it). *How* to read each one is not configured at all: the
# schema is fetched and the properties inferred, because no two boards agree on
# whether the date is called "Due Date" or "Deadline". See notion.jq.
#
# The widget never talks to Notion itself, so a failure here leaves the last
# good list on screen. Setup: see README.md in this directory.
#
# The handling rules this file is written around all live in notion-lib.sh:
# nothing is read or written by pathname, every response has a byte ceiling
# before it reaches jq, everything parsed has a cardinality ceiling (bounds.jq),
# the cache is published atomically under a lock, and the whole run has a
# deadline that reaches every process it starts.

set -uo pipefail

NOTION_VERSION="2022-06-28"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/notion-lib.sh"
INFER="$HERE/notion.jq"
BOUNDS="$HERE/bounds.jq"

[[ -f $LIB ]] || { echo "missing notion-lib.sh next to fetch.sh" >&2; exit 1; }
# shellcheck source=notion-lib.sh
source "$LIB"

# Re-exec under a deadline, in a session of our own. Everything below runs
# inside that, and nothing below can outlive it. See notion_bound_run.
notion_bound_run "${NOTION_FETCH_DEADLINE:-240}" "$HERE/fetch.sh" "$@"

ENV_FILE="$NOTION_ENV_FILE"
CONFIG_FILE="$NOTION_CONFIG_FILE"

# One page of a Notion query is 100 rows; the row ceiling and the page
# backstop agree with MAX_TASKS in bounds.jq, so nothing is fetched that would
# only be thrown away at the end.
MAX_PAGES=20
MAX_ROWS=2000
MAX_BODY_BYTES=65536

umask 077
TMPDIR_RUN=$(mktemp -d) || exit 1
notion_trap_group "$TMPDIR_RUN"

# The state directory is ours alone — mode 700, inside omarchy's, which is
# shared with other components — and it is opened once. Every read and write
# of the cache below goes through that descriptor rather than through the name
# it was opened under, so replacing the directory mid-refresh cannot redirect
# one. The lock is taken on the descriptor too: timer, manual, create and
# status refreshes overlap constantly, and two of them publishing at once is
# how you get half a task list.
notion_open_dir "$NOTION_STATE_DIR" STATE_FD 700 \
  || { echo "cannot use $NOTION_STATE_DIR — check its owner and permissions" >&2; exit 1; }
STATE_AT="$(notion_dir_at "$STATE_FD")"
flock -w 30 "$STATE_FD" || { echo "another refresh is still running" >&2; exit 1; }

# Record the problem without discarding the tasks already cached: the widget
# shows .error alongside whatever list it last had.
die() {
  local msg="$1" prev="$TMPDIR_RUN/prev.json" next="$TMPDIR_RUN/err.json"
  if notion_read_file "$STATE_AT/$NOTION_CACHE_NAME" "$NOTION_MAX_CACHE_BYTES" >"$prev" 2>/dev/null \
     && jq -e . "$prev" >/dev/null 2>&1; then
    jq --arg e "$msg" '.error = $e' "$prev" >"$next" 2>/dev/null
  else
    jq -n --arg e "$msg" '{updated: null, error: $e, sources: [], tasks: []}' >"$next" 2>/dev/null
  fi
  [[ -s $next ]] && notion_publish "$STATE_FD" "$NOTION_CACHE_NAME" 600 "$NOTION_MAX_CACHE_BYTES" <"$next"
  echo "$msg" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || die "jq is not installed"
command -v curl >/dev/null 2>&1 || die "curl is not installed"
[[ -f $INFER ]] || die "missing notion.jq next to fetch.sh"
[[ -f $BOUNDS ]] || die "missing bounds.jq next to fetch.sh"

CONFIG="$TMPDIR_RUN/config.json"
notion_read_file "$CONFIG_FILE" "$NOTION_MAX_CONFIG_BYTES" >"$CONFIG" \
  || die "cannot read $CONFIG_FILE — run setup.sh (it has to be a regular file you own)"

NOTION_TOKEN=$(notion_read_token) \
  || die "no usable NOTION_TOKEN in $ENV_FILE — run setup.sh"
# The token travels to curl in a file, never as an argument. See notion-lib.sh.
AUTH=$(notion_auth_file "$TMPDIR_RUN" "$NOTION_TOKEN") || die "could not stage the auth header"

jq -e '.sources | type == "array" and length > 0' >/dev/null 2>&1 <"$CONFIG" \
  || die "no projects in $CONFIG_FILE — run setup.sh"

ME=$(jq -r '.me // ""' "$CONFIG")
[[ $ME =~ ^[0-9a-fA-F-]{0,40}$ ]] || die "the \"me\" id in $CONFIG_FILE is malformed"

api_get() {
  notion_curl "$2" "https://api.notion.com/v1/$1" \
    -H @"$AUTH" \
    -H "Notion-Version: $NOTION_VERSION"
}

# Page through a database query, writing the concatenated .results array to $3.
# Pages accumulate as files rather than in a shell variable: a full Notion page
# object is several KB, so 150+ of them passed back through `jq --argjson`
# overflow ARG_MAX and the merge dies with "Argument list too long". The
# request body travels as a file for the same reason, and because an argv is
# the one place a payload cannot be bounded after the fact.
fetch_all() {
  local db="$1" filter="$2" out="$3"
  local cursor="" page=0 rows=0 dir body resp got file

  dir=$(mktemp -d -p "$TMPDIR_RUN") || return 1
  body="$dir/body.json"
  resp="$dir/resp.json"

  while :; do
    # An empty filter object is rejected by Notion, so an unfiltered query has
    # to omit the key entirely rather than send `filter: {}`.
    if [[ $filter == "{}" || -z $filter ]]; then
      if [[ -z $cursor ]]; then
        jq -n '{page_size: 100}' >"$body"
      else
        jq -n --arg c "$cursor" '{page_size: 100, start_cursor: $c}' >"$body"
      fi
    elif [[ -z $cursor ]]; then
      jq -n --argjson f "$filter" '{page_size: 100, filter: $f}' >"$body"
    else
      jq -n --argjson f "$filter" --arg c "$cursor" '{page_size: 100, filter: $f, start_cursor: $c}' >"$body"
    fi
    (( $(stat -c '%s' "$body" 2>/dev/null || echo $((MAX_BODY_BYTES + 1))) <= MAX_BODY_BYTES )) || return 2

    notion_curl "$resp" -X POST "https://api.notion.com/v1/databases/$db/query" \
      -H @"$AUTH" \
      -H "Notion-Version: $NOTION_VERSION" \
      -H "Content-Type: application/json" \
      --data-binary @"$body" || return 1

    jq -e '.results | type == "array"' >/dev/null 2>&1 <"$resp" || return 2
    file="$dir/page.$(printf '%03d' "$page").json"
    jq '.results' "$resp" >"$file" || return 2

    got=$(jq 'length' "$file" 2>/dev/null) || return 2
    rows=$(( rows + got ))
    (( rows < MAX_ROWS )) || break

    [[ $(jq -r '.has_more' "$resp") == "true" ]] || break
    cursor=$(jq -r '.next_cursor // ""' "$resp")
    # An opaque cursor from the other end still ends up in a request body, so
    # it is checked rather than echoed back on trust.
    [[ $cursor =~ ^[A-Za-z0-9_:-]{1,256}$ ]] || break
    page=$((page + 1))
    (( page < MAX_PAGES )) || break
  done

  jq -s --argjson max "$MAX_ROWS" 'add // [] | .[0:$max]' "$dir"/page.*.json >"$out" || return 2
  jq -e 'type == "array"' >/dev/null 2>&1 <"$out"
}

# Titles of the rows in a related database, for a capture form's dropdown.
# Cached alongside the tasks so capture needs no round trip of its own.
fetch_relation() {
  local db="$1" out="$2" raw
  raw=$(mktemp -p "$TMPDIR_RUN") || return 1
  fetch_all "$db" '{}' "$raw" || return 1
  jq '[ .[]
        | { id: .id,
            name: ([ (.properties | to_entries[] | select(.value.type == "title"))
                     | (.value.title // []) | map(.plain_text) | join("") ][0] // "") }
        | select(.name != "") ] | sort_by(.name)' "$raw" >"$out"
}

count=$(jq '.sources | length' "$CONFIG")
: >"$TMPDIR_RUN/all.sources.json"
: >"$TMPDIR_RUN/all.tasks.json"
{ cat "$INFER"; echo 'inferred'; } >"$TMPDIR_RUN/infer.jq"

for (( i = 0; i < count; i++ )); do
  entry=$(jq -c --argjson i "$i" '.sources[$i]' "$CONFIG")
  key=$(jq -r '.key // ""' <<<"$entry")
  label=$(jq -r '.label // ""' <<<"$entry")
  db=$(jq -r '.database // ""' <<<"$entry")
  [[ -n $key && -n $db ]] || die "project $i in $CONFIG_FILE needs a key and a database"

  # $key becomes a filename below and $db goes into a request path. setup.sh
  # only ever writes safe values, but this config file is documented, so it
  # gets hand-edited; neither is checked anywhere else.
  [[ $key =~ ^[A-Za-z0-9_-]{1,64}$ ]] \
    || die "project key \"$key\" in $CONFIG_FILE must be 1-64 of letters, digits, - or _"
  db=$(notion_normalize_id "$db") \
    || die "a database id in $CONFIG_FILE is not 32 hex digits"

  schema_raw="$TMPDIR_RUN/$key.raw.json"
  schema="$TMPDIR_RUN/$key.schema.json"
  api_get "databases/$db" "$schema_raw" \
    || die "could not read the \"$label\" database (is it shared with the integration?)"

  jq -f "$TMPDIR_RUN/infer.jq" "$schema_raw" >"$schema" \
    || die "could not read the schema of \"$label\""

  jq -e '.props.title != null and .props.status != null' >/dev/null 2>&1 <"$schema" \
    || die "\"$label\" has no title or no status property — it is not a task board"

  # Everything the board does not file under Complete. Asking by group rather
  # than by name means a renamed status cannot silently empty the widget.
  filter=$(jq -c --arg prop "$(jq -r '.props.status' "$schema")" \
             '{ or: [ .statuses[] | select(.group != "Complete")
                      | { property: $prop, status: { equals: .name } } ] }' "$schema")

  rows="$TMPDIR_RUN/$key.rows.json"
  fetch_all "$db" "$filter" "$rows" \
    || die "Notion request failed for \"$label\" (is it shared with the integration?)"

  jq --arg key "$key" --arg me "$ME" \
     --arg pTitle "$(jq -r '.props.title // ""' "$schema")" \
     --arg pStatus "$(jq -r '.props.status // ""' "$schema")" \
     --arg pDate "$(jq -r '.props.date // ""' "$schema")" \
     --arg pPrio "$(jq -r '.props.priority // ""' "$schema")" \
     --arg pOwner "$(jq -r '.props.owner // ""' "$schema")" \
     --argjson prios "$(jq -c '.priorities' "$schema")" \
     --argjson sts "$(jq -c '.statuses' "$schema")" \
     '[ .[]
        # Bound before use: index/1 evaluates its argument against its own
        # input, so `$prios | index(.properties…)` would look for "properties"
        # on the priorities array rather than on the row.
        | (if $pPrio == "" then "" else (.properties[$pPrio].select.name // "") end) as $pname
        | {
          id:       .id,
          name:     ((.properties[$pTitle].title // []) | map(.plain_text) | join("")),
          status:   (.properties[$pStatus].status.name // ""),
          # To-do / In progress / Complete. Carried so the row can be coloured
          # on a board whose status wording nobody has ever seen before.
          statusGroup: ((.properties[$pStatus].status.name // "") as $sn
                        | ([ $sts[] | select(.name == $sn) | .group ][0] // "")),
          priority: $pname,
          # Position in the option order the board itself defines, which is
          # what makes Eisenhower (Do/Decide/Delegate/Delete) and MoSCoW
          # (Must/Should/Could/Wont) both sort right with neither of them
          # written down anywhere. Untriaged sits just above the bottom
          # option: it has not been judged, so it must not outrank something
          # explicitly marked important, but neither is it an explicit no.
          rank:     (if $pPrio == "" then 0
                     else (($prios | index($pname)) // (($prios | length) - 1.5))
                     end),
          due:      (if $pDate == "" then null else (.properties[$pDate].date.start // null) end),
          url:      .url,
          source:   $key,
          # A board with no people property is one where everything is yours.
          mine:     (if $pOwner == "" then true
                     else ([ (.properties[$pOwner].people // [])[].id ] | index($me) != null)
                     end)
        } | select(.name != "") ]' "$rows" >"$TMPDIR_RUN/$key.tasks.json" \
    || die "could not read the tasks in \"$label\""

  # Relation dropdowns are opt-in: each one costs a full query, and a task
  # board can easily relate to half a dozen others. Eight is the ceiling
  # bounds.jq keeps, so nothing is fetched that would only be dropped.
  rels="$TMPDIR_RUN/$key.rels.json"
  echo '{}' >"$rels"
  while read -r rel; do
    [[ -n $rel ]] || continue
    target=$(jq -r --arg r "$rel" '.relationTargets[$r] // ""' "$schema")
    [[ -n $target ]] || continue
    target=$(notion_normalize_id "$target") || continue
    if fetch_relation "$target" "$TMPDIR_RUN/$key.rel.json"; then
      jq --arg r "$rel" --slurpfile v "$TMPDIR_RUN/$key.rel.json" '. + {($r): $v[0]}' \
        "$rels" >"$rels.tmp" && mv "$rels.tmp" "$rels"
    fi
  done < <(jq -r '((.captureRelations // []) | .[0:8])[]' <<<"$entry")

  jq -n --argjson entry "$entry" --slurpfile schema "$schema" --slurpfile rels "$rels" \
    '$entry + $schema[0] + { relations: $rels[0] }' >>"$TMPDIR_RUN/all.sources.json" \
    || die "could not assemble the \"$label\" project"
  cat "$TMPDIR_RUN/$key.tasks.json" >>"$TMPDIR_RUN/all.tasks.json"
done

BUILT="$TMPDIR_RUN/built.json"
jq -n \
  --slurpfile sources "$TMPDIR_RUN/all.sources.json" \
  --slurpfile tasks "$TMPDIR_RUN/all.tasks.json" \
  --arg me "$ME" \
  '{ updated: (now | todate), error: null, me: $me,
     sources: $sources,
     tasks: ($tasks | add // []) }' \
  >"$BUILT" || die "failed to merge task lists"

# Last gate before anything reaches the widget: every array and every string
# cut to the ceilings in bounds.jq, and then the whole document weighed. A
# cache that is still too big after capping is a bug here, not something to
# hand to a long-lived process.
FINAL="$TMPDIR_RUN/final.json"
jq -f <(cat "$BOUNDS"; echo bounded) "$BUILT" >"$FINAL" \
  || die "built cache was malformed; kept the previous one"
jq -e '.tasks | type == "array"' >/dev/null 2>&1 <"$FINAL" \
  || die "built cache was malformed; kept the previous one"
(( $(stat -c '%s' "$FINAL") <= NOTION_MAX_CACHE_BYTES )) \
  || die "built cache was over its size limit; kept the previous one"

notion_publish "$STATE_FD" "$NOTION_CACHE_NAME" 600 "$NOTION_MAX_CACHE_BYTES" <"$FINAL" \
  || die "could not publish the cache"

# The cache used to sit loose in omarchy's shared state directory. It is ours
# and nobody else reads it, so the old copy goes rather than being left behind
# holding a stale task list.
LEGACY="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/notion-tasks.json"
[[ -f $LEGACY && ! -L $LEGACY ]] && rm -f -- "$LEGACY"

echo "notion-tasks: $(jq -r '
  . as $c
  | [ $c.sources[]
      | .key as $k
      | "\(.label // $k) \([ $c.tasks[] | select(.source == $k) ] | length)"
        + (if .onlyMine then " (\([ $c.tasks[] | select(.source == $k and .mine) ] | length) mine)" else "" end) ]
  | join(", ")' "$FINAL")"
