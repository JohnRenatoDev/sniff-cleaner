import QtQuick
import qs.Commons
import qs.Ui

// Past cleanups from `sniff history --json`, newest first.
Column {
  id: pane
  required property var panel
  spacing: Style.spacing.rowGap

  ListView {
    width: parent.width
    height: Style.space(420)
    clip: true
    spacing: Style.spacing.md
    model: pane.panel.historyData || []

    Label {
      anchors.centerIn: parent
      visible: parent.count === 0
      muted: true
      text: pane.panel.tr("cli.no_history")
    }

    delegate: Column {
      id: report
      required property var modelData
      readonly property int removedCount: modelData.outcomes.filter(function(o) { return o.removed }).length
      width: ListView.view.width
      spacing: Style.spacing.xxs
      Label {
        width: parent.width
        font.bold: true
        text: pane.panel.time(report.modelData.date) + (report.modelData.automatic ? "  · " + pane.panel.tr("ui.automatic_tag") : "")
      }
      Label {
        width: parent.width
        muted: true
        font.pixelSize: Style.font.caption
        text: pane.panel.tr("ui.history_row", [
          report.removedCount,
          report.modelData.outcomes.length - report.removedCount,
          pane.panel.bytes(report.modelData.estimatedFreedBytes),
          pane.panel.signedBytes(report.modelData.netFreeSpaceChange)])
      }
      Repeater {
        model: report.modelData.outcomes
        delegate: Label {
          required property var modelData
          width: report.width
          wrapMode: Text.NoWrap
          elide: Text.ElideMiddle
          muted: true
          font.pixelSize: Style.font.caption
          text: (modelData.removed ? "✓ " : (modelData.partiallyRemoved ? "◐ " : "• ")) + modelData.path
        }
      }
    }
  }
}
