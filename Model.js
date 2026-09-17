.pragma library

// Pure helpers for the Notion tasks widget. Kept Qt-free so it can stay a
// `.pragma library` singleton shared by the bar label and the popup rows.
//
// Nothing here knows the name of a database, a status, or a priority. All of
// that is inferred from each board's schema by fetch.sh and arrives in the
// cache under `sources`; this file only knows the *shapes*. That is what lets
// the same widget serve an Eisenhower personal list and a MoSCoW agency board
// without a line of per-board code.

var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
              "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

// ---- bounds -------------------------------------------------------------
// The same ceilings bounds.jq applies on the way out of fetch.sh, applied
// again on the way in. Not redundancy for its own sake: read-cache.sh is one
// way into this model and read-cache.sh could be replaced, while this is the
// long-lived process that sorts, groups and repeats over whatever it is
// given. Below the parse boundary every string is of known length with no
// control characters in it, every array is of known maximum size, and every
// number is a number.

var MAX_TEXT      = 300
var MAX_SHORT     = 120
var MAX_URL       = 512
var MAX_SOURCES   = 24
var MAX_TASKS     = 2000
var MAX_STATUSES  = 60
var MAX_PRIORITIES = 40
var MAX_SELECTS   = 40
var MAX_OPTIONS   = 200
var MAX_RELATIONS = 8
var MAX_RELATION_ROWS = 500
var MAX_CACHE_CHARS = 4 * 1024 * 1024

// Control characters, DEL and the C1 block, plus the Unicode line and
// paragraph separators. Built from a string rather than written as a regex
// literal so the escapes survive being copied around.
var CONTROL_CHARS = new RegExp("[\\x00-\\x1f\\x7f-\\x9f\\u2028\\u2029]", "g")

// Text, cut to length, with all of those folded to spaces. Every dynamic Text
// in the popup is textFormat: PlainText, so this is not about markup — it is
// about one field being able to draw itself as several lines of UI, or as a
// megabyte.
function plain(value, limit) {
  // Only text is text. A number is rendered as one; anything else — an object
  // a hostile or broken cache put where a name belongs — becomes nothing,
  // rather than the string "[object Object]" in the middle of a task list.
  var s
  if (typeof value === "string") s = value
  else if (typeof value === "number" && isFinite(value)) s = String(value)
  else return ""
  if (s.length > limit) s = s.slice(0, limit)
  return s.replace(CONTROL_CHARS, " ")
}

function numberOr(value, fallback) {
  return (typeof value === "number" && isFinite(value)) ? value : fallback
}

function boolOf(value) { return value === true }

// 32 hex digits, dashed or not, or nothing at all.
function idOf(value) {
  if (value === undefined || value === null) return ""
  var s = String(value).replace(/-/g, "")
  return /^[0-9a-fA-F]{32}$/.test(s) ? s.toLowerCase() : ""
}

