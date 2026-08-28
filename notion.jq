# Shared inference: turn a Notion database object into everything the widget
# needs to read and write that board, without anyone naming a property.
#
# The boards this plugin was written against disagree on nearly every name —
# "Due Date" vs "Deadline", "Priority Level" vs "Priority", "Assignee" vs
# "Owner" — and a stranger's board will disagree again. Types are the stable
# part, so selection is by type first and name only to break ties.

def props: (.properties // {}) | to_entries;
def of_type($t): [ props[] | select(.value.type == $t) | .key ];

# First name matching $re, else the first of its type, else null. A board with
# no date property at all is fine: tasks simply have no due date.
def prefer($cands; $re):
  ([ $cands[] | select(test($re; "i")) ][0] // $cands[0] // null);

# Priority is different: an unrelated select must not be press-ganged into it,
# so this one returns null rather than falling back.
def named_only($cands; $re): ([ $cands[] | select(test($re; "i")) ][0] // null);

def status_property: (.properties[of_type("status")[0] // ""] // {}) | .status // {};

def statuses:
  status_property as $s
  | ($s.groups // []) as $groups
  | [ ($s.options // [])[]
      | . as $o
      | { name: $o.name,
          group: ([ $groups[] | select((.option_ids // []) | index($o.id)) | .name ][0] // "") } ];

# Notion's status groups are unordered — one board here lists Complete as
# [Archived, Completed], so "first in the group" would archive things. Options
# order is the board's own, so pick from that and skip archive-shaped names.
def complete_status:
  [ statuses[] | select(.group == "Complete") ] as $done
  | ((([ $done[] | select(.name | test("archiv"; "i") | not) ] + $done)[0]) // {}).name // "";

def priority_key: named_only(of_type("select"); "priority");

# Rank is the option's position in the board's own list, which is what makes
# Eisenhower (Do/Decide/Delegate/Delete) and MoSCoW (Must/Should/Could/Won't)
# both sort correctly with nothing written down about either.
def priorities:
  priority_key as $k
  | if $k == null then []
    else [ (.properties[$k].select.options // [])[].name ]
    end;

def inferred:
  priority_key as $prio
  | {
      title: ((.title // []) | map(.plain_text) | join("")),
      url: (.url // ""),
      props: {
        title:    (of_type("title")[0] // null),
        status:   (of_type("status")[0] // null),
        date:     prefer(of_type("date"); "^(due|deadline|target)"),
        priority: $prio,
        owner:    prefer(of_type("people"); "^(owner|assignee|responsible)"),
        # Everything else a capture form could reasonably offer. Selects are
        # free — they are already in the schema. Relations cost a query each,
        # so they are only listed here; config decides which get loaded.
        selects:   [ of_type("select")[] | select(. != $prio) ],
        relations: of_type("relation")
      },
      # Which database each relation points at, so a capture form can offer
      # the rows on the other end of it (clients, projects, cycles) without
      # being told where they live.
      relationTargets: ([ props[]
                          | select(.value.type == "relation")
                          | { key: .key, value: (.value.relation.database_id // "") } ]
                        | from_entries),
      statuses: statuses,
      complete: complete_status,
      priorities: priorities,
      # Options for every select except the priority one. These ride along
      # free — they are already in the schema — so a capture form can offer
      # them without a request of its own.
      selectOptions: ([ props[]
                        | select(.value.type == "select" and .key != $prio)
                        | { key: .key,
                            value: [ (.value.select.options // [])[].name ] } ]
                      | from_entries)
    };
