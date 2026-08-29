import QtQuick
import qs.Commons
import qs.Ui

// Status picker for one task. The vocabulary is whatever fetch.sh read off
// that task's board, so this component never needs to know that personal
// tasks finish as "Completed" and TK Digital ones as "Done".
//
// The panel owns the cursor (`choice`) so the shared PanelKeyCatcher can drive
// it with the same ↑↓ that walks the task list.
Column {
  id: form

  property var task: null
  property var options: []
  property int choice: 0
  property string currentStatus: ""
  property bool busy: false
  property string errorText: ""

  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property color dim: Qt.darker(foreground, 1.55)
  property string fontFamily: Style.font.family

  readonly property string chosen: choice >= 0 && choice < options.length
                                   ? String(options[choice]) : ""

  signal picked(int index)
  signal submitted()
  signal cancelled()

  spacing: Style.spacing.xl

  PanelSectionHeader {
    text: "CHANGE STATUS"
    foreground: form.foreground
    fontFamily: form.fontFamily
  }

  Text {
    width: parent.width
    text: form.task && form.task.name ? form.task.name : ""
    color: form.foreground
    font.family: form.fontFamily
    font.pixelSize: Style.font.body
    wrapMode: Text.WordWrap
    maximumLineCount: 2
    elide: Text.ElideRight
  }

  Text {
    width: parent.width
    text: "now  ·  " + (form.currentStatus !== "" ? form.currentStatus : "unset")
    color: form.dim
    font.family: form.fontFamily
    font.pixelSize: Style.font.caption
  }

  Column {
    width: parent.width
    spacing: Style.spacing.xxs

    Repeater {
      model: form.options

      Button {
        required property var modelData
        required property int index
        width: parent.width
        text: String(modelData)
        leftAlign: true
        bordered: true
        // `selected` is where the task is now; `hasCursor` is where the
        // keyboard is. They start together and part as soon as you move.
        selected: String(modelData) === form.currentStatus
        hasCursor: index === form.choice
        foreground: form.foreground
        fontFamily: form.fontFamily
        onClicked: { form.picked(index); form.submitted() }
      }
    }
  }

  Text {
    visible: form.errorText !== ""
    width: parent.width
    text: form.errorText
    color: form.urgent
    font.family: form.fontFamily
    font.pixelSize: Style.font.body
    wrapMode: Text.WordWrap
  }

  Text {
    width: parent.width
    text: form.busy
          ? "Saving…"
          : "↑↓ choose  ·  Enter apply  ·  Esc cancel  ·  d completes without opening this"
    color: form.dim
    font.family: form.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }
}
