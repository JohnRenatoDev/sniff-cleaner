import QtQuick
import qs.Commons
import qs.Ui

// Outcome of one cleanup: estimate and measured free-space change apart.
Column {
  id: pane
  required property var panel
  readonly property var result: panel.resultData
  spacing: Style.spacing.rowGap

  Label { text: pane.panel.tr("ui.result"); font.pixelSize: Style.font.title; font.bold: true }
  Label {
    width: parent.width
    text: pane.result
      ? pane.panel.tr("ui.result_summary", [pane.panel.bytes(pane.result.estimatedFreedBytes), pane.panel.signedBytes(pane.result.netFreeSpaceChange)])
      : ""
  }
  ListView {
    width: parent.width
    height: Style.space(280)
    clip: true
    model: pane.result ? pane.result.outcomes : []
    delegate: Column {
      required property var modelData
      width: ListView.view.width
      bottomPadding: Style.spacing.sm
      Label {
        width: parent.width
        wrapMode: Text.WrapAnywhere
        text: (modelData.removed ? "✓ " : (modelData.partiallyRemoved ? "◐ " : "• ")) + modelData.path
        color: modelData.removed ? pane.panel.fg : pane.panel.urgentColor
      }
      Label { width: parent.width; muted: true; font.pixelSize: Style.font.caption; text: modelData.message }
    }
  }
  Button { text: pane.panel.tr("ui.done"); onClicked: pane.panel.view = "list" }
}
