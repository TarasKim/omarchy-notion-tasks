#!/usr/bin/env bash
# Shared file, secret and transport handling. Sourced by the other scripts,
# never run on its own.
#
# Everything here exists because the four scripts that talk to Notion would
# otherwise each get their own chance to mishandle the same three things: an
# integration token that can read, create and edit anything in the workspace;
# files under ~/.config and ~/.local/state that another local account may be
# able to replace; and API responses of a size nobody here chose.
#
# The rule this file enforces, and which the scripts are written around:
#
#   nothing is read, written or parsed by pathname. A path is resolved once,
#   into a descriptor, and every check and every byte afterwards goes through
#   that descriptor — with a ceiling on how many bytes there can be.

# ---- ceilings -------------------------------------------------------------
# All of these are deliberately far above any real board and far below "as
# much as the other end feels like sending". Overridable for testing only.

NOTION_MAX_TOKEN_BYTES="${NOTION_MAX_TOKEN_BYTES:-4096}"
NOTION_MAX_CONFIG_BYTES="${NOTION_MAX_CONFIG_BYTES:-262144}"     # 256 KiB
NOTION_MAX_CACHE_BYTES="${NOTION_MAX_CACHE_BYTES:-4194304}"      # 4 MiB
NOTION_MAX_RESPONSE_BYTES="${NOTION_MAX_RESPONSE_BYTES:-8388608}" # 8 MiB per call
NOTION_HTTP_TIMEOUT="${NOTION_HTTP_TIMEOUT:-20}"
# A blocking open (a FIFO planted where a config file belongs) must not hang
# the widget's refresh; it is bounded rather than trusted.
NOTION_OPEN_TIMEOUT="${NOTION_OPEN_TIMEOUT:-5}"

# ---- where things live ----------------------------------------------------
# One definition each, so the four scripts and the widget cannot drift apart
# about which file they mean.

NOTION_CONFIG_DIR="${NOTION_CONFIG_DIR:-$HOME/.config/omarchy}"
NOTION_ENV_FILE="${NOTION_ENV_FILE:-$NOTION_CONFIG_DIR/notion-tasks.env}"
NOTION_CONFIG_FILE="${NOTION_CONFIG_FILE:-$NOTION_CONFIG_DIR/notion-tasks.json}"
# The cache lives in a directory of our own, mode 700, rather than loose in
# omarchy's shared state directory: it is a full copy of your task list, and
# a private parent is what lets every write below be a descriptor-relative
# rename into a place nothing else has a hand in.
NOTION_STATE_DIR="${NOTION_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/notion-tasks}"
NOTION_CACHE_NAME="cache.json"
NOTION_CACHE="$NOTION_STATE_DIR/$NOTION_CACHE_NAME"

# ---- reading --------------------------------------------------------------

