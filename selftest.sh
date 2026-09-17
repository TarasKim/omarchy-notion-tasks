#!/usr/bin/env bash
# Offline checks for the handling rules the rest of this plugin is built on.
#
#   bash selftest.sh
#
# No token, no network, and nothing outside its own temp directory: every
# script under test is pointed at a sandbox through the NOTION_* variables the
# library reads. Run it after changing anything in notion-lib.sh, bounds.jq or
# the scripts that use them.
#
# What it asserts is the list of things that are easy to get wrong once and
# never notice: that a read follows a descriptor rather than a name, that a
# planted symlink or FIFO is refused rather than followed or waited on, that
# every ceiling actually holds, that a publish is atomic and cannot be
# redirected, that two refreshes cannot interleave, and that a hostile cache
# comes out the other side as an ordinary bounded document.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
is()   { [[ "$2" == "$3" ]] && ok "$1" || bad "$1 (want [$2] got [$3])"; }
rc_is(){ local want="$1" desc="$2"; shift 2; "$@" >/dev/null 2>&1; is "$desc" "$want" "$?"; }
head2(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

SANDBOX=$(mktemp -d) || exit 1
trap 'rm -rf -- "$SANDBOX"' EXIT

export NOTION_CONFIG_DIR="$SANDBOX/config"
export NOTION_STATE_DIR="$SANDBOX/state"
export NOTION_ENV_FILE="$NOTION_CONFIG_DIR/notion-tasks.env"
export NOTION_CONFIG_FILE="$NOTION_CONFIG_DIR/notion-tasks.json"
mkdir -m 700 "$NOTION_CONFIG_DIR" "$NOTION_STATE_DIR"

# shellcheck source=notion-lib.sh
source "$HERE/notion-lib.sh"

head2 "Reading: one open, then the descriptor"

printf 'hello\n' >"$SANDBOX/plain"; chmod 600 "$SANDBOX/plain"
is "reads a regular file it owns" "hello" "$(notion_read_file "$SANDBOX/plain" 100)"

ln -s plain "$SANDBOX/via-symlink"
rc_is 13 "refuses a symlinked leaf" notion_read_file "$SANDBOX/via-symlink" 100

mkfifo "$SANDBOX/fifo"
start=$SECONDS
notion_read_file "$SANDBOX/fifo" 100 >/dev/null 2>&1
rc=$?
took=$((SECONDS - start))
[[ $rc -ne 0 ]] && ok "refuses a FIFO" || bad "refuses a FIFO"
[[ $took -le $((NOTION_OPEN_TIMEOUT + 2)) ]] \
  && ok "and does not block on it (${took}s)" || bad "blocked on a FIFO for ${took}s"

rc_is 15 "refuses a directory" notion_read_file "$SANDBOX" 100
rc_is 12 "refuses a missing file" notion_read_file "$SANDBOX/nothing" 100

chmod 666 "$SANDBOX/plain"
rc_is 17 "refuses a file anyone can write" notion_read_file "$SANDBOX/plain" 100
chmod 644 "$SANDBOX/plain"
rc_is 18 "refuses a token file anyone can read" notion_read_file "$SANDBOX/plain" 100 private
chmod 600 "$SANDBOX/plain"

printf '%0.sx' {1..500} >"$SANDBOX/big"; chmod 600 "$SANDBOX/big"
rc_is 19 "refuses a file over its ceiling" notion_read_file "$SANDBOX/big" 100
is "and reads one under it" 500 "$(notion_read_file "$SANDBOX/big" 4096 | wc -c)"

mkdir "$SANDBOX/real-dir"; ln -s real-dir "$SANDBOX/dir-link"
printf 'ok\n' >"$SANDBOX/real-dir/f"; chmod 600 "$SANDBOX/real-dir/f"
is "a symlinked ancestor is still fine" "ok" "$(notion_read_file "$SANDBOX/dir-link/f" 100)"

head2 "The token"

printf 'NOTION_TOKEN=ntn_TestTokenValue123\n' >"$NOTION_ENV_FILE"; chmod 600 "$NOTION_ENV_FILE"
is "reads a token" "ntn_TestTokenValue123" "$(notion_read_token)"
printf 'NOTION_TOKEN="ntn_TestTokenValue123"\n' >"$NOTION_ENV_FILE"; chmod 600 "$NOTION_ENV_FILE"
is "tolerates the quoted form" "ntn_TestTokenValue123" "$(notion_read_token)"
printf 'NOTION_TOKEN=$(touch %s/pwned)\n' "$SANDBOX" >"$NOTION_ENV_FILE"; chmod 600 "$NOTION_ENV_FILE"
rc_is 1 "refuses a shell-shaped token" notion_read_token
[[ -e $SANDBOX/pwned ]] && bad "the env file executed" || ok "and never executes the env file"
printf 'NOTION_TOKEN=ntn_TestTokenValue123\n' >"$NOTION_ENV_FILE"; chmod 600 "$NOTION_ENV_FILE"

head2 "Writing: held directory, unpredictable inode, atomic rename"

notion_open_dir "$NOTION_STATE_DIR" FD 700
is "opens a directory it owns" 0 "$?"
printf '{"a":1}' | notion_publish "$FD" "cache.json" 600 100
is "publishes" 0 "$?"
is "with the content" '{"a":1}' "$(cat "$NOTION_STATE_DIR/cache.json")"
is "and the mode" "600" "$(stat -c '%a' "$NOTION_STATE_DIR/cache.json")"
is "leaving no scratch behind" 0 "$(find "$NOTION_STATE_DIR" -name '.cache.json.*' | wc -l)"

printf '%0.sy' {1..500} | notion_publish "$FD" "cache.json" 600 100 2>/dev/null
is "refuses content over the ceiling" 1 "$?"
is "and keeps what was there" '{"a":1}' "$(cat "$NOTION_STATE_DIR/cache.json")"

ln -s "$SANDBOX/elsewhere" "$NOTION_STATE_DIR/planted"
printf 'x' | notion_publish "$FD" "planted" 600 100 2>/dev/null
is "refuses to publish onto a symlink" 9 "$?"
[[ -e $SANDBOX/elsewhere ]] && bad "wrote through the symlink" || ok "and writes nothing through it"
rm -f "$NOTION_STATE_DIR/planted"

chmod 777 "$NOTION_STATE_DIR"
notion_open_dir "$NOTION_STATE_DIR" FD2 2>/dev/null
is "refuses a directory anyone can write" 8 "$?"
chmod 700 "$NOTION_STATE_DIR"

head2 "The publication lock"

cat >"$SANDBOX/locker.sh" <<'LOCKER'
source "$1/notion-lib.sh"
notion_open_dir "$NOTION_STATE_DIR" FD || exit 2
flock -w "$2" "$FD" || exit 3
sleep "$3"
LOCKER
NOTION_STATE_DIR="$NOTION_STATE_DIR" bash "$SANDBOX/locker.sh" "$HERE" 5 3 &
holder=$!
sleep 1
NOTION_STATE_DIR="$NOTION_STATE_DIR" timeout 1 bash "$SANDBOX/locker.sh" "$HERE" 0 0
is "a second publisher waits for the first" 3 "$?"
wait "$holder" 2>/dev/null
NOTION_STATE_DIR="$NOTION_STATE_DIR" bash "$SANDBOX/locker.sh" "$HERE" 1 0
is "and takes it once released" 0 "$?"

head2 "Ceilings on what is parsed (bounds.jq)"

jq -n '{sources: [range(40) | {key: ("k" + tostring), label: "L",
                               database: "11111111222233334444555555555555",
                               statuses: [range(80) | {name: ("s" + tostring), group: "To-do"}],
                               relations: {R: [range(900) | {id: "aaaaaaaabbbbccccddddeeeeeeeeeeee", name: ("r" + tostring)}]}}],
        tasks: [range(2500) | {name: "t", source: "k0"}]}' >"$SANDBOX/big.json"
