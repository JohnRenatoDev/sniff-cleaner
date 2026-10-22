import QtQuick
import qs.Commons
import qs.Ui

// Settings written through `sniff config`; scheduling through `sniff
// schedule`, whose status comes from systemd rather than the saved flag.
Flickable {
  id: pane
  required property var panel
  readonly property var prefs: panel.prefs || ({})
  readonly property bool editing: projectField.activeFocus || exclusionField.activeFocus
  width: parent ? parent.width : 0
  height: Style.space(420)
  contentHeight: body.implicitHeight
  clip: true
  boundsBehavior: Flickable.StopAtBounds

  function list(key) { return pane.prefs[key] || [] }

  Column {
    id: body
    width: pane.width
    spacing: Style.spacing.rowGap

    PanelSectionHeader { text: pane.panel.tr("ui.categories") }
    Grid {
      width: parent.width
      columns: 2
      columnSpacing: Style.spacing.controlGap
      rowSpacing: Style.spacing.xs
      Repeater {
        model: (pane.panel.categories || []).filter(function(c) { return !c.inspectionOnly })
        // Compact rows: one line per category, two columns.
        delegate: Button {
          required property var modelData
          readonly property bool on: pane.list("enabledCategories").indexOf(modelData.id) >= 0
          width: (body.width - Style.spacing.controlGap) / 2
          leftAlign: true
          selected: on
          text: (on ? "[x] " : "[ ] ") + modelData.title + (modelData.automatic ? "" : " · " + pane.panel.tr("ui.manual_only"))
          Accessible.role: Accessible.CheckBox
          Accessible.checkable: true
          Accessible.checked: on
          onClicked: pane.panel.config([on ? "--disable" : "--enable", modelData.id])
        }
      }
    }

    PanelSectionHeader { text: pane.panel.tr("ui.retention", [pane.prefs.retentionDays || 14]) }
    Row {
      spacing: Style.spacing.controlGap
      Button { text: "−"; onClicked: pane.panel.config(["--retention-days", String(Math.max(1, (pane.prefs.retentionDays || 14) - 1))]) }
      Button { text: "+"; onClicked: pane.panel.config(["--retention-days", String((pane.prefs.retentionDays || 14) + 1)]) }
    }
    PanelSectionHeader { text: pane.panel.tr("ui.log_retention", [pane.prefs.logRetentionDays || 30]) }
    Row {
      spacing: Style.spacing.controlGap
      Button { text: "−"; onClicked: pane.panel.config(["--log-retention-days", String(Math.max(1, (pane.prefs.logRetentionDays || 30) - 1))]) }
      Button { text: "+"; onClicked: pane.panel.config(["--log-retention-days", String((pane.prefs.logRetentionDays || 30) + 1)]) }
    }

    PanelSectionHeader { text: pane.panel.tr("ui.projects") }
    Repeater {
      model: pane.list("projectRoots")
      delegate: Row {
        required property string modelData
        width: body.width
        spacing: Style.spacing.controlGap
        Label { width: parent.width - removeProject.width - Style.spacing.controlGap; wrapMode: Text.WrapAnywhere; text: modelData; anchors.verticalCenter: parent.verticalCenter }
        Button { id: removeProject; text: pane.panel.tr("ui.remove"); onClicked: pane.panel.config(["--remove-project", modelData]) }
      }
    }
    Label { visible: pane.list("projectRoots").length === 0; muted: true; text: pane.panel.tr("ui.none") }
    TextField {
      id: projectField
      width: parent.width
      placeholderText: pane.panel.tr("ui.path_placeholder")
      onAccepted: { if (text.trim() !== "") pane.panel.config(["--project", text.trim()]); text = ""; pane.panel.focusKeys() }
      Keys.onEscapePressed: pane.panel.focusKeys()
    }

    PanelSectionHeader { text: pane.panel.tr("ui.exclusions") }
    Repeater {
      model: pane.list("exclusions")
      delegate: Row {
        required property string modelData
        width: body.width
        spacing: Style.spacing.controlGap
        Label { width: parent.width - removeExclusion.width - Style.spacing.controlGap; wrapMode: Text.WrapAnywhere; text: modelData; anchors.verticalCenter: parent.verticalCenter }
        Button { id: removeExclusion; text: pane.panel.tr("ui.remove"); onClicked: pane.panel.config(["--remove-exclusion", modelData]) }
      }
    }
    Label { visible: pane.list("exclusions").length === 0; muted: true; text: pane.panel.tr("ui.none") }
    TextField {
      id: exclusionField
      width: parent.width
      placeholderText: pane.panel.tr("ui.path_placeholder")
      onAccepted: { if (text.trim() !== "") pane.panel.config(["--exclude", text.trim()]); text = ""; pane.panel.focusKeys() }
      Keys.onEscapePressed: pane.panel.focusKeys()
    }

    PanelSectionHeader { text: pane.panel.tr("ui.schedule") }
    Label {
      width: parent.width
      text: {
        var s = pane.panel.scheduleData
        if (!s) return ""
        var r = s.registration || {}
        var on = r.enabled && r.active
        var key = s.scheduleEnabled === on ? (on ? "cli.schedule_on" : "cli.schedule_off") : "cli.schedule_mismatch"
        return pane.panel.tr(key)
      }
    }
    Label {
      visible: !!(pane.panel.scheduleData && pane.panel.scheduleData.message)
      width: parent.width
      muted: true
      font.pixelSize: Style.font.caption
      text: pane.panel.scheduleData && pane.panel.scheduleData.message ? pane.panel.scheduleData.message : ""
    }
    Row {
      spacing: Style.spacing.controlGap
      Button { text: pane.panel.tr("ui.schedule_analyze"); enabled: !pane.panel.busy; onClicked: pane.panel.schedule(["enable", "--mode", "analyze"]) }
      Button { text: pane.panel.tr("ui.schedule_automatic"); enabled: !pane.panel.busy; onClicked: pane.panel.schedule(["enable", "--mode", "automatic"]) }
      Button { text: pane.panel.tr("ui.schedule_disable"); enabled: !pane.panel.busy; onClicked: pane.panel.schedule(["disable"]) }
    }
  }
}