# notion_read_file PATH [MAX_BYTES] [private]
#
# Print the contents of PATH, or fail. One open; every check runs against that
# open descriptor, and the bytes come from it too:
#
#   * the open is bounded by a deadline, so a FIFO cannot stall the caller
#   * the descriptor's own path (/proc/PID/fd) must equal the path asked for,
#     which is what makes a symlinked or raced leaf a refusal rather than a
#     silent redirect
#   * fstat on the descriptor must say: regular file, owned by us, not
#     writable by group or other, no larger than the ceiling
#   * "private" additionally refuses any group or other access at all, for
#     the file holding the token
#
# It is a separate short-lived process because holding the descriptor there
# means a failed check cannot leave a descriptor open in a long script, and
# because the deadline has something to kill.
notion_read_file() {
  local path="$1" cap="${2:-$NOTION_MAX_CONFIG_BYTES}" mode="${3:-shared}"
  [[ $path == /* ]] || return 2
  timeout -s KILL "$NOTION_OPEN_TIMEOUT" bash -c '
    set -u
    path=$1 cap=$2 mode=$3
    dir=$(realpath -e -- "${path%/*}" 2>/dev/null) || exit 11
    expected="$dir/${path##*/}"

    exec {fd}<"$path" 2>/dev/null || exit 12
    [[ $(readlink "/proc/$$/fd/$fd" 2>/dev/null) == "$expected" ]] || exit 13

    meta=$(stat -L -c "%F|%u|%a|%s" "/proc/$$/fd/$fd" 2>/dev/null) || exit 14
    IFS="|" read -r kind uid perm size <<<"$meta"
    [[ $kind == "regular file" || $kind == "regular empty file" ]] || exit 15
    [[ $uid == "$EUID" ]] || exit 16
    (( (8#$perm & 0022) == 0 )) || exit 17
    [[ $mode != private ]] || (( (8#$perm & 0077) == 0 )) || exit 18
    (( size <= cap )) || exit 19

    IFS= read -r -N "$cap" data <&"$fd" || true
    printf "%s" "$data"
  ' notion-read "$path" "$cap" "$mode"
}

# Read NOTION_TOKEN out of the env file *without* sourcing it. `source` runs
# the file as shell, so a stray backtick or $(...) — from a bad paste, or from
# hand-editing a file the README documents the path of — would execute as you
# instead of failing to parse. The file is a secret, not a script.
notion_read_token() {
  local body line token=""
  body=$(notion_read_file "$NOTION_ENV_FILE" "$NOTION_MAX_TOKEN_BYTES" private) || return 1
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ $line == NOTION_TOKEN=* ]] || continue
    line="${line#NOTION_TOKEN=}"
    # Tolerate the quoted forms a hand-edit tends to leave behind.
    if (( ${#line} >= 2 )) && [[ ( $line == \"*\" ) || ( $line == \'*\' ) ]]; then
      line="${line:1:${#line}-2}"
    fi
    token="$line"
    break
  done <<<"$body"
  # A Notion secret is an opaque word. Anything else — a newline, a shell
  # metacharacter, a paragraph — is a broken file, not a token, and must not
  # reach a header file or an error message.
  [[ $token =~ ^[A-Za-z0-9_-]{16,256}$ ]] || return 1
  printf '%s' "$token"
}

# ---- writing --------------------------------------------------------------

# notion_open_dir DIR VARNAME [create-mode]
#
# Open DIR and leave a verified descriptor for it in the named variable. The
# descriptor, not the path, is what callers write through afterwards: with it
# held, replacing the directory or any ancestor underneath us cannot redirect
# a later write, because there is no later path walk to redirect.
notion_open_dir() {
  local dir="$1" var="$2" create="${3:-}" fd expected meta kind uid perm
  [[ $dir == /* ]] || return 2
  [[ -d $dir ]] || { [[ -n $create ]] && mkdir -m "$create" -p "$dir"; } || return 3

  expected=$(realpath -e -- "$dir" 2>/dev/null) || return 4
  # A redirection on a bare `exec` is permanent, so the quiet open has to put
  # stderr back afterwards rather than leave the rest of the script writing
  # its messages into /dev/null.
  local saved rc
  exec {saved}>&2 2>/dev/null
  exec {fd}<"$dir"
  rc=$?
  exec 2>&"$saved" {saved}>&-
  (( rc == 0 )) || return 5
  if [[ $(readlink "/proc/$$/fd/$fd" 2>/dev/null) != "$expected" ]]; then
    exec {fd}<&-; return 6
  fi
  meta=$(stat -L -c '%F|%u|%a' "/proc/$$/fd/$fd" 2>/dev/null) || { exec {fd}<&-; return 7; }
  IFS='|' read -r kind uid perm <<<"$meta"
  if [[ $kind != directory ]] || [[ $uid != "$EUID" ]] || (( (8#$perm & 0022) != 0 )); then
    exec {fd}<&-; return 8
  fi
  printf -v "$var" '%s' "$fd"
}

# The directory a held descriptor refers to, as a path children can use.
# /proc/PID/fd/N is the descriptor itself rather than a fresh resolution of
# the name it was opened under, so a scratch file created "inside" it lands in
# the directory we verified even if that name now points somewhere else.
notion_dir_at() { printf '/proc/%s/fd/%s' "$$" "$1"; }

# notion_publish DIRFD NAME MODE MAX_BYTES < content
#
# Publish content as DIRFD/NAME, atomically and with no window in which the
# name exists holding something half-written or world-readable:
#
#   unpredictable O_EXCL scratch inode created relative to the held directory
#   -> written with the final mode from the start -> fsync -> rename over the
#   name -> fsync the directory, so the rename survives a crash
#
# An existing leaf that is not a regular file is refused rather than followed:
# renaming over a symlink replaces the symlink, but a caller that finds one
# there is being pointed at by something and should stop.
notion_publish() {
  local dfd="$1" name="$2" mode="$3" cap="$4"
  local at tmp size rc=0
  at=$(notion_dir_at "$dfd")

  local leaf
  leaf=$(stat -c '%F' "$at/$name" 2>/dev/null) || leaf=""
  if [[ -n $leaf && $leaf != "regular file" && $leaf != "regular empty file" ]]; then
    return 9
  fi

  tmp=$(mktemp "$at/.${name}.XXXXXXXXXX") || return 1
  chmod "$mode" "$tmp" || { rm -f "$tmp"; return 1; }

  # head, not cat: the ceiling is enforced on the way in, and one byte over it
  # is a failure rather than a truncation nobody notices.
  head -c "$((cap + 1))" >"$tmp" || rc=1
  size=$(stat -c '%s' "$tmp" 2>/dev/null) || rc=1
  (( rc == 0 && size <= cap )) || { rm -f "$tmp"; return 1; }

  sync -d "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$at/$name" || { rm -f "$tmp"; return 1; }
  sync "$at" 2>/dev/null || true
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

# ---- transport ------------------------------------------------------------

# notion_curl OUTFILE CURL-ARGS...
#
# Every call to Notion goes through here, so every response has a ceiling and
# a deadline. --max-time bounds how long the other end may take; it says
# nothing about how much it may send, which is what --max-filesize and the
# size check after it are for. OUTFILE is inside the run's own 0700 temp
# directory, so it needs no descriptor dance of its own.
notion_curl() {
  local out="$1"; shift
  # Soft-fail keeps the body when the other end answers with an error: for a
  # create or a status change, Notion's own message is the useful part.
  local fail="-f"; [[ -z ${NOTION_CURL_FAIL_SOFT:-} ]] || fail=""
  # shellcheck disable=SC2086  # one optional flag, deliberately unquoted
  curl $fail -sS \
    --max-time "$NOTION_HTTP_TIMEOUT" \
    --max-filesize "$NOTION_MAX_RESPONSE_BYTES" \
    --proto '=https' --tlsv1.2 \
    -o "$out" "$@" || return 1
  local size
  size=$(stat -c '%s' "$out" 2>/dev/null) || return 1
  (( size <= NOTION_MAX_RESPONSE_BYTES )) || return 1
}

# ---- identifiers ----------------------------------------------------------

# Notion ids are 32 hex digits, dashed or not. Everything that reaches a
# request path or a filename goes through here first: the ids come from a
# config file the README invites people to edit by hand.
notion_normalize_id() {
  local id="${1//-/}"
  [[ $id =~ ^[0-9a-fA-F]{32}$ ]] || return 1
  printf '%s' "$id"
}

# ---- run bounds -----------------------------------------------------------

# notion_bound_run DEADLINE_SECONDS "$0" "$@"
#
# Re-exec the calling script inside its own session, under an overall
# deadline, with stderr capped. Three things follow, all of which the widget
# depends on:
#
#   * a refresh that wedges — a hung TLS handshake, a board with a dozen
#     relations — is killed rather than held open forever
#   * the kill reaches curl and jq too, because the session makes them one
#     process group rather than loose children of the shell
#   * a failure loop cannot pump megabytes of stderr into the collector
#     living inside the long-lived shell
#
# Callers pair this with notion_trap_group, which turns the deadline's TERM,
# and the panel going away, into a signal for that whole group.
notion_bound_run() {
  local deadline="$1"; shift
  [[ -z ${NOTION_BOUNDED:-} ]] || return 0
  # Both ends of the chain are watched below: $$ is the process the caller
  # holds a handle on (exec keeps the pid, so this is what the panel sees as
  # the process it started), and $PPID is the caller itself.
  export NOTION_BOUNDED=1 NOTION_OWNER_PIDS="$$ $PPID"
  # head alone would leave later writes on a closed pipe; the drain keeps the
  # cap from turning into a SIGPIPE for whatever is still writing.
  exec 2> >({ head -c 4096 >&2; cat >/dev/null; })
  exec setsid --wait timeout --signal=TERM --kill-after=5 "$deadline" bash "$@"
}

# Clean up, take the rest of the session with us, and stop if whoever asked
# for the work has gone. `kill 0` is the whole process group — which, because
# notion_bound_run made one, is exactly this run and nothing else.
#
# The owner watch is what covers the panel quitting mid-refresh: without it an
# orphaned run keeps a token in memory and a socket open until its deadline.
notion_trap_group() {
  local scratch="$1" watch="" pids="${NOTION_OWNER_PIDS:-}"
  if [[ -n $pids ]]; then
    # Detached from our stdio on purpose: a watcher still holding the stdout
    # pipe would keep the caller waiting for output that had already ended.
    { while :; do
          sleep 2
          for owner in $pids; do kill -0 "$owner" 2>/dev/null || break 2; done
        done
        kill -TERM 0 2>/dev/null; } >/dev/null 2>&1 </dev/null &
    watch=$!
  fi
  # shellcheck disable=SC2064  # the values are wanted now, not at trap time
  trap "[[ -z '$watch' ]] || kill '$watch' 2>/dev/null; rm -rf -- '$scratch'" EXIT
  trap "rm -rf -- '$scratch'; trap - TERM; kill -TERM 0 2>/dev/null; exit 143" TERM INT HUP
}

# Run a nested helper with a budget of its own rather than inside ours.
notion_run_helper() { env -u NOTION_BOUNDED -u NOTION_OWNER_PIDS bash "$@"; }
