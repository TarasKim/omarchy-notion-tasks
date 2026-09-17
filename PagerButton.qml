import QtQuick
import qs.Commons
import qs.Ui

// Chevron for the popup pager. Small enough that the hit area is padded out
// beyond the glyph, otherwise it is a two-pixel click target.
Text {
  id: pager

  property string glyph: "›"
  property bool stepEnabled: true
  property color foreground: Color.foreground
  property color dim: Qt.darker(foreground, 1.55)
  property string fontFamily: Style.font.family

  signal triggered()

  // The glyph is a literal, but this is a Text sink like any other and the
  // default is AutoText; a component is not the place to leave that open.
  textFormat: Text.PlainText
  anchors.verticalCenter: parent ? parent.verticalCenter : undefined
  text: glyph
  color: stepEnabled ? (hit.containsMouse ? foreground : dim) : Qt.darker(dim, 1.4)
  font.family: fontFamily
  font.pixelSize: Style.font.subtitle

  MouseArea {
    id: hit
    anchors.fill: parent
    anchors.margins: -Style.spacing.md
    hoverEnabled: true
    enabled: pager.stepEnabled
    cursorShape: Qt.PointingHandCursor
    onClicked: pager.triggered()
  }
}
