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
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/notion-lib.sh"

[[ -f $LIB ]] || { echo "missing notion-lib.sh next to set-status.sh" >&2; exit 1; }
# shellcheck source=notion-lib.sh
source "$LIB"
notion_bound_run "${NOTION_STATUS_DEADLINE:-120}" "$HERE/set-status.sh" "$@"

die() { echo "$1" >&2; exit 1; }

page="" status=""
while (($#)); do
  case "$1" in
    --id)     page="${2:-}"; shift 2 ;;
    --status) status="${2:-}"; shift 2 ;;
    *) die "unknown argument" ;;
  esac
done

[[ -n $page ]]   || die "no task id"
[[ -n $status ]] || die "no status given"

# Both arrive over an argv from a long-lived process, so both are bounded
# before anything is built out of them. The id has an exact shape; a status
# name is a board's own word, so it is held to a length and to being text.
page=$(notion_normalize_id "$page") || die "that is not a Notion page id"
(( ${#status} <= 120 )) || die "that status name is too long"
[[ $status != *[$'\x01'-$'\x1f\x7f']* ]] || die "that status name contains control characters"

command -v jq >/dev/null 2>&1 || die "jq is not installed"
command -v curl >/dev/null 2>&1 || die "curl is not installed"

umask 077
TMP=$(mktemp -d) || die "could not create a temp directory"
notion_trap_group "$TMP"

NOTION_TOKEN=$(notion_read_token) || die "no usable NOTION_TOKEN — run setup.sh"
# The token travels to curl in a file, never as an argument. See notion-lib.sh.
AUTH=$(notion_auth_file "$TMP" "$NOTION_TOKEN") || die "could not stage the auth header"

PAYLOAD="$TMP/payload.json"
jq -n --arg s "$status" '{properties: {"Status": {status: {name: $s}}}}' >"$PAYLOAD" \
  || die "could not build the request"

RESP="$TMP/resp.json"
# -f is off here on purpose: Notion's own error body is the message worth
# showing, and curl would throw it away. The size ceiling still applies.
NOTION_CURL_FAIL_SOFT=1 notion_curl "$RESP" -X PATCH "https://api.notion.com/v1/pages/$page" \
  -H @"$AUTH" \
  -H "Notion-Version: $NOTION_VERSION" \
  -H "Content-Type: application/json" \
  --data-binary @"$PAYLOAD" || die "could not reach Notion"

if [[ $(jq -r '.object // ""' "$RESP") == "error" ]]; then
  msg=$(jq -r '(.message // "unknown error") | .[0:300]' "$RESP")
  # The commonest cause by far, and the API's own wording does not say it.
  if [[ $(jq -r '.code // ""' "$RESP") == "restricted_resource" ]]; then
    msg="$msg (does the integration have Update content capability?)"
  fi
  die "Notion rejected the change: $msg"
fi

# Refresh so the row updates — or leaves the list, if it is now complete —
# without waiting for the poll interval. It gets a budget of its own rather
# than the remains of this one.
notion_run_helper "$HERE/fetch.sh" >/dev/null 2>&1 || true

echo "$status"
