import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Open Notion tasks in the bar. The bar label is the count that needs action
// now (overdue + due today), falling back to the total open count when the day
// is clear. The popup is the triaged list; clicking a row opens the page.
//
// Data arrives out-of-band: fetch.sh writes a JSON cache and this widget only
// ever reads that file. A failed fetch therefore leaves the last good list on
// screen instead of blanking it.
//
// Nothing here names a database, a status or a priority. The boards come from
// ~/.config/omarchy/notion-tasks.json and everything about how to read them is
// inferred from their schemas by fetch.sh, so this file works the same for two
// projects or seven.
Panel {
  id: root
  moduleName: "io.github.taraskim.notion-tasks"
  ipcTarget: "io.github.taraskim.notion-tasks"
  manageIpc: false

  property var tasks: []
  property var sources: []
  property string updatedAt: ""
  property string cacheError: ""
  property string fetchError: ""
  property bool fetching: false
  property bool capturing: false
  property bool creating: false
  property string captureError: ""
  property int cursorIndex: 0
  property bool cursorActive: false

  // Status-change mode. The task is held by value rather than by index: the
  // ordered list can shift under a refresh while the picker is open, and the
  // change must land on the row that was actually chosen.
  property bool choosingStatus: false
  property var statusTask: null
  property int statusChoice: 0
  property bool statusBusy: false
  property string statusError: ""
  property string statusPendingName: ""

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Omarchy's Color singleton keeps only foreground/background/accent/urgent/
  // muted — the theme's colors.toml carries a fuller palette that it parses
  // and discards. Read it directly so status and due dates can use real hues,
  // with every key falling back to an exposed role when a theme omits it.
  property var themeColors: ({})

  function themeColor(key, fallback) {
    var value = themeColors[key]
    return value === undefined ? fallback : value
  }

  readonly property color cRed:     themeColor("red", urgent)
  readonly property color cOrange:  themeColor("orange", themeColor("yellow", urgent))
  readonly property color cYellow:  themeColor("yellow", cOrange)
  readonly property color cBlue:    themeColor("blue", Color.accent)
  readonly property color cMagenta: themeColor("magenta", Color.accent)
  readonly property color cMuted:   themeColor("muted", dim)

  readonly property var hues: ({
    red: cRed, orange: cOrange, yellow: cYellow,
    blue: cBlue, magenta: cMagenta, muted: cMuted,
    foreground: foreground, dim: dim
  })

  function loadThemeColors(raw) {
    var parsed = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var m = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["\']?(#[0-9A-Fa-f]{6})/)
      if (m) parsed[m[1]] = m[2]
    }
    themeColors = parsed
  }

  readonly property int refreshSec: setting("refreshIntervalSec", 300)
  // maxTasks is the pre-pagination name; still honoured for stored entries.
  readonly property int pageSize: setting("pageSize", setting("maxTasks", 14))
  readonly property string openScript: String(Qt.resolvedUrl("open-task.sh")).replace(/^file:\/\//, "")
  // Reuses a single task window rather than leaving one behind per click; see
  // open-task.sh. Set openCommand to "omarchy-launch-webapp" for a window per
  // task, or "xdg-open" for a browser tab.
  // Empty counts as unset, not as "run nothing": the manifest seeds an empty
  // default so re-adding the widget cannot bake in a broken command.
  readonly property string openCommandSetting: setting("openCommand", "")
  readonly property string openCommand: openCommandSetting !== ""
    ? openCommandSetting
    : ("bash " + openScript)
  readonly property bool hideUnimportant: setting("hideUnimportant", true)
  readonly property bool groupBySource: setting("groupBySource", true)
  readonly property bool showStatus: setting("showStatus", true)
  // Boards configured "only mine" show everyone's work while this is on. It
  // can only widen the list, which is why one key can serve every board.
  readonly property bool showAllOwners: setting("showAllOwners", false)
  // Keys of boards switched off from the popup. Stored rather than derived so
  // the choice survives a restart.
  readonly property var hiddenSources: setting("hiddenSources", [])
  readonly property string glyph: setting("label", "✓")

  // One options object drives the counts, the popup list and the header, so
  // the bar number always describes exactly what a click will show.
  readonly property var filterOpts: ({
    sources: sources,
    hidden: hiddenSources,
    showAllOwners: showAllOwners,
    hideUnimportant: hideUnimportant,
    groupBySource: groupBySource
  })

  readonly property string cachePath: Quickshell.env("HOME") + "/.local/state/omarchy/notion-tasks.json"
  readonly property string fetchScript: String(Qt.resolvedUrl("fetch.sh")).replace(/^file:\/\//, "")
  readonly property string createScript: String(Qt.resolvedUrl("create-task.sh")).replace(/^file:\/\//, "")
  readonly property string statusScript: String(Qt.resolvedUrl("set-status.sh")).replace(/^file:\/\//, "")

  readonly property var activeTasks: Model.filtered(tasks, filterOpts)
  readonly property var orderedTasks: Model.ordered(tasks, filterOpts)

  // The cursor indexes the whole ordered list; the page is derived from it, so
  // walking off the bottom of a page turns to the next one on its own.
  readonly property int totalRows: orderedTasks.length
  readonly property int pageCount: Model.pageCount(totalRows, pageSize)
  readonly property int page: pageSize > 0 ? Math.min(pageCount - 1, Math.floor(cursorIndex / pageSize)) : 0
  readonly property int cursorInPage: cursorIndex - page * pageSize
  readonly property string rangeText: Model.rangeLabel(page, pageSize, totalRows)
  readonly property var rows: Model.pageSlice(orderedTasks, page, pageSize)

  // The groups present on this page, in configured order, each carrying the
  // index its first row occupies within the page. One shared cursor walks all
  // of them because every group knows its own offset.
  readonly property var groups: Model.pageGroups(sources, rows, groupBySource)

  function isSourceHidden(key) {
    for (var i = 0; i < hiddenSources.length; i++) if (hiddenSources[i] === key) return true
    return false
  }

  function toggleSource(key) {
    var next = []
    var found = false
    for (var i = 0; i < hiddenSources.length; i++) {
      if (hiddenSources[i] === key) { found = true; continue }
      next.push(hiddenSources[i])
    }
    if (!found) next.push(key)
    updateSetting("hiddenSources", next)
  }

  function groupHeader(key) {
    var text = Model.groupTitle(sources, key) + "  ·  " + Model.countFor(activeTasks, key)
    var src = Model.sourceFor(sources, key === "" ? null : { source: key })
    if (src && src.onlyMine) text += showAllOwners ? "  (all)" : "  (mine)"
    return text
  }

  onOrderedTasksChanged: if (cursorIndex >= orderedTasks.length)
                           cursorIndex = Math.max(0, orderedTasks.length - 1)
  readonly property int overdueCount: Model.countOverdue(activeTasks)
  readonly property int todayCount: Model.countToday(activeTasks)
  readonly property int actionable: overdueCount + todayCount
  readonly property int openCount: activeTasks.length

  readonly property string barText: glyph + " " + (actionable > 0 ? actionable : openCount)
  readonly property string statusLine: {
    if (openCount === 0) return cacheError !== "" || fetchError !== "" ? "No data yet" : "Nothing open"
    var parts = []
    if (overdueCount > 0) parts.push(overdueCount + " overdue")
    if (todayCount > 0) parts.push(todayCount + " due today")
    var perSource = []
    for (var i = 0; i < sources.length; i++) {
      if (isSourceHidden(sources[i].key)) continue
      perSource.push(Model.countFor(activeTasks, sources[i].key) + " " + sources[i].label)
    }
    parts.push(perSource.length > 1 ? perSource.join("  ·  ") : openCount + " open")
    return parts.join("  ·  ")
  }
  readonly property string problem: statusError !== "" ? statusError
                                    : (fetchError !== "" ? fetchError : cacheError)

  function applyCache(raw) {
    var parsed = Model.parseCache(raw)
    tasks = parsed.tasks
    sources = parsed.sources
    updatedAt = parsed.updated
    cacheError = parsed.error
  }

  function updateSetting(key, value) {
    var entry = { id: root.moduleName }
    for (var k in root.settings) if (k !== "id") entry[k] = root.settings[k]
    entry[key] = value
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function refresh() {
    themeFile.reload()
    if (fetcher.running) return
    fetching = true
    fetcher.running = true
  }

  // omarchy-launch-webapp opens the page as a Chromium --app window, so a task
  // lands in the same chrome-less surface as the installed Notion app rather
  // than a browser tab.
  //
  // The URL is never spliced into the command line. It comes from Notion, which
  // means anyone who can add a row to a shared board writes part of it; that it
  // arrives slug-safe today is a property of Notion's title mangling, not a
  // guarantee. It travels as a positional parameter instead, which bash expands
  // without re-tokenizing — the shape Commons/Util.qml recommends for anything
  // built from input. The login shell is kept because open-task.sh needs the
  // session PATH to find omarchy-launch-webapp and hyprctl.
  function openUrl(url) {
    if (!url) return
    var target = String(url)
    if (openCommandSetting === "") {
      Quickshell.execDetached(["bash", "-lc", 'exec bash "$@"', "bash", openScript, target])
      return
    }
    // A configured openCommand is a shell fragment by design ("xdg-open",
    // "flatpak run … --"), so it stays shell; only the URL is quarantined.
    Quickshell.execDetached(["bash", "-lc", openCommandSetting + ' "$@"', "bash", target])
  }

  function openTask(task) {
    if (!task) return
    openUrl(task.url)
    close()
  }

  // The board behind the highlighted row, falling back to the first one, so
  // "open the database" means something with any number of projects.
  function openDatabase() {
    var task = cursorTask()
    var src = task ? Model.sourceFor(sources, task) : null
    if (!src && sources.length > 0) src = sources[0]
    if (src && src.url) { openUrl(src.url); close() }
  }

  function startCapture() {
    captureError = ""
    capturing = true
    if (!opened) controller.show()
    // The key catcher owns the panel's focus; hand it to the field so typing
    // lands in the form rather than firing list shortcuts.
    Qt.callLater(function () { captureForm.focusTitle() })
  }

  function cancelCapture() {
    capturing = false
    creating = false
    captureError = ""
    captureForm.reset()
    keyCatcher.forceActiveFocus()
  }

  function submitCapture() {
    if (creating) return
    var title = String(captureForm.titleText).trim()
    if (title === "") { captureError = "A task needs a title."; return }

    var args = ["bash", createScript, "--dest", captureForm.dest, "--title", title]

    var priority = Model.priorityValueFor(sources, captureForm.dest, captureForm.priorityLabel)
    if (priority !== "") args = args.concat(["--priority", priority])

    var due = String(captureForm.dueText).trim()
    if (due !== "") args = args.concat(["--due", due])

    // Extra selects and relations are whatever the target board carries, so
    // they travel as name/value pairs rather than as named flags.
    var extras = captureForm.extraArgs()
    for (var i = 0; i < extras.length; i++) args.push(extras[i])

    captureError = ""
    creating = true
    creator.command = args
    creator.running = true
  }

  // The row the keyboard is on, or null when the cursor has not been engaged
  // yet. Both status actions require it: completing whatever happens to be at
  // index 0 because you had not aimed yet is not a good surprise.
  function cursorTask() {
    if (!cursorActive || cursorIndex < 0 || cursorIndex >= totalRows) return null
    return orderedTasks[cursorIndex]
  }

  function startStatusPick() {
    // Matches the list's own "first key press only wakes the cursor" rule.
    if (!cursorActive) { cursorActive = true; return }
    var task = cursorTask()
    if (!task) return
    statusError = ""
    statusTask = task
    statusChoice = Model.statusIndex(sources, task)
    choosingStatus = true
  }

  function cancelStatusPick() {
    choosingStatus = false
    statusTask = null
    statusBusy = false
    statusPendingName = ""
    statusError = ""
    keyCatcher.forceActiveFocus()
  }

  function moveStatusChoice(delta) {
    var count = Model.statusNamesFor(sources, statusTask).length
    if (count === 0) return
    statusChoice = Math.max(0, Math.min(count - 1, statusChoice + delta))
  }

  // Matched on id rather than on object identity: a refresh can land mid-write
  // and rebuild the task objects underneath the list.
  function isPending(task) {
    if (!statusBusy || !statusTask || !task) return false
    var id = Model.taskId(task)
    return id !== "" && id === Model.taskId(statusTask)
  }

  function isPendingComplete(task) {
    return isPending(task) && statusPendingName !== ""
           && statusPendingName === Model.completeStatus(sources, task)
  }

  function applyStatus(task, name) {
    if (statusBusy || !task || !name) return
    var id = Model.taskId(task)
    if (id === "") { statusError = "That task has no Notion id — refresh and try again."; return }
    statusError = ""
    statusPendingName = name
    statusBusy = true
    statusSetter.command = ["bash", statusScript, "--id", id, "--status", name]
    statusSetter.running = true
  }

  function submitStatus() {
    var names = Model.statusNamesFor(sources, statusTask)
    if (statusChoice < 0 || statusChoice >= names.length) return
    // Choosing the status it already has is a no-op, not a round trip.
    if (statusTask && names[statusChoice] === statusTask.status) { cancelStatusPick(); return }
    applyStatus(statusTask, names[statusChoice])
  }

  // One key for the overwhelmingly common change, so finishing a task does not
  // cost a trip through the picker.
  function completeCursorTask() {
    if (!cursorActive) { cursorActive = true; return }
    var task = cursorTask()
    if (!task) return
    var done = Model.completeStatus(sources, task)
    if (done === "") { statusError = "No completed status on that board."; return }
    if (task.status === done) return
    statusTask = task
    applyStatus(task, done)
  }

  function moveCursor(delta) {
    if (totalRows === 0) return
    cursorIndex = Math.max(0, Math.min(totalRows - 1, cursorIndex + delta))
  }

  function changePage(direction) {
    if (totalRows === 0) return
    var target = Math.max(0, Math.min(pageCount - 1, page + direction))
    cursorIndex = Math.min(totalRows - 1, target * pageSize)
    cursorActive = true
  }

  function activateCursor() {
    if (cursorIndex >= 0 && cursorIndex < totalRows) openTask(orderedTasks[cursorIndex])
  }

  function open() {
    cursorActive = false
    cursorIndex = 0
    if (choosingStatus) cancelStatusPick()
    themeFile.reload()
    controller.show()
    refresh()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // current/theme is a symlink that a theme switch retargets, which a plain
  // watch does not reliably see — so this is also reloaded whenever the popup
  // opens and on every refresh tick.
  FileView {
    id: themeFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.loadThemeColors(text())
    onLoadFailed: root.loadThemeColors("")
  }

  FileView {
    id: cacheFile
    path: root.cachePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyCache(text())
    onLoadFailed: root.applyCache("")
  }

  Process {
    id: fetcher
    command: ["bash", root.fetchScript]
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.fetchError = String(text || "").trim()
    }
    onExited: function (exitCode) {
      root.fetching = false
      if (exitCode === 0) {
        root.fetchError = ""
        cacheFile.reload()
      } else if (root.fetchError === "") {
        root.fetchError = "fetch failed (exit " + exitCode + ")"
      }
    }
  }

  Process {
    id: creator
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.captureError = String(text || "").trim()
    }
    onExited: function (exitCode) {
      root.creating = false
      if (exitCode === 0) {
        root.captureError = ""
        root.capturing = false
        captureForm.reset()
        keyCatcher.forceActiveFocus()
        // create-task.sh refreshes the cache itself; this just picks it up
        // immediately rather than on the next watch tick.
        cacheFile.reload()
      } else if (root.captureError === "") {
        root.captureError = "Could not create the task (exit " + exitCode + ")."
      }
    }
  }

  Process {
    id: statusSetter
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.statusError = String(text || "").trim()
    }
    onExited: function (exitCode) {
      root.statusBusy = false
      root.statusPendingName = ""
      if (exitCode === 0) {
        root.statusError = ""
        root.choosingStatus = false
        root.statusTask = null
        keyCatcher.forceActiveFocus()
        // set-status.sh refreshes the cache itself; this just picks it up now
        // rather than on the next watch tick.
        cacheFile.reload()
      } else if (root.statusError === "") {
        root.statusError = "Could not change the status (exit " + exitCode + ")."
      }
    }
  }

  Timer {
    interval: Math.max(60, root.refreshSec) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  IpcHandler {
    target: "io.github.taraskim.notion-tasks"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.broadcastRefresh(); return "ok" }
    function count(): string { return String(root.actionable) }
    function capture(): string { root.startCapture(); return "ok" }
    function complete(): string { root.completeCursorTask(); return "ok" }
    function projects(): string {
      var out = []
      for (var i = 0; i < root.sources.length; i++) {
        var s = root.sources[i]
        out.push({ key: s.key, label: s.label, hidden: root.isSourceHidden(s.key),
                   onlyMine: s.onlyMine === true,
                   open: Model.countFor(root.activeTasks, s.key),
                   complete: s.complete })
      }
      return JSON.stringify(out)
    }
    function stats(): string {
      return JSON.stringify({
        cached: root.tasks.length, shown: root.totalRows,
        page: root.page + 1, pages: root.pageCount, pageSize: root.pageSize,
        overdue: root.overdueCount, projects: root.sources.length,
        range: root.rangeText, openCommand: root.openCommand
      })
    }
  }

  // The bar mounts one widget per monitor; refresh on all of them so a manual
  // refresh does not leave other screens stale.
  function broadcastRefresh() {
    var items = bar && typeof bar.moduleWidgets === "function"
      ? bar.moduleWidgets(moduleName) : [root]
    for (var i = 0; i < items.length; i++)
      if (items[i] && typeof items[i].refresh === "function") items[i].refresh()
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText
    active: root.overdueCount > 0
    tooltipText: root.statusLine

    onPressed: function (buttonCode) {
      if (buttonCode === Qt.RightButton) root.refresh()
      else if (buttonCode === Qt.MiddleButton) root.openDatabase()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function (dx, dy) {
        if (root.capturing) return
        if (root.choosingStatus) { root.moveStatusChoice(dy); return }
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dx !== 0) root.changePage(dx)
        else root.moveCursor(dy)
      }
      onActivateRequested: {
        if (root.capturing) return
        if (root.choosingStatus) root.submitStatus()
        else if (root.cursorActive) root.activateCursor()
      }
      onCloseRequested: {
        if (root.capturing) root.cancelCapture()
        else if (root.choosingStatus) root.cancelStatusPick()
        else root.close()
      }
      onTabRequested: function (direction) {
        if (!root.capturing && !root.choosingStatus) root.switchPanel(direction)
      }
      onTextKey: function (t) {
        if (root.capturing || root.choosingStatus) return
        // 1..9 switch a project off and on. With any number of boards there is
        // no single "the other one" for a letter key to mean.
        if (t >= "1" && t <= "9") {
          var i = parseInt(t, 10) - 1
          if (i < root.sources.length) root.toggleSource(root.sources[i].key)
          return
        }
        if (t === "n" || t === "N") root.startCapture()
        else if (t === "s" || t === "S") root.startStatusPick()
        else if (t === "d" || t === "D") root.completeCursorTask()
        else if (t === "r" || t === "R") root.refresh()
        else if (t === "o" || t === "O") root.openDatabase()
        else if (t === "m" || t === "M") root.updateSetting("showAllOwners", !root.showAllOwners)
        else if (t === "[") root.changePage(-1)
        else if (t === "]") root.changePage(1)
        else if (t === "g" || t === "G") root.updateSetting("groupBySource", !root.groupBySource)
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.spacing.xxl

          // List, capture form and status picker are the panel's three modes.
          // Column skips invisible children, so the popup resizes to whichever
          // is showing.
          Column {
            id: listColumn
            visible: !root.capturing && !root.choosingStatus
            width: parent.width
            spacing: Style.spacing.xxl

            PanelHero {
              width: parent.width
              title: "Tasks"
              meta: root.statusLine
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              visible: root.problem !== ""
              width: parent.width
              text: root.problem
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            PanelSeparator { foreground: root.foreground }

            Column {
              width: parent.width
              spacing: Style.spacing.xl

              PanelSectionHeader {
                text: {
                  if (root.groupBySource) return "UP NEXT  ·  " + root.rangeText.toUpperCase()
                  var shown = []
                  for (var i = 0; i < root.sources.length; i++)
                    if (!root.isSourceHidden(root.sources[i].key))
                      shown.push(String(root.sources[i].label).toUpperCase())
                  return (shown.length > 0 ? shown.join(" + ") : "NOTHING SHOWN")
                         + "  ·  " + root.rangeText.toUpperCase()
                }
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Text {
                visible: root.rows.length === 0
                width: parent.width
                text: root.sources.length === 0
                      ? "No projects configured — run setup.sh."
                      : (root.openCount > 0 ? "Nothing left after filtering." : "No open tasks.")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                horizontalAlignment: Text.AlignHCenter
              }

              // Ungrouped: one flat list, each row badged with its source.
              Column {
                id: taskColumn
                visible: root.rows.length > 0 && !root.groupBySource
                width: parent.width
                spacing: Style.spacing.xxs

                Repeater {
                  model: root.groupBySource ? [] : root.rows

                  TaskRow {
                    required property var modelData
                    required property int index
                    width: taskColumn.width
                    task: modelData
                    sources: root.sources
                    rowIndex: index
                    showBadge: true
                    hasCursor: root.cursorActive && root.cursorInPage === index
                    foreground: root.foreground
                    urgent: root.urgent
                    dim: root.dim
                    hues: root.hues
                    showStatus: root.showStatus
                    pending: root.isPending(modelData)
                    pendingComplete: root.isPendingComplete(modelData)
                    fontFamily: root.fontFamily
                    onActivated: root.openTask(modelData)
                    onHovered: { root.cursorActive = true; root.cursorIndex = root.page * root.pageSize + index }
                  }
                }
              }

              // Grouped: a headed block per board, in configured order. Each
              // group carries the page-index of its first row, which is what
              // lets every block share the one cursor no matter how many
              // boards there are.
              Column {
                id: groupColumn
                visible: root.groupBySource && root.groups.length > 0
                width: parent.width
                spacing: Style.spacing.xxl

                Repeater {
                  model: root.groupBySource ? root.groups : []

                  Column {
                    id: groupBlock
                    required property var modelData
                    width: groupColumn.width
                    spacing: Style.spacing.md

                    PanelSectionHeader {
                      text: root.groupHeader(groupBlock.modelData.key)
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                    }

                    Repeater {
                      model: groupBlock.modelData.items

                      TaskRow {
                        required property var modelData
                        required property int index
                        readonly property int pageRow: groupBlock.modelData.offset + index
                        width: groupBlock.width
                        task: modelData
                        sources: root.sources
                        rowIndex: index
                        showBadge: false
                        hasCursor: root.cursorActive && root.cursorInPage === pageRow
                        foreground: root.foreground
                        urgent: root.urgent
                        dim: root.dim
                        hues: root.hues
                        showStatus: root.showStatus
                        pending: root.isPending(modelData)
                        pendingComplete: root.isPendingComplete(modelData)
                        fontFamily: root.fontFamily
                        onActivated: root.openTask(modelData)
                        onHovered: { root.cursorActive = true; root.cursorIndex = root.page * root.pageSize + pageRow }
                      }
                    }
                  }
                }
              }
            }

            PanelSeparator { foreground: root.foreground }

            Column {
              width: parent.width
              spacing: Style.spacing.md

              // Pager. Hidden entirely when everything fits on one page, so a
              // short list keeps the popup as quiet as it was before.
              Row {
                visible: root.pageCount > 1
                width: parent.width
                spacing: Style.spacing.xl

                PagerButton {
                  glyph: "‹"
                  stepEnabled: root.page > 0
                  foreground: root.foreground
                  dim: root.dim
                  fontFamily: root.fontFamily
                  onTriggered: root.changePage(-1)
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.rangeText + "   ·   page " + (root.page + 1) + " of " + root.pageCount
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                PagerButton {
                  glyph: "›"
                  stepEnabled: root.page < root.pageCount - 1
                  foreground: root.foreground
                  dim: root.dim
                  fontFamily: root.fontFamily
                  onTriggered: root.changePage(1)
                }
              }

              // Which number key belongs to which board, and which are off.
              Text {
                visible: root.sources.length > 1
                width: parent.width
                text: {
                  var parts = []
                  for (var i = 0; i < root.sources.length; i++) {
                    var s = root.sources[i]
                    parts.push((i + 1) + " " + s.label + (root.isSourceHidden(s.key) ? " (off)" : ""))
                  }
                  return parts.join("   ")
                }
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              Text {
                width: parent.width
                text: (root.statusBusy ? "Saving…"
                       : root.fetching ? "Refreshing…"
                       : "Updated " + Model.updatedLabel(root.updatedAt))
                      + "     n new   s status   d done   ←→ page   g group   r refresh"
                      + "   m mine/all   o database"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }
          }

          StatusForm {
            id: statusForm
            visible: root.choosingStatus
            width: parent.width
            task: root.statusTask
            options: Model.statusNamesFor(root.sources, root.statusTask)
            choice: root.statusChoice
            currentStatus: root.statusTask && root.statusTask.status ? root.statusTask.status : ""
            busy: root.statusBusy
            errorText: root.statusError
            foreground: root.foreground
            urgent: root.urgent
            dim: root.dim
            fontFamily: root.fontFamily
            onPicked: function (i) { root.statusChoice = i }
            onSubmitted: root.submitStatus()
            onCancelled: root.cancelStatusPick()
          }

          CaptureForm {
            id: captureForm
            visible: root.capturing
            width: parent.width
            sources: root.sources
            foreground: root.foreground
            urgent: root.urgent
            dim: root.dim
            fontFamily: root.fontFamily
            busy: root.creating
            errorText: root.captureError
            onSubmitted: root.submitCapture()
            onCancelled: root.cancelCapture()
          }
        }
      }
    }
  }
}