jq -f <(cat "$HERE/bounds.jq"; echo bounded) "$SANDBOX/big.json" >"$SANDBOX/capped.json"
is "boards capped"        24   "$(jq '.sources | length' "$SANDBOX/capped.json")"
is "tasks capped"         2000 "$(jq '.tasks | length' "$SANDBOX/capped.json")"
is "statuses capped"      60   "$(jq '.sources[0].statuses | length' "$SANDBOX/capped.json")"
is "relation rows capped" 500  "$(jq '.sources[0].relations.R | length' "$SANDBOX/capped.json")"
is "and says what it cut" "true" \
   "$(jq '.error | test("capped")' "$SANDBOX/capped.json")"

jq -n '{sources: [{key: "k", label: "AB", database: "11111111222233334444555555555555"}],
        tasks: [{name: ("x" * 5000), source: "k", url: "https://evil.example/aaaaaaaabbbbccccddddeeeeeeeeeeee"},
                {name: "kept", source: "k", url: "https://www.notion.so/T-aaaaaaaabbbbccccddddeeeeeeeeeeee", rank: "NaN", mine: "yes"},
                {name: "orphan", source: "gone"},
                {name: {an: "object"}, source: "k"}]}' >"$SANDBOX/hostile.json"
jq -f <(cat "$HERE/bounds.jq"; echo bounded) "$SANDBOX/hostile.json" >"$SANDBOX/clean.json"
is "long names cut"            300 "$(jq -r '.tasks[0].name | length' "$SANDBOX/clean.json")"
is "control characters folded" "A B" "$(jq -r '.sources[0].label' "$SANDBOX/clean.json")"
is "foreign urls dropped"      ""  "$(jq -r '.tasks[0].url' "$SANDBOX/clean.json")"
is "notion urls kept"          "true" "$(jq -r '.tasks[1].url | startswith("https://www.notion.so/")' "$SANDBOX/clean.json")"
is "ranks are numbers"         "number" "$(jq -r '.tasks[1].rank | type' "$SANDBOX/clean.json")"
is "\"yes\" is not true"       "false" "$(jq -r '.tasks[1].mine' "$SANDBOX/clean.json")"
is "orphans and rubbish gone"  2   "$(jq '.tasks | length' "$SANDBOX/clean.json")"

