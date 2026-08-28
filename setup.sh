#!/usr/bin/env bash
# Interactive setup: connect a Notion integration and choose which of its
# databases are task boards.
#
# It asks two things only — who you are, and which boards to show. Everything
# else (which property is the title, the status, the deadline, the owner; what
# the priorities are called; which status means done) is read from each board
# schema at fetch time. See notion.jq.

set -uo pipefail

NOTION_VERSION="2022-06-28"
ENV_FILE="$HOME/.config/omarchy/notion-tasks.env"
CONFIG_FILE="$HOME/.config/omarchy/notion-tasks.json"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { printf '\n%s\n' "$1" >&2; exit 1; }
say() { printf '%s\n' "$1"; }
head2() { printf '\n\033[1m%s\033[0m\n' "$1"; }

for c in jq curl gum; do
  command -v "$c" >/dev/null 2>&1 || die "$c is required but not installed."
done

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

api() {
  curl -fsS --max-time 20 "https://api.notion.com/v1/$1" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Notion-Version: $NOTION_VERSION" "${@:2}"
}

# ---- 1. token -------------------------------------------------------------

head2 "1. Notion integration"
cat <<'TXT'
This needs an internal integration in your own workspace.

  1. Open https://www.notion.so/profile/integrations -> New integration
  2. Make it internal, pick your workspace
  3. Under Capabilities tick: Read content, Insert content, Update content
  4. Copy the Internal Integration Secret (it starts with ntn_)

Then share each task board with it: open the database, ... -> Connections ->
add your integration. A board that is not shared returns 404 even with a
valid token.
TXT

TOKEN=""
if [[ -f $ENV_FILE ]]; then
  # shellcheck source=/dev/null
  set -a; source "$ENV_FILE"; set +a
  if [[ -n ${NOTION_TOKEN:-} ]] && gum confirm "Reuse the token already in $ENV_FILE?"; then
    TOKEN="$NOTION_TOKEN"
  fi
fi

if [[ -z $TOKEN ]]; then
  TOKEN=$(gum input --password --placeholder "ntn_...") || exit 1
  [[ -n $TOKEN ]] || die "No token given."
fi

gum spin --title "Checking the token..." -- \
  curl -fsS --max-time 20 "https://api.notion.com/v1/users/me" \
    -H "Authorization: Bearer $TOKEN" -H "Notion-Version: $NOTION_VERSION" \
    -o "$TMP/me.json" \
  || die "Notion rejected that token."
say "Connected as integration \"$(jq -r '.name // "unnamed"' "$TMP/me.json")\"."

# ---- 2. who you are -------------------------------------------------------
# A workspace-level integration has no owner to read back, so the one person
# it cannot work out on its own is which member you are.

head2 "2. Which person are you?"
api "users?page_size=100" >"$TMP/users.json" || die "Could not list workspace members."
jq -r '[.results[] | select(.type == "person")] | length' "$TMP/users.json" >"$TMP/n"
if [[ $(cat "$TMP/n") -eq 0 ]]; then
  say "No people visible; owner filtering will be off."
  ME=""
