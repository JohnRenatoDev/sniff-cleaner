import QtQuick
import qs.Commons
import qs.Ui

// The saved plan, in full, before permanent removal.
Column {
  id: pane
  required property var panel
  spacing: Style.spacing.rowGap

  Label { text: pane.panel.tr("ui.review_title"); font.pixelSize: Style.font.title; font.bold: true }
  Label { width: parent.width; text: pane.panel.tr("ui.review_body") }
  Label {
    muted: true
    font.pixelSize: Style.font.caption
    text: pane.panel.planData ? pane.panel.tr("ui.expires", [pane.panel.time(pane.panel.planData.expiresAt)]) : ""
  }
  ListView {
    width: parent.width
    height: Style.space(260)
    clip: true
    model: pane.panel.planData ? pane.panel.planData.items : []
    delegate: Column {
      required property var modelData
      width: ListView.view.width
      bottomPadding: Style.spacing.sm
      Label {
        width: parent.width
        wrapMode: Text.WrapAnywhere
        text: pane.panel.bytes(modelData.allocatedBytes) + "  " + modelData.path
      }
      Label {
        visible: modelData.category === "worktree"
        width: parent.width
        color: pane.panel.urgentColor
        font.pixelSize: Style.font.caption
        text: pane.panel.tr("detail.no_backup")
      }
    }
  }
  Row {
    spacing: Style.spacing.controlGap
    Button { text: pane.panel.tr("ui.cancel"); enabled: !pane.panel.busy; onClicked: pane.panel.view = "list" }
    Button {
      text: pane.panel.busy ? pane.panel.tr("ui.cleaning") : pane.panel.tr("ui.confirm")
      enabled: !pane.panel.busy
      foreground: pane.panel.urgentColor
      onClicked: pane.panel.confirmClean()
    }
  }
}