# The host Notion actually serves from has to survive the cache filter too:
# when it did not, every task URL in the cache was blanked and no row in the
# popup would open.
jq -n '{sources: [{key: "k", label: "L", database: "11111111222233334444555555555555"}],
        tasks: [{name: "live host", source: "k", url: "https://app.notion.com/p/Task-aaaaaaaabbbbccccddddeeeeeeeeeeee"},
                {name: "old host",  source: "k", url: "https://www.notion.so/Task-aaaaaaaabbbbccccddddeeeeeeeeeeee"},
                {name: "not notion", source: "k", url: "https://notion.so.example.com/aaaaaaaabbbbccccddddeeeeeeeeeeee"}]}' \
  | jq -f <(cat "$HERE/bounds.jq"; echo bounded) >"$SANDBOX/hosts.json"
is "app.notion.com url survives"  "https://app.notion.com/p/Task-aaaaaaaabbbbccccddddeeeeeeeeeeee" \
   "$(jq -r '.tasks[0].url' "$SANDBOX/hosts.json")"
is "notion.so url survives"       "https://www.notion.so/Task-aaaaaaaabbbbccccddddeeeeeeeeeeee" \
   "$(jq -r '.tasks[1].url' "$SANDBOX/hosts.json")"
is "look-alike host dropped"      "" "$(jq -r '.tasks[2].url' "$SANDBOX/hosts.json")"

head2 "read-cache.sh: the widget's only way in"

cp "$SANDBOX/hostile.json" "$NOTION_STATE_DIR/cache.json"; chmod 600 "$NOTION_STATE_DIR/cache.json"
out=$(bash "$HERE/read-cache.sh")
is "normalises a hostile cache" 2 "$(jq '.tasks | length' <<<"$out")"

rm -f "$NOTION_STATE_DIR/cache.json"
ln -s "$SANDBOX/plain" "$NOTION_STATE_DIR/cache.json"
bash "$HERE/read-cache.sh" >/dev/null 2>&1
is "refuses a symlinked cache" 1 "$?"
rm -f "$NOTION_STATE_DIR/cache.json"

mkfifo "$NOTION_STATE_DIR/cache.json"
start=$SECONDS
bash "$HERE/read-cache.sh" >/dev/null 2>&1
took=$((SECONDS - start))
[[ $took -le $((NOTION_OPEN_TIMEOUT + 3)) ]] \
  && ok "refuses a FIFO cache without hanging (${took}s)" \
  || bad "hung on a FIFO cache for ${took}s"
rm -f "$NOTION_STATE_DIR/cache.json"

head2 "Arguments the panel can send"

printf '{"me":"","sources":[{"key":"p","label":"P","database":"11111111222233334444555555555555","props":{"title":"Name"},"statuses":[]}],"tasks":[]}' \
  >"$NOTION_STATE_DIR/cache.json"