else
  mapfile -t PEOPLE < <(jq -r '.results[] | select(.type=="person")
                               | "\(.name)  <\(.person.email // "no email")>  \(.id)"' "$TMP/users.json")
  pick=$(printf '%s\n' "${PEOPLE[@]}" | gum choose --header "Used to tell your tasks from everyone else's") || exit 1
  ME="${pick##*  }"
  say "You are ${pick%%  <*}."
fi

# ---- 3. which boards ------------------------------------------------------

head2 "3. Which databases are task boards?"
gum spin --title "Looking for databases shared with the integration..." -- \
  curl -fsS --max-time 20 -X POST "https://api.notion.com/v1/search" \
    -H "Authorization: Bearer $TOKEN" -H "Notion-Version: $NOTION_VERSION" \
    -H "Content-Type: application/json" \
    -d '{"filter":{"value":"database","property":"object"},"page_size":100}' \
    -o "$TMP/search.json" \
  || die "Search failed."

# A task board is anything with a title and a status. That is a loose test on
# purpose — it is a shortlist to choose from, not a verdict. Sharing a
# workspace usually exposes clients, cycles and idea lists too, and only you
# know which of them you actually work off.
jq -r '[ .results[]
         | { id: .id,
             title: ((.title // []) | map(.plain_text) | join("")),
             hasTitle: ([ .properties[] | select(.type == "title") ] | length > 0),
             hasStatus: ([ .properties[] | select(.type == "status") ] | length > 0) }
         | select(.hasTitle and .hasStatus and .title != "") ]
       | sort_by(.title)' "$TMP/search.json" >"$TMP/cands.json"

count=$(jq 'length' "$TMP/cands.json")
(( count > 0 )) || die "No database with a title and a status property is shared with this integration."

say "$count shared databases look like task boards."
mapfile -t LABELS < <(jq -r '.[] | "\(.title)  ·  \(.id)"' "$TMP/cands.json")
mapfile -t CHOSEN < <(printf '%s\n' "${LABELS[@]}" \
  | gum choose --no-limit --header "Space to select, Enter to confirm") || exit 1
(( ${#CHOSEN[@]} > 0 )) || die "Nothing chosen."

# ---- 4. order -------------------------------------------------------------
# Order is display order: the first board is the first group in the popup, and
# ties in the sort break its way. Worth asking rather than guessing.

ORDERED=()
if (( ${#CHOSEN[@]} > 1 )); then
  head2 "4. What order should they appear in?"
  remaining=("${CHOSEN[@]}")
  while (( ${#remaining[@]} > 1 )); do
    pick=$(printf '%s\n' "${remaining[@]}" \
      | gum choose --header "Next after: ${ORDERED[*]:+$(printf '%s, ' "${ORDERED[@]%%  ·*}")}") || exit 1
    ORDERED+=("$pick")
    next=()
    for r in "${remaining[@]}"; do [[ $r == "$pick" ]] || next+=("$r"); done
    remaining=("${next[@]}")
  done
  ORDERED+=("${remaining[0]}")
else
  ORDERED=("${CHOSEN[@]}")
fi

# ---- 5. per-board questions ----------------------------------------------

head2 "5. Details"
: >"$TMP/sources.jsonl"
used_keys=""

for entry in "${ORDERED[@]}"; do
  db="${entry##*·  }"
  db="${db// /}"
  title="${entry%%  ·*}"

  api "databases/$db" >"$TMP/db.json" || die "Could not read $title."

  label=$(gum input --value "$title" --header "Display name for \"$title\"") || exit 1
  [[ -n $label ]] || label="$title"

  # Keys identify a board in the cache and in shell.json, so they have to be
  # stable and file-safe; the label can be anything.
  key=$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//; s/-$//')
  [[ -n $key ]] || key="board"
  base="$key"; n=2
  while printf '%s' "$used_keys" | command grep -qx "$key"; do key="$base-$n"; n=$((n + 1)); done
  used_keys="$used_keys
$key"

  only_mine=false
  if [[ -n $ME ]] && jq -e '[ .properties[] | select(.type == "people") ] | length > 0' >/dev/null "$TMP/db.json"; then
    if gum confirm --default=no "\"$label\": show only tasks assigned to you?"; then only_mine=true; fi
  fi

  rels="[]"
  mapfile -t RELNAMES < <(jq -r '.properties | to_entries[] | select(.value.type == "relation") | .key' "$TMP/db.json")
  if (( ${#RELNAMES[@]} > 0 )); then
    if gum confirm --default=no "\"$label\": offer any linked databases when creating a task?"; then
      mapfile -t PICKED < <(printf '%s\n' "${RELNAMES[@]}" \
        | gum choose --no-limit --header "Each one costs a request per refresh") || true
      if (( ${#PICKED[@]} > 0 )); then
        rels=$(printf '%s\n' "${PICKED[@]}" | jq -R . | jq -s .)
      fi
    fi
  fi

  jq -nc --arg key "$key" --arg label "$label" --arg db "$db" \
         --argjson mine "$only_mine" --argjson rels "$rels" \
    '{key: $key, label: $label, database: $db, onlyMine: $mine, captureRelations: $rels}' \
    >>"$TMP/sources.jsonl"
done

# ---- 6. write -------------------------------------------------------------

jq -s --arg me "$ME" '{version: 1, me: $me, sources: .}' "$TMP/sources.jsonl" >"$TMP/config.json" \
  || die "Could not build the config."

install -m 600 /dev/null "$ENV_FILE"
printf 'NOTION_TOKEN=%s\n' "$TOKEN" >"$ENV_FILE"
install -m 644 "$TMP/config.json" "$CONFIG_FILE"

head2 "Done"
say "Token   $ENV_FILE (chmod 600)"
say "Boards  $CONFIG_FILE"
jq -r '.sources[] | "  \(.label)  \(if .onlyMine then "(only yours)" else "(everyone)" end)"' "$CONFIG_FILE"

say ""
if gum confirm "Fetch tasks now?"; then
  bash "$HERE/fetch.sh" || die "Fetch failed — see the message above."
  say ""
  say "Add the widget in Setup -> Plugins, or put io.github.taraskim.notion-tasks in the"
  say "bar layout in ~/.config/omarchy/shell.json, then: omarchy restart shell"
fi
