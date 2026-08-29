#!/usr/bin/env bash
# Change a task's Status in Notion and refresh the cache.
#
#   set-status.sh --id PAGE_ID --status NAME
#
# Both databases spell the property "Status" and type it `status`, so one code
# path covers them; the *names* differ ("Completed" vs "Done") and are chosen
# by the caller from the vocabulary fetch.sh cached for that source.
#
# Prints the applied status on success; anything on stderr is shown by the
# widget, so messages here are user-facing.

set -uo pipefail

NOTION_VERSION="2022-06-28"
ENV_FILE="$HOME/.config/omarchy/notion-tasks.env"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/notion-lib.sh"

die() { echo "$1" >&2; exit 1; }

page="" status=""
while (($#)); do
  case "$1" in
    --id)     page="${2:-}"; shift 2 ;;
    --status) status="${2:-}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n $page ]]   || die "no task id"
[[ -n $status ]] || die "no status given"

command -v jq >/dev/null 2>&1 || die "jq is not installed"
command -v curl >/dev/null 2>&1 || die "curl is not installed"
[[ -f $LIB ]] || die "missing notion-lib.sh next to set-status.sh"
[[ -f $ENV_FILE ]] || die "missing $ENV_FILE"

# shellcheck source=notion-lib.sh
NOTION_ENV_FILE="$ENV_FILE"; source "$LIB"
NOTION_TOKEN=$(notion_read_token) || die "NOTION_TOKEN not set"

TMP=$(mktemp -d) || die "could not create a temp directory"
trap 'rm -rf "$TMP"' EXIT
# The token travels to curl in a file, never as an argument. See notion-lib.sh.
AUTH=$(notion_auth_file "$TMP" "$NOTION_TOKEN") || die "could not stage the auth header"

# The widget passes the 32-hex id from the cache; accept the dashed form too.
# Keep the original for the message: the assignment clobbers $page on failure.
raw_page="$page"
page=$(notion_normalize_id "$raw_page") || die "not a Notion page id: $raw_page"

payload=$(jq -n --arg s "$status" '{properties: {"Status": {status: {name: $s}}}}')

resp=$(curl -sS --max-time 20 -X PATCH "https://api.notion.com/v1/pages/$page" \
  -H @"$AUTH" \
  -H "Notion-Version: $NOTION_VERSION" \
  -H "Content-Type: application/json" \
  -d "$payload") || die "could not reach Notion"

if [[ $(jq -r '.object // ""' <<<"$resp") == "error" ]]; then
  msg=$(jq -r '.message // "unknown error"' <<<"$resp")
  # The commonest cause by far, and the API's own wording does not say it.
  if [[ $(jq -r '.code // ""' <<<"$resp") == "restricted_resource" ]]; then
    msg="$msg (does the integration have Update content capability?)"
  fi
  die "Notion rejected the change: $msg"
fi

# Refresh so the row updates — or leaves the list, if it is now complete —
# without waiting for the poll interval.
bash "$HERE/fetch.sh" >/dev/null 2>&1 || true

echo "$status"