chmod 600 "$NOTION_STATE_DIR/cache.json"

long=$(printf '%0.sx' {1..1000})
rc_is 1 "refuses a 1000-character title" bash "$HERE/create-task.sh" --dest p --title "$long"
rc_is 1 "refuses a title with control characters" bash "$HERE/create-task.sh" --dest p --title "$(printf 'a\tb')"
rc_is 1 "refuses a destination that is not a key" bash "$HERE/create-task.sh" --dest 'a;b' --title x
rc_is 1 "refuses a relation that is not a page id" bash "$HERE/create-task.sh" --dest p --title x --relation 'R=../etc'
rc_is 1 "refuses an id that is not a page id" bash "$HERE/set-status.sh" --id nope --status Done
rc_is 1 "refuses an over-long status name" bash "$HERE/set-status.sh" --id aaaaaaaabbbbccccddddeeeeeeeeeeee --status "$long"

head2 "URLs open-task.sh will and will not open"

mkdir -p "$SANDBOX/bin"
cat >"$SANDBOX/bin/omarchy-launch-webapp" <<'STUB'
#!/usr/bin/env bash
printf 'LAUNCHED %s\n' "$1"
STUB
# A stub compositor, so a test run can never focus or close a real window.
cat >"$SANDBOX/bin/hyprctl" <<'STUB'
#!/usr/bin/env bash
[[ $1 == clients ]] && printf '[]\n'
exit 0
STUB
chmod +x "$SANDBOX/bin/omarchy-launch-webapp" "$SANDBOX/bin/hyprctl"

opens() {
  local url="$1" want="$2" out
  out=$(PATH="$SANDBOX/bin:$PATH" bash "$HERE/open-task.sh" "$url" 2>/dev/null)
  local got=no; [[ $out == LAUNCHED* ]] && got=yes
  is "$([[ $want == yes ]] && echo opens || echo refuses): ${url:0:52}" "$want" "$got"
}
ID=aaaaaaaabbbbccccddddeeeeeeeeeeee
# app.notion.com is the host Notion actually serves pages from; notion.so is
# the historical one that older caches still hold. Both must open, or every
# row in the popup becomes unclickable -- which is exactly what happened once.
opens "https://app.notion.com/p/Task-$ID"           yes
opens "https://www.notion.so/Task-$ID"              yes
opens "https://notion.so/$ID"                       yes
opens "https://notion.com/$ID"                      yes
opens "http://www.notion.so/$ID"                   no
opens "https://notion.so.example.com/$ID"          no
opens "https://www.notion.so/x\$(touch $SANDBOX/pwned2)$ID" no
opens "https://www.notion.so/no-id-at-all"         no
opens "javascript:alert(1)"                        no
opens "https://www.notion.so/$(printf '%0.sa' {1..600})" no
[[ -e $SANDBOX/pwned2 ]] && bad "a url ran a command" || ok "and no url ever ran a command"

head2 "Model.js, if a JS runtime is around"

if command -v node >/dev/null 2>&1; then
  node -e '
    const fs = require("fs")
    const src = fs.readFileSync(process.argv[1], "utf8").replace(/^\.pragma library\s*$/m, "")
    const M = {}
    new Function("x", src + ";Object.assign(x,{parseCache,safeUrl})")(M)
    const t = (name, cond) => console.log((cond ? "  \x1b[32mok\x1b[0m   " : "  \x1b[31mFAIL\x1b[0m ") + name)
    const big = JSON.stringify({sources: Array.from({length: 40}, (_, i) => ({key: "k" + i, label: "L", database: "1".repeat(32)})),
                                tasks: Array.from({length: 3000}, () => ({name: "t", source: "k0"}))})
    const p = M.parseCache(big)
    t("boards capped in the widget too", p.sources.length === 24)
    t("tasks capped in the widget too", p.tasks.length === 2000)
    t("a cache over 4 MiB is refused unparsed", M.parseCache("x".repeat(5 << 20)).error === "cache too large")
    t("rubbish is not a cache", M.parseCache("<html>").error === "cache unreadable")
    t("foreign urls never leave the model", M.safeUrl("https://evil.example/" + "a".repeat(32)) === "")
  ' "$HERE/Model.js"
  PASS=$((PASS + 5))
else
  printf '  skipped (no node)\n'
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
