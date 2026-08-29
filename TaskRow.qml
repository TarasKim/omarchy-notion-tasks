import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// One task line: priority chip, name, status, relative due date.
// Clicking opens the Notion page; the row is also the keyboard cursor target.
//
// Colour carries three independent axes without turning into a rainbow:
//   priority -> chip      red / orange / neutral, "how much does this matter"
//   status   -> label     blue in flight, yellow blocked, magenta testing
//   due      -> date      red past, orange today, yellow soon, neutral beyond
Item {
  id: row

  property var task: null
  // The board this task came from, for the badge and for reading the chip
  // against that board's own priority scale.
  property var sources: []
  property int rowIndex: 0
  property bool hasCursor: false
  // Redundant once the popup draws a header per source, so grouping hides it.
  property bool showBadge: true
  property bool showStatus: true

  // A status write is in flight for this row. The write takes a round trip to
  // Notion plus a re-fetch, and for a completion the row then vanishes — so
  // without this the popup just sits there for a second and then something
  // disappears, which reads as a glitch rather than as the thing working.
  property bool pending: false
  property bool pendingComplete: false

  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property color dim: Qt.darker(foreground, 1.55)
  property string fontFamily: Style.font.family

  // red / orange / yellow / blue / magenta / muted, resolved from the theme
  // by the panel. Named `hues` because Item already owns `palette`.
  property var hues: ({})

  signal activated()
  signal hovered()

  readonly property var prio: Model.priority(task)
  readonly property var status: Model.statusInfo(task)
  readonly property string sourceTag: Model.sourceLabel(sources, task)
  readonly property string heat: Model.priorityHeat(sources, task)
  readonly property string urgency: Model.dueUrgency(task)

  function hue(key, fallback) {
    var value = hues ? hues[key] : undefined
    return value === undefined ? fallback : value
  }

  readonly property color chipColor: {
    if (heat === "high") return hue("red", urgent)
    if (heat === "medium") return hue("orange", urgent)
    if (heat === "lowest") return hue("muted", dim)
    return dim
  }

  readonly property color statusColor: {
    if (status.key === "active") return hue("blue", foreground)
    if (status.key === "waiting") return hue("yellow", dim)
    if (status.key === "testing") return hue("magenta", dim)
    return dim
  }

  // Completing strikes the name through straight away. It is the optimistic
  // half of the feedback: if Notion rejects the change the row is still here a
  // moment later, un-struck, with the reason in the popup.
  readonly property string pendingLabel: pendingComplete ? "completing…" : "saving…"

  readonly property color dueColor: {
    if (urgency === "overdue") return hue("red", urgent)
    if (urgency === "today") return hue("orange", urgent)
    if (urgency === "soon") return hue("yellow", foreground)
    return dim
  }

  implicitHeight: content.implicitHeight + Style.spacing.lg * 2

  opacity: pending ? 0.45 : 1.0
  Behavior on opacity { NumberAnimation { duration: 120 } }

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: row.hasCursor || mouse.containsMouse ? Style.hoverFill : "transparent"
    border.width: row.hasCursor ? Style.hoverBorderWidth : 0
    border.color: Style.hoverBorderColor
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    enabled: !row.pending
    onEntered: row.hovered()
    onClicked: row.activated()
  }

  Row {
    id: content
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: Style.spacing.lg
    anchors.rightMargin: Style.spacing.lg
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.spacing.xl

    Text {
      id: chip
      width: Style.space(56)
      anchors.verticalCenter: parent.verticalCenter
      text: row.prio.tag
      color: row.chipColor
      font.family: row.fontFamily
      font.pixelSize: Style.font.caption
      // Capitals set at caption size need the tracking; without it the chip
      // column reads as a smudge rather than as labels. The hero's meta line
      // does the same at 1.2 — less here, because this one sits in a fixed
      // column and has to leave room for the longest tag on the board.
      font.letterSpacing: 0.8
      // Weight, not just colour, carries the top of the scale: a red chip and
      // a grey one at the same weight is the same information twice for most
      // people and none at all for the rest.
      font.bold: row.heat === "high"
      elide: Text.ElideRight
    }

    Text {
      id: name
      width: Math.max(0, content.width - chip.width
                         - (statusText.visible ? statusText.implicitWidth + content.spacing : 0)
                         - (badge.visible ? badge.implicitWidth + content.spacing : 0)
                         - (due.visible ? due.implicitWidth + content.spacing : 0)
                         - content.spacing)
      anchors.verticalCenter: parent.verticalCenter
      text: row.task && row.task.name ? row.task.name : ""
      color: row.foreground
      font.family: row.fontFamily
      font.pixelSize: Style.font.body
      font.strikeout: row.pendingComplete
      elide: Text.ElideRight
    }

    Text {
      id: statusText
      visible: row.showStatus && row.status.label !== "" && row.status.key !== "todo"
      anchors.verticalCenter: parent.verticalCenter
      text: row.status.label
      color: row.statusColor
      font.family: row.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      id: badge
      visible: row.showBadge && row.sourceTag !== ""
      anchors.verticalCenter: parent.verticalCenter
      text: row.sourceTag
      color: row.dim
      font.family: row.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      id: due
      visible: text !== ""
      anchors.verticalCenter: parent.verticalCenter
      text: row.pending ? row.pendingLabel : Model.dueLabel(row.task)
      color: row.pending ? row.dim : row.dueColor
      font.family: row.fontFamily
      // Caption, with the chip, the status and the badge. At bodySmall this
      // sat one pixel under the task name, which is not a step anyone can
      // see — it just made the row look mis-set. Overdue still shouts, in the
      // two channels that carry at this size: colour and weight.
      font.pixelSize: Style.font.caption
      font.bold: !row.pending && row.urgency === "overdue"
      font.italic: row.pending
    }
  }
}
