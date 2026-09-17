# Every ceiling the cache is held to, in one place.
#
# fetch.sh already bounds what it reads off the network in bytes. This is the
# other half: what survives *parsing* — how many boards, tasks, statuses and
# relation rows, and how long any one string may be — because a response that
# is small enough to accept can still describe a model nothing downstream was
# built to hold. The widget is a long-lived process that sorts and repeats
# over all of it on every frame, so the model it is handed is capped here,
# where a limit can still be reported, rather than there, where it cannot.
#
# Strings are cut to length and stripped of control characters on the way
# through, so nothing below this line has to think about what a task name
# might contain. Anything that goes over a limit is named in .error rather
# than dropped silently: an unexplained short list is a bug report.

def MAX_SOURCES:        24;
def MAX_TASKS:        2000;
def MAX_STATUSES:       60;
def MAX_PRIORITIES:     40;
def MAX_SELECTS:        40;
def MAX_OPTIONS:       200;
def MAX_RELATIONS:       8;
def MAX_RELATION_ROWS: 500;

def LEN_NAME:  300;
def LEN_SHORT: 120;
def LEN_URL:   512;

# A string, cut to $n, with control characters folded to spaces. Anything that
# is not a string becomes "": the widget renders these, and "[object Object]"
# is not a task name.
def txt($n):
  if type == "string" then (gsub("[[:cntrl:]]"; " ") | .[0:$n]) else "" end;

def num($default):
  if type == "number" and (isnan | not) and (isinfinite | not) then . else $default end;

def flag: . == true;

# 32 hex digits, dashed or not, or nothing.
def pageid:
  if type == "string" and (gsub("-"; "") | test("^[0-9a-fA-F]{32}$"))
  then (gsub("-"; "") | ascii_downcase) else "" end;

# Only an https Notion page URL survives. This is the same test open-task.sh
# applies before it will open anything and Model.js applies before it will
# hand one to a process: a URL that has passed all three has been checked on
# every path that can reach a command line.
def pageurl:
  if type == "string"
     and (length <= LEN_URL)
     and test("^https://(www\\.)?notion\\.so/[A-Za-z0-9._~%/?=&#+-]*$")
     and test("[0-9a-fA-F]{32}")
  then . else "" end;

def cap($n): if type == "array" then .[0:$n] else [] end;
def over($n): (type == "array" and (length > $n));

def clean_task:
  {
    id:          (.id          | pageid),
    name:        (.name        | txt(LEN_NAME)),
    status:      (.status      | txt(LEN_SHORT)),
    statusGroup: (.statusGroup | txt(LEN_SHORT)),
    priority:    (.priority    | txt(LEN_SHORT)),
    rank:        (.rank        | num(0)),
    due:         (if (.due | type) == "string" then (.due | txt(64)) else null end),
    url:         (.url         | pageurl),
    source:      (.source      | txt(64)),
    mine:        (.mine        | flag)
  }
  | select(.name != "");

def clean_option: txt(LEN_SHORT);

def clean_status:
  { name: (.name | txt(LEN_SHORT)), group: (.group | txt(LEN_SHORT)) }
  | select(.name != "");

def clean_relation_rows:
  [ (cap(MAX_RELATION_ROWS))[]
    | { id: (.id | pageid), name: (.name | txt(LEN_SHORT)) }
    | select(.id != "" and .name != "") ];

def clean_source:
  {
    key:      (.key   | txt(64)),
    label:    (.label | txt(LEN_SHORT)),
    badge:    (.badge | txt(8)),
    database: (.database | pageid),
    url:      (.url   | pageurl),
    onlyMine: (.onlyMine | flag),
    complete: (.complete | txt(LEN_SHORT)),
    props: {
      title:    ((.props.title    // "") | txt(LEN_SHORT)),
      status:   ((.props.status   // "") | txt(LEN_SHORT)),
      date:     ((.props.date     // "") | txt(LEN_SHORT)),
      priority: ((.props.priority // "") | txt(LEN_SHORT)),
      owner:    ((.props.owner    // "") | txt(LEN_SHORT)),
      selects:  [ ((.props.selects // []) | cap(MAX_SELECTS))[] | clean_option | select(. != "") ]
    },
    statuses:   [ ((.statuses   // []) | cap(MAX_STATUSES))[]   | clean_status ],
    priorities: [ ((.priorities // []) | cap(MAX_PRIORITIES))[] | clean_option | select(. != "") ],
    selectOptions:
      ( [ ((.selectOptions // {}) | to_entries | cap(MAX_SELECTS))[]
          | { key:   (.key | txt(LEN_SHORT)),
              value: [ ((.value // []) | cap(MAX_OPTIONS))[] | clean_option | select(. != "") ] }
          | select(.key != "") ] | from_entries ),
    relations:
      ( [ ((.relations // {}) | to_entries | cap(MAX_RELATIONS))[]
          | { key:   (.key | txt(LEN_SHORT)),
              value: ((.value // []) | clean_relation_rows) }
          | select(.key != "") ] | from_entries )
  }
  | select(.key != "" and .database != "");

# What had to be cut, named, so the panel can say so instead of quietly
# showing a short list.
def overflow:
  [ (if (.sources | over(MAX_SOURCES)) then "boards" else empty end),
    (if (.tasks   | over(MAX_TASKS))   then "tasks"  else empty end),
    (if [ (.sources // [])[] | select((.statuses // []) | over(MAX_STATUSES)) ] | length > 0
     then "statuses" else empty end),
    (if [ (.sources // [])[] | select(((.relations // {}) | to_entries) | over(MAX_RELATIONS)) ] | length > 0
     then "relation properties" else empty end),
    (if [ (.sources // [])[] | (.relations // {}) | to_entries[] | select((.value // []) | over(MAX_RELATION_ROWS)) ] | length > 0
     then "relation rows" else empty end) ];

def bounded:
  (overflow) as $cut
  | {
      updated: ((.updated // "") | txt(64)),
      me:      ((.me // "") | pageid),
      sources: [ ((.sources // []) | cap(MAX_SOURCES))[] | clean_source ],
      tasks:   [ ((.tasks   // []) | cap(MAX_TASKS))[]   | clean_task ],
      error:   ( ((.error // "") | txt(LEN_NAME)) as $e
                 | if ($cut | length) == 0 then $e
                   elif $e == "" then "Too much to show: capped " + ($cut | join(", ")) + "."
                   else $e end )
    }
  # A task whose board did not survive the caps is not renderable.
  | . as $c
  | .tasks = [ $c.tasks[] | select(.source as $k | $c.sources | any(.key == $k)) ];
