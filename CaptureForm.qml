import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Quick-capture form. Destination first, because it decides which fields even
// apply — and *what* those fields are is read from the target board's schema,
// not written down here. A board with a Service select and a Clients relation
// grows two dropdowns; a bare personal list grows none.
Column {
  id: form

  property var sources: []
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property color dim: Qt.darker(foreground, 1.55)
  property string fontFamily: Style.font.family
  property bool busy: false
  property string errorText: ""

  property string dest: ""
  property string titleText: ""
  property string priorityLabel: "no priority"
  property string dueText: ""
  // Keyed by property name. Reassigned wholesale on every change: QML does not
  // watch the inside of a plain JS object.
  property var selectValues: ({})
  property var relationValues: ({})

  readonly property var targets: Model.captureTargets(sources)
  readonly property var selectFields: Model.selectFields(sources, dest)
  readonly property var relationFields: Model.relationFields(sources, dest)
  readonly property bool canSubmit: titleText.trim() !== "" && dest !== "" && !busy

  signal submitted()
  signal cancelled()

  // Default to the first configured board, and recover if the configuration
  // changes underneath an open form.
  function ensureDest() {
    if (targets.length === 0) { dest = ""; return }
    for (var i = 0; i < targets.length; i++) if (targets[i].key === dest) return
    dest = targets[0].key
  }

  onSourcesChanged: ensureDest()
  Component.onCompleted: ensureDest()

  // The vocabulary changes with the destination, so nothing chosen for one
  // board may survive a switch to another.
  onDestChanged: {
    priorityLabel = "no priority"
    selectValues = ({})
    relationValues = ({})
  }

  function setSelectValue(name, value) {
    var next = {}
    for (var k in selectValues) next[k] = selectValues[k]
    next[name] = value
    selectValues = next
  }

  function setRelationValue(name, value) {
    var next = {}
    for (var k in relationValues) next[k] = relationValues[k]
    next[name] = value
    relationValues = next
  }

  function reset() {
    titleText = ""
    dueText = ""
    priorityLabel = "no priority"
    selectValues = ({})
    relationValues = ({})
    errorText = ""
  }

  function focusTitle() { titleInput.forceActiveFocus() }

  // Extra fields travel as NAME=VALUE pairs rather than as named flags,
  // because which fields exist is only known at runtime.
  function extraArgs() {
    var out = []
    for (var i = 0; i < selectFields.length; i++) {
      var f = selectFields[i]
      var v = selectValues[f.name]
      if (v !== undefined && v !== "" && v !== f.placeholder)
        out.push("--select", f.name + "=" + v)
    }
    for (var j = 0; j < relationFields.length; j++) {
      var r = relationFields[j]
      var chosen = relationValues[r.name]
      if (chosen === undefined || chosen === "" || chosen === "none") continue
      var id = Model.relationIdFor(r.rows, chosen)
      if (id !== "") out.push("--relation", r.name + "=" + id)
    }
    return out
  }

  spacing: Style.spacing.xl

  PanelSectionHeader {
    text: "NEW TASK"
    foreground: form.foreground
    fontFamily: form.fontFamily
  }

  TextField {
    id: titleInput
    width: parent.width
    text: form.titleText
    placeholderText: "What needs doing?"
    foreground: form.foreground
    font.family: form.fontFamily
    font.pixelSize: Style.font.body
    onTextChanged: form.titleText = text
    onAccepted: if (form.canSubmit) form.submitted()
  }

  Flow {
    width: parent.width
    spacing: Style.spacing.md

    Repeater {
      model: form.targets

      Button {
        required property var modelData
        text: modelData.label
        selected: form.dest === modelData.key
        bordered: true
        foreground: form.foreground
        fontFamily: form.fontFamily
        onClicked: form.dest = modelData.key
      }
    }
  }

  Dropdown {
    id: priorityPick
    visible: Model.priorityLabels(form.sources, form.dest).length > 1
    width: parent.width
    label: "Priority"
    fontFamily: form.fontFamily
    options: Model.priorityLabels(form.sources, form.dest)
    value: form.priorityLabel
    onChanged: function (v) { form.priorityLabel = v }
  }

  Repeater {
    model: form.selectFields

    Dropdown {
      required property var modelData
      width: form.width
      label: modelData.name
      fontFamily: form.fontFamily
      options: modelData.options
      value: form.selectValues[modelData.name] !== undefined
             ? form.selectValues[modelData.name] : modelData.placeholder
      onChanged: function (v) { form.setSelectValue(modelData.name, v) }
    }
  }

  Repeater {
    model: form.relationFields

    Dropdown {
      required property var modelData
      width: form.width
      label: modelData.name
      fontFamily: form.fontFamily
      options: Model.relationNames(modelData.rows)
      value: form.relationValues[modelData.name] !== undefined
             ? form.relationValues[modelData.name] : "none"
      onChanged: function (v) { form.setRelationValue(modelData.name, v) }
    }
  }

  TextField {
    id: dueInput
    width: parent.width
    text: form.dueText
    placeholderText: "Due — today, tomorrow, +3d, 2026-09-01 (optional)"
    foreground: form.foreground
    font.family: form.fontFamily
    // Same size as the title field above it. Two inputs in one form set at
    // two sizes reads as a mistake, not as a hierarchy.
    font.pixelSize: Style.font.body
    onTextChanged: form.dueText = text
    onAccepted: if (form.canSubmit) form.submitted()
  }

  Text {
    visible: form.errorText !== ""
    width: parent.width
    text: form.errorText
    color: form.urgent
    font.family: form.fontFamily
    // An error has to outrank the key hints below it, and one pixel of
    // difference does not do that.
    font.pixelSize: Style.font.body
    wrapMode: Text.WordWrap
  }

  Row {
    width: parent.width
    spacing: Style.spacing.md

    Button {
      text: form.busy ? "Creating…" : "Create task"
      bordered: true
      active: form.canSubmit
      foreground: form.foreground
      fontFamily: form.fontFamily
      onClicked: if (form.canSubmit) form.submitted()
    }

    Button {
      text: "Cancel"
      bordered: true
      foreground: form.dim
      fontFamily: form.fontFamily
      onClicked: form.cancelled()
    }
  }

  Text {
    width: parent.width
    text: {
      var label = ""
      for (var i = 0; i < form.targets.length; i++)
        if (form.targets[i].key === form.dest) label = form.targets[i].label
      return "Enter creates  ·  Esc cancels  ·  goes to " + (label !== "" ? label : "no project")
    }
    color: form.dim
    font.family: form.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }
}
