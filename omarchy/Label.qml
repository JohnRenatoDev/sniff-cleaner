import QtQuick
import qs.Commons
import qs.Commons as Commons

// Text with the shell's font and popup colors.
Text {
  property bool muted: false
  color: muted ? Qt.darker(Commons.Color.popups.text, 1.5) : Commons.Color.popups.text
  font.family: Style.font.family
  font.pixelSize: Style.font.body
  wrapMode: Text.WordWrap
}
