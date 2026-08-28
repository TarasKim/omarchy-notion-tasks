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

set -uo pipefail

NOTION_VERSION="2022-06-28"
ENV_FILE="$HOME/.config/omarchy/notion-tasks.env"
CONFIG_FILE="$HOME/.config/omarchy/notion-tasks.json"
CACHE="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/notion-tasks.json"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFER="$HERE/notion.jq"

mkdir -p "$(dirname "$CACHE")"
TMPDIR_RUN=$(mktemp -d) || exit 1
trap 'rm -rf "$TMPDIR_RUN"' EXIT

# Record the problem without discarding the tasks already cached: the widget
# shows .error alongside whatever list it last had.
die() {
  local msg="$1"
  if [[ -s $CACHE ]] && jq -e . "$CACHE" >/dev/null 2>&1; then
    jq --arg e "$msg" '.error = $e' "$CACHE" >"$CACHE.tmp" && mv "$CACHE.tmp" "$CACHE"
  else
    jq -n --arg e "$msg" '{updated: null, error: $e, sources: [], tasks: []}' >"$CACHE"
  fi
  echo "$msg" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || die "jq is not installed"
command -v curl >/dev/null 2>&1 || die "curl is not installed"
[[ -f $INFER ]] || die "missing notion.jq next to fetch.sh"
[[ -f $ENV_FILE ]] || die "missing $ENV_FILE — run setup.sh"
[[ -f $CONFIG_FILE ]] || die "no projects configured — run setup.sh"

# shellcheck source=/dev/null
set -a; source "$ENV_FILE"; set +a
[[ -n ${NOTION_TOKEN:-} ]] || die "NOTION_TOKEN not set in $ENV_FILE"

jq -e '.sources | type == "array" and length > 0' >/dev/null 2>&1 <"$CONFIG_FILE" \
  || die "no projects in $CONFIG_FILE — run setup.sh"

ME=$(jq -r '.me // ""' "$CONFIG_FILE")

api_get() {
  curl -fsS --max-time 20 "https://api.notion.com/v1/$1" \
    -H "Authorization: Bearer $NOTION_TOKEN" \
    -H "Notion-Version: $NOTION_VERSION"
}

# Page through a database query, writing the concatenated .results array to $3.
# Pages accumulate as files rather than in a shell variable: a full Notion page
# object is several KB, so 150+ of them passed back through `jq --argjson`
# overflow ARG_MAX and the merge dies with "Argument list too long".
fetch_all() {
  local db="$1" filter="$2" out="$3"
  local cursor="" body resp page=0 dir

  dir=$(mktemp -d -p "$TMPDIR_RUN") || return 1

  while :; do
    # An empty filter object is rejected by Notion, so an unfiltered query has
    # to omit the key entirely rather than send `filter: {}`.
    if [[ $filter == "{}" || -z $filter ]]; then
      if [[ -z $cursor ]]; then
        body=$(jq -n '{page_size: 100}')
      else
        body=$(jq -n --arg c "$cursor" '{page_size: 100, start_cursor: $c}')
      fi
    elif [[ -z $cursor ]]; then
      body=$(jq -n --argjson f "$filter" '{page_size: 100, filter: $f}')
    else
      body=$(jq -n --argjson f "$filter" --arg c "$cursor" '{page_size: 100, filter: $f, start_cursor: $c}')
    fi

    resp=$(curl -fsS --max-time 20 \
      -X POST "https://api.notion.com/v1/databases/$db/query" \
      -H "Authorization: Bearer $NOTION_TOKEN" \
      -H "Notion-Version: $NOTION_VERSION" \
      -H "Content-Type: application/json" \
      -d "$body") || return 1

    jq -e '.results | type == "array"' >/dev/null 2>&1 <<<"$resp" || return 2
    printf '%s' "$resp" | jq '.results' >"$dir/page.$(printf '%03d' "$page").json" || return 2

    [[ $(printf '%s' "$resp" | jq -r '.has_more') == "true" ]] || break
    cursor=$(printf '%s' "$resp" | jq -r '.next_cursor')
    page=$((page + 1))
    (( page < 20 )) || break   # backstop; 2000 open tasks is not a real state
  done

  jq -s 'add // []' "$dir"/page.*.json >"$out" || return 2
  jq -e 'type == "array"' >/dev/null 2>&1 <"$out"
}

# Titles of the rows in a related database, for a capture form's dropdown.
# Cached alongside the tasks so capture needs no round trip of its own.
fetch_relation() {
  local db="$1" out="$2" raw="$TMPDIR_RUN/rel.$RANDOM.json"
  fetch_all "$db" '{}' "$raw" || return 1
  jq '[ .[]
        | { id: .id,
            name: ([ (.properties | to_entries[] | select(.value.type == "title"))
                     | (.value.title // []) | map(.plain_text) | join("") ][0] // "") }
        | select(.name != "") ] | sort_by(.name)' "$raw" >"$out"
}

count=$(jq '.sources | length' "$CONFIG_FILE")
: >"$TMPDIR_RUN/all.sources.json"
: >"$TMPDIR_RUN/all.tasks.json"

for (( i = 0; i < count; i++ )); do
  entry=$(jq -c --argjson i "$i" '.sources[$i]' "$CONFIG_FILE")
  key=$(jq -r '.key // ""' <<<"$entry")
  label=$(jq -r '.label // ""' <<<"$entry")
  db=$(jq -r '.database // ""' <<<"$entry")
  [[ -n $key && -n $db ]] || die "project $i in $CONFIG_FILE needs a key and a database"

  schema_raw="$TMPDIR_RUN/$key.raw.json"
  schema="$TMPDIR_RUN/$key.schema.json"
  api_get "databases/$db" >"$schema_raw" \
    || die "could not read the \"$label\" database (is it shared with the integration?)"

  { cat "$INFER"; echo 'inferred'; } >"$TMPDIR_RUN/infer.jq"
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
  # board can easily relate to half a dozen others.
  rels="$TMPDIR_RUN/$key.rels.json"
  echo '{}' >"$rels"
  while read -r rel; do
    [[ -n $rel ]] || continue
    target=$(jq -r --arg r "$rel" '.relationTargets[$r] // ""' "$schema")
    [[ -n $target ]] || continue
    if fetch_relation "$target" "$TMPDIR_RUN/$key.rel.json"; then
      jq --arg r "$rel" --slurpfile v "$TMPDIR_RUN/$key.rel.json" '. + {($r): $v[0]}' \
        "$rels" >"$rels.tmp" && mv "$rels.tmp" "$rels"
    fi
  done < <(jq -r '(.captureRelations // [])[]' <<<"$entry")

  jq -n --argjson entry "$entry" --slurpfile schema "$schema" --slurpfile rels "$rels" \
    '$entry + $schema[0] + { relations: $rels[0] }' >>"$TMPDIR_RUN/all.sources.json" \
    || die "could not assemble the \"$label\" project"
  cat "$TMPDIR_RUN/$key.tasks.json" >>"$TMPDIR_RUN/all.tasks.json"
done

jq -n \
  --slurpfile sources "$TMPDIR_RUN/all.sources.json" \
  --slurpfile tasks "$TMPDIR_RUN/all.tasks.json" \
  --arg me "$ME" \
  '{ updated: (now | todate), error: null, me: $me,
     sources: $sources,
     tasks: ($tasks | add // []) }' \
  >"$CACHE.tmp" || die "failed to merge task lists"

jq -e '.tasks | type == "array"' >/dev/null 2>&1 <"$CACHE.tmp" \
  || die "built cache was malformed; kept the previous one"

mv "$CACHE.tmp" "$CACHE"
echo "notion-tasks: $(jq -r '
  . as $c
  | [ $c.sources[]
      | .key as $k
      | "\(.label // $k) \([ $c.tasks[] | select(.source == $k) ] | length)"
        + (if .onlyMine then " (\([ $c.tasks[] | select(.source == $k and .mine) ] | length) mine)" else "" end) ]
  | join(", ")' "$CACHE")"