// The one URL shape this widget will hand to a process: https, Notion's own
// host, and a page id in it. open-task.sh checks the same thing again at the
// other end, because neither of them can see how the other was reached.
function safeUrl(value) {
  if (value === undefined || value === null) return ""
  var s = String(value)
  if (s.length > MAX_URL) return ""
  if (!/^https:\/\/(www\.)?notion\.so\/[A-Za-z0-9._~%\/?=&#+-]*$/.test(s)) return ""
  if (!/[0-9a-fA-F]{32}/.test(s)) return ""
  return s
}

function capped(value, limit) {
  if (!Array.isArray(value)) return []
  return value.length > limit ? value.slice(0, limit) : value
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

// ---- sources ------------------------------------------------------------
// `sources` is the ordered array from the cache. Order is the user's, set in
// notion-tasks.json, and it drives three things at once: the sort, the order
// the groups render in, and which group a page's cursor offset belongs to.

function sourceKey(task) { return (task && task.source) || "" }

function sourceAt(sources, i) { return (sources || [])[i] || null }

function sourceFor(sources, task) {
  var key = sourceKey(task)
  var list = sources || []
  for (var i = 0; i < list.length; i++) if (list[i].key === key) return list[i]
  return null
}

// Position in the configured order; unknown sources sort to the end rather
// than to the front, so a stale cached task cannot jump the queue.
function sourceRank(sources, task) {
  var key = sourceKey(task)
  var list = sources || []
  for (var i = 0; i < list.length; i++) if (list[i].key === key) return i
  return list.length
}

function sourceTitle(sources, key) {
  var list = sources || []
  for (var i = 0; i < list.length; i++)
    if (list[i].key === key) return list[i].label || list[i].title || key
  return key
}

function groupTitle(sources, key) { return String(sourceTitle(sources, key)).toUpperCase() }

// Short badge for the flat (ungrouped) list. An all-caps word is already an
// abbreviation and survives whole, anything else contributes its initial —
// so "TK Digital" reads TKD and "Personal" reads P. A board can override it
// with `badge` in the config when that guess reads badly.
function badgeFor(label) {
  var words = String(label || "").split(/\s+/).filter(function (w) { return w !== "" })
  var out = ""
  for (var i = 0; i < words.length; i++) {
    var w = words[i]
    out += (w === w.toUpperCase() && w.length <= 4) ? w : w.charAt(0).toUpperCase()
  }
  return out.slice(0, 5)
}

function sourceLabel(sources, task) {
  var src = sourceFor(sources, task)
  if (!src) return ""
  if (src.badge !== undefined) return String(src.badge)
  return badgeFor(src.label || src.title || src.key)
}

// ---- priority -----------------------------------------------------------
// fetch.sh already resolved the rank against the board's own option order, so
// there is nothing to look up here — only a label to shorten for the chip.

function priorityTag(task) {
  var raw = task && task.priority ? String(task.priority) : ""
  if (raw === "") return ""
  // "Do (Urgent & Important)" -> "DO"; "Must" -> "MUST".
  return raw.split(" (")[0].trim().toUpperCase()
}

function priority(task) {
  var rank = (task && typeof task.rank === "number") ? task.rank : 2.5
  return { rank: rank, tag: priorityTag(task) }
}

// How urgent this rank is *relative to its own board*, so the chip colours the
// top of a four-step scale and the top of a two-step scale the same way.
function priorityHeat(sources, task) {
  var src = sourceFor(sources, task)
  var count = src && src.priorities ? src.priorities.length : 4
  var rank = priority(task).rank
  if (priorityTag(task) === "") return "none"
  if (rank <= 0) return "high"
  if (count <= 2) return "low"
  if (rank <= Math.max(1, Math.floor((count - 1) / 2))) return "medium"
  if (rank >= count - 1) return "lowest"
  return "low"
}

// The bottom option of whatever scale the board uses — Delete, Won't, and so
// on. This is what `hideUnimportant` hides.
function isLowestPriority(sources, task) {
  var src = sourceFor(sources, task)
  var count = src && src.priorities ? src.priorities.length : 0
  if (count === 0) return false
  return priority(task).rank >= count - 1
}

// ---- status -------------------------------------------------------------
// Familiar wordings get a familiar label; anything else falls back to the
// board's own word, coloured by the group Notion files it under.

var STATUS = {
  "To Do":       { key: "todo",    label: "todo" },
  "Not started": { key: "todo",    label: "todo" },
  "In progress": { key: "active",  label: "active" },
  "Waiting":     { key: "waiting", label: "waiting" },
  "Testing":     { key: "testing", label: "testing" },
  "Completed":   { key: "done",    label: "done" },
  "Done":        { key: "done",    label: "done" },
  "Archived":    { key: "done",    label: "archived" }
}

var GROUP_KEY = { "To-do": "todo", "In progress": "active", "Complete": "done" }

function statusInfo(task) {
  var raw = task && task.status ? String(task.status) : ""
  if (STATUS[raw]) return STATUS[raw]
  var group = task && task.statusGroup ? String(task.statusGroup) : ""
  return { key: GROUP_KEY[group] || "todo", label: raw.toLowerCase() }
}

// ---- dates --------------------------------------------------------------

function startOfToday() {
  var d = new Date()
  d.setHours(0, 0, 0, 0)
  return d
}

// Notion hands back either "2026-02-16" or "2026-02-09 18:00:00Z".
function dueDate(task) {
  if (!task || !task.due) return null
  var d = new Date(String(task.due).replace(" ", "T"))
  return isNaN(d.getTime()) ? null : d
}

function isOverdue(task) {
  var d = dueDate(task)
  return d !== null && d < startOfToday()
}

function isToday(task) {
  var d = dueDate(task)
  if (d === null) return false
  var start = startOfToday()
  var end = new Date(start.getTime())
  end.setDate(end.getDate() + 1)
  return d >= start && d < end
}

function countOverdue(tasks) { return (tasks || []).filter(isOverdue).length }
function countToday(tasks)   { return (tasks || []).filter(isToday).length }

function dueLabel(task) {
  var d = dueDate(task)
  if (d === null) return ""
  var days = Math.round((d - startOfToday()) / 86400000)
  if (days < -1)  return Math.abs(days) + "d late"
  if (days === -1) return "yesterday"
  if (days === 0)  return "today"
  if (days === 1)  return "tomorrow"
  if (days < 7)    return "in " + days + "d"
  return d.getDate() + " " + MONTHS[d.getMonth()]
}

// Colour axis for the due date: red once it has passed, warming down through
// orange and yellow as it approaches, neutral beyond that.
function dueUrgency(task) {
  var d = dueDate(task)
  if (d === null) return "none"
  var days = Math.round((d - startOfToday()) / 86400000)
  if (days < 0) return "overdue"
  if (days === 0) return "today"
  if (days <= 3) return "soon"
  return "later"
}

// ---- filtering and ordering ---------------------------------------------
// `opts` mirrors the widget settings: sources, hidden, showAllOwners,
// hideUnimportant. Every count and the popup list run through this, so the bar
// number always describes exactly what the popup will show.

function isHidden(opts, key) {
  var hidden = (opts && opts.hidden) || []
  for (var i = 0; i < hidden.length; i++) if (hidden[i] === key) return true
  return false
}

function included(task, opts) {
  var sources = (opts && opts.sources) || []
  var src = sourceFor(sources, task)
  if (!src) return false
  if (isHidden(opts, src.key)) return false
  // A board configured "only mine" still shows everything while the mine/all
  // override is on — the toggle can only ever widen the list, never narrow it.
  if (src.onlyMine && !opts.showAllOwners && task.mine !== true) return false
  if (opts.hideUnimportant && isLowestPriority(sources, task)) return false
  return true
}

function filtered(tasks, opts) {
  return (tasks || []).filter(function (t) { return included(t, opts) })
}

// Dated tasks first in due order, then undated by priority. Within one due
// date the urgent end of the board wins, so a day's list reads worst-first.
function sorted(tasks, opts) {
  var sources = (opts && opts.sources) || []
  var list = (tasks || []).slice()
  list.sort(function (a, b) {
    if (opts && opts.groupBySource) {
      var sa = sourceRank(sources, a), sb = sourceRank(sources, b)
      if (sa !== sb) return sa - sb
    }
    var da = dueDate(a), db = dueDate(b)
    if ((da === null) !== (db === null)) return da === null ? 1 : -1
    if (da !== null && da.getTime() !== db.getTime()) return da.getTime() - db.getTime()
    var pa = priority(a).rank, pb = priority(b).rank
    if (pa !== pb) return pa - pb
    return String(a.name || "").localeCompare(String(b.name || ""))
  })
  return list
}

// The full filtered, sorted list. The panel pages over this rather than
// receiving a pre-truncated slice, so it can report an honest total.
function ordered(tasks, opts) { return sorted(filtered(tasks, opts), opts) }

function ofSource(list, key) {
  return (list || []).filter(function (t) { return sourceKey(t) === key })
}

// The visible groups within one page, in configured order, each with the index
// its first row occupies in the page. That offset is what lets every group
// share one cursor: the panel never has to know how many groups there are.
function pageGroups(sources, rows, groupBySource) {
  var out = []
  if (!groupBySource) return out
  var offset = 0
  var list = sources || []
  for (var i = 0; i < list.length; i++) {
    var items = ofSource(rows, list[i].key)
    if (items.length === 0) continue
    out.push({ key: list[i].key, items: items, offset: offset })
    offset += items.length
  }
  return out
}

function countFor(tasks, key) {
  return (tasks || []).filter(function (t) { return sourceKey(t) === key }).length
}

// ---- paging -------------------------------------------------------------

function pageCount(total, size) {
  return size > 0 ? Math.max(1, Math.ceil(total / size)) : 1
}

function pageSlice(list, page, size) {
  if (size <= 0) return list
  var start = page * size
  return list.slice(start, start + size)
}

// "15-28 of 200", or "1-14 of 14" when everything fits on one page.
function rangeLabel(page, size, total) {
  if (total === 0) return "0 of 0"
  var start = page * size + 1
  var end = Math.min(total, (page + 1) * size)
  return start + "-" + end + " of " + total
}

// ---- status changes -----------------------------------------------------

function statusesOf(sources, key) {
  var list = sources || []
  for (var i = 0; i < list.length; i++)
    if (list[i].key === key && Array.isArray(list[i].statuses)) return list[i].statuses
  return []
}

function statusNames(sources, key) {
  var list = statusesOf(sources, key), out = []
  for (var i = 0; i < list.length; i++) out.push(list[i].name)
  return out
}

function statusNamesFor(sources, task) { return statusNames(sources, sourceKey(task)) }

// The name that means finished on this board — "Completed" here, "Done"
// there, "Live" on someone else's.
function completeStatus(sources, task) {
  var src = sourceFor(sources, task)
  return (src && src.complete) ? String(src.complete) : ""
}

// Where the task sits in its board's list, so the picker opens on it rather
// than at the top.
function statusIndex(sources, task) {
  var names = statusNamesFor(sources, task)
  var current = task && task.status ? String(task.status) : ""
  for (var i = 0; i < names.length; i++) if (names[i] === current) return i
  return 0
}

// Notion page id. Tasks cached before fetch.sh recorded it carry only the URL,
// which ends in the same 32-hex id — so an upgrade does not need a refresh
// before the first status change works.
function taskId(task) {
  if (!task) return ""
  var id = idOf(task.id)
  if (id !== "") return id
  var m = String(task.url || "").match(/([0-9a-fA-F]{32})(?:\?|#|$)/)
  return m ? m[1].toLowerCase() : ""
}

// ---- quick capture ------------------------------------------------------
// Every choice a capture form offers comes from the target board's schema, so
// a new project needs no code here.

function captureTargets(sources) {
  var list = sources || [], out = []
  for (var i = 0; i < list.length; i++)
    out.push({ key: list[i].key, label: list[i].label || list[i].title || list[i].key })
  return out
}

function priorityChoices(sources, key) {
  var list = sources || [], out = [{ label: "no priority", value: "" }]
  for (var i = 0; i < list.length; i++) {
    if (list[i].key !== key) continue
    var prios = list[i].priorities || []
    for (var j = 0; j < prios.length; j++)
      out.push({ label: String(prios[j]).split(" (")[0].trim(), value: prios[j] })
  }
  return out
}

function priorityLabels(sources, key) {
  var choices = priorityChoices(sources, key), out = []
  for (var i = 0; i < choices.length; i++) out.push(choices[i].label)
  return out
}

function priorityValueFor(sources, key, label) {
  var choices = priorityChoices(sources, key)
  for (var i = 0; i < choices.length; i++)
    if (choices[i].label === label) return choices[i].value
  return ""
}

// Extra select properties the board carries (Service, Type, Location…), each
// offered as its own dropdown.
function selectFields(sources, key) {
  var src = null, list = sources || []
  for (var i = 0; i < list.length; i++) if (list[i].key === key) src = list[i]
  if (!src || !src.props) return []
  var names = src.props.selects || [], out = []
  for (var j = 0; j < names.length; j++) {
    // The placeholder is carried rather than pattern-matched later: an option
    // legitimately called "no charge" must not read as "left blank".
    var blank = "no " + String(names[j]).toLowerCase()
    out.push({ name: names[j], placeholder: blank,
               options: [blank].concat(selectOptions(sources, key, names[j])) })
  }
  return out
}

function selectOptions(sources, key, prop) {
  var list = sources || []
  for (var i = 0; i < list.length; i++)
    if (list[i].key === key && list[i].selectOptions && list[i].selectOptions[prop])
      return list[i].selectOptions[prop]
  return []
}

// Relation properties the config asked to load (Clients, Projects…).
function relationFields(sources, key) {
  var list = sources || [], out = []
  for (var i = 0; i < list.length; i++) {
    if (list[i].key !== key) continue
    var rels = list[i].relations || {}
    for (var name in rels)
      out.push({ name: name, rows: rels[name] || [] })
  }
  return out
}

function relationNames(rows) {
  var out = ["none"]
  for (var i = 0; i < (rows || []).length; i++) out.push(rows[i].name)
  return out
}

function relationIdFor(rows, name) {
  for (var i = 0; i < (rows || []).length; i++)
    if (rows[i].name === name) return rows[i].id
  return ""
}

// ---- cache --------------------------------------------------------------

// One task, reduced to the fields this widget renders, each of them checked.
// Anything else the document carried is dropped rather than carried around:
// a field nothing reads is a field nothing bounds.
function normalizeTask(raw) {
  if (!isObject(raw)) return null
  var name = plain(raw.name, MAX_TEXT)
  if (name === "") return null
  return {
    id: idOf(raw.id),
    name: name,
    status: plain(raw.status, MAX_SHORT),
    statusGroup: plain(raw.statusGroup, MAX_SHORT),
    priority: plain(raw.priority, MAX_SHORT),
    rank: numberOr(raw.rank, 0),
    due: typeof raw.due === "string" ? plain(raw.due, 64) : null,
    url: safeUrl(raw.url),
    source: plain(raw.source, 64),
    mine: boolOf(raw.mine)
  }
}

function normalizeStrings(list, limit, itemLimit) {
  var raw = capped(list, limit), out = []
  for (var i = 0; i < raw.length; i++) {
    var s = plain(raw[i], itemLimit)
    if (s !== "") out.push(s)
  }
  return out
}

function normalizeMap(map, limit, valueLimit, itemLimit) {
  var out = {}, n = 0
  if (!isObject(map)) return out
  for (var key in map) {
    if (n >= limit) break
    var k = plain(key, MAX_SHORT)
    if (k === "") continue
    out[k] = normalizeStrings(map[key], valueLimit, itemLimit)
    n++
  }
  return out
}

function normalizeRelations(map) {
  var out = {}, n = 0
  if (!isObject(map)) return out
  for (var key in map) {
    if (n >= MAX_RELATIONS) break
    var k = plain(key, MAX_SHORT)
    if (k === "") continue
    var rows = capped(map[key], MAX_RELATION_ROWS), kept = []
    for (var i = 0; i < rows.length; i++) {
      if (!isObject(rows[i])) continue
      var id = idOf(rows[i].id), label = plain(rows[i].name, MAX_SHORT)
      if (id !== "" && label !== "") kept.push({ id: id, name: label })
    }
    out[k] = kept
    n++
  }
  return out
}

function normalizeSource(raw) {
  if (!isObject(raw)) return null
  var key = plain(raw.key, 64)
  if (key === "" || idOf(raw.database) === "") return null
  var props = isObject(raw.props) ? raw.props : {}
  var statuses = capped(raw.statuses, MAX_STATUSES), keptStatuses = []
  for (var i = 0; i < statuses.length; i++) {
    if (!isObject(statuses[i])) continue
    var name = plain(statuses[i].name, MAX_SHORT)
    if (name !== "") keptStatuses.push({ name: name, group: plain(statuses[i].group, MAX_SHORT) })
  }
  return {
    key: key,
    label: plain(raw.label, MAX_SHORT),
    badge: plain(raw.badge, 8),
    database: idOf(raw.database),
    url: safeUrl(raw.url),
    onlyMine: boolOf(raw.onlyMine),
    complete: plain(raw.complete, MAX_SHORT),
    props: {
      title: plain(props.title, MAX_SHORT),
      status: plain(props.status, MAX_SHORT),
      date: plain(props.date, MAX_SHORT),
      priority: plain(props.priority, MAX_SHORT),
      owner: plain(props.owner, MAX_SHORT),
      selects: normalizeStrings(props.selects, MAX_SELECTS, MAX_SHORT)
    },
    statuses: keptStatuses,
    priorities: normalizeStrings(raw.priorities, MAX_PRIORITIES, MAX_SHORT),
    selectOptions: normalizeMap(raw.selectOptions, MAX_SELECTS, MAX_OPTIONS, MAX_SHORT),
    relations: normalizeRelations(raw.relations)
  }
}

function parseCache(text) {
  var s = text === undefined || text === null ? "" : String(text)
  // Weighed before it is parsed: JSON.parse on an arbitrarily large string is
  // the one step here with no natural ceiling of its own.
  if (s.length > MAX_CACHE_CHARS)
    return { tasks: [], sources: [], updated: "", error: "cache too large" }
  try {
    var o = JSON.parse(s || "{}")
    if (!isObject(o)) throw new Error("not an object")

    var sources = [], rawSources = capped(o.sources, MAX_SOURCES)
    for (var i = 0; i < rawSources.length; i++) {
      var src = normalizeSource(rawSources[i])
      if (src) sources.push(src)
    }

    var tasks = [], rawTasks = capped(o.tasks, MAX_TASKS)
    for (var j = 0; j < rawTasks.length; j++) {
      var task = normalizeTask(rawTasks[j])
      // A task whose board did not survive has nothing to be grouped, sorted
      // or coloured against.
      if (task && sourceFor(sources, task)) tasks.push(task)
    }

    return {
      tasks: tasks,
      sources: sources,
      updated: plain(o.updated, 64),
      error: plain(o.error, MAX_TEXT)
    }
  } catch (e) {
    return { tasks: [], sources: [], updated: "", error: "cache unreadable" }
  }
}

// "17:42" from the ISO stamp fetch.sh writes, for the popup footer.
//
// That footer is the one StyledText in the widget, which makes this the one
// cache-derived string that reaches a markup-aware sink. So the guarantee is
// made here and checked here: two literals, or four digits and a colon.
function updatedLabel(iso) {
  if (!iso) return "never"
  var d = new Date(String(iso).slice(0, 64))
  if (isNaN(d.getTime())) return "unknown"
  var hh = ("0" + d.getHours()).slice(-2)
  var mm = ("0" + d.getMinutes()).slice(-2)
  var out = hh + ":" + mm
  return /^[0-9]{2}:[0-9]{2}$/.test(out) ? out : "unknown"
}
