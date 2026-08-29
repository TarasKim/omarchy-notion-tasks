#!/usr/bin/env bash
# Shared secret handling. Sourced by the other scripts, never run on its own.
#
# Both functions here exist because getting either one wrong leaks an
# integration token that can read, create and edit anything in the workspace —
# and four scripts talking to Notion would otherwise each get their own chance
# to get it wrong.

NOTION_ENV_FILE="${NOTION_ENV_FILE:-$HOME/.config/omarchy/notion-tasks.env}"

# Read NOTION_TOKEN out of the env file *without* sourcing it. `source` runs
# the file as shell, so a stray backtick or $(...) — from a bad paste, or from
# hand-editing a file the README documents the path of — would execute as you
# instead of failing to parse. The file is a secret, not a script.
notion_read_token() {
  local line
  [[ -f $NOTION_ENV_FILE ]] || return 1
  while IFS= read -r line || [[ -n $line ]]; do
    line="${line%$'\r'}"
    [[ $line == NOTION_TOKEN=* ]] || continue
    line="${line#NOTION_TOKEN=}"
    # Tolerate the quoted forms a hand-edit tends to leave behind.
    if (( ${#line} >= 2 )) && [[ ( $line == \"*\" ) || ( $line == \'*\' ) ]]; then
      line="${line:1:${#line}-2}"
    fi
    [[ -n $line ]] || return 1
    printf '%s' "$line"
    return 0
  done <"$NOTION_ENV_FILE"
  return 1
}

# Write the Authorization header to a file, and echo its path, so curl can be
# given `-H @file` instead of the header itself.
#
# A header passed on the command line lands in /proc/PID/cmdline, which is
# world-readable on a stock kernel: any other local account can lift the token
# straight out of the process table while a refresh runs — every five minutes,
# by default. $1 must be a directory only you can read (mktemp -d gives 0700).
notion_auth_file() {
  local path="$1/auth.header"
  ( umask 077; printf 'Authorization: Bearer %s\n' "$2" >"$path" ) || return 1
  printf '%s' "$path"
}

# Notion ids are 32 hex digits, dashed or not. Everything that reaches a
# request path or a filename goes through here first: the ids come from a
# config file the README invites people to edit by hand.
notion_normalize_id() {
  local id="${1//-/}"
  [[ $id =~ ^[0-9a-fA-F]{32}$ ]] || return 1
  printf '%s' "$id"
}
