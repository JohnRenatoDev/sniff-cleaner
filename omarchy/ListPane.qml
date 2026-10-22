import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Format.js" as Format

// Scan results: filters, search, selection and the entry to plan review.
Column {
  id: pane
  required property var panel
  property alias searchField: searchField
  property alias list: list
  spacing: Style.spacing.rowGap

  Row {
    spacing: Style.spacing.sm
    Repeater {
      model: pane.panel.filters
      delegate: Button {
        required property string modelData
        text: pane.panel.tr("ui.filter_" + modelData.replace("-", "_"))
        selected: pane.panel.filter === modelData
        onClicked: { pane.panel.filter = modelData; pane.panel.cursor = 0 }
      }
    }
  }

  TextField {
    id: searchField
    width: parent.width
    placeholderText: pane.panel.tr("ui.search")
    onTextChanged: { pane.panel.search = text; pane.panel.cursor = 0 }
    Keys.onEscapePressed: pane.panel.focusKeys()
    Keys.onReturnPressed: pane.panel.focusKeys()
  }

  ListView {
    id: list
    width: parent.width
    height: Style.space(300)
    clip: true
    model: pane.panel.items
    boundsBehavior: Flickable.StopAtBounds
    currentIndex: pane.panel.cursor
    spacing: Style.spacing.xs

    Label {
      anchors.centerIn: parent
      visible: list.count === 0
      muted: true
      text: pane.panel.scanData ? pane.panel.tr("ui.empty") : pane.panel.tr("ui.idle_hint")
    }

    delegate: Rectangle {
      id: row
      required property var modelData
      required property int index
      readonly property bool isCursor: index === pane.panel.cursor
      readonly property bool isSelected: pane.panel.selectionVersion >= 0 && pane.panel.selected[modelData.path] === true
      readonly property bool expanded: pane.panel.expandedPath === modelData.path
      readonly property bool canSelect: pane.panel.selectable(modelData)
      width: list.width
      height: rowColumn.implicitHeight + Style.spacing.md * 2
      color: isCursor ? Style.hoverFill : "transparent"
      radius: Style.cornerRadius

      Accessible.role: Accessible.CheckBox
      Accessible.name: modelData.title + ", " + modelData.stateTitle + ", " + modelData.path
      Accessible.checkable: canSelect
      Accessible.checked: isSelected

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: function(mouse) {
          pane.panel.cursor = row.index
          if (mouse.button === Qt.RightButton) pane.panel.expandedPath = row.expanded ? "" : row.modelData.path
          else pane.panel.toggleSelect(row.modelData)
        }
      }

      Column {
        id: rowColumn
        x: Style.spacing.md
        y: Style.spacing.md
        width: parent.width - Style.spacing.md * 2
        spacing: Style.spacing.xxs

        Row {
          width: parent.width
          spacing: Style.spacing.md
          Label {
            id: check
            wrapMode: Text.NoWrap
            text: !row.canSelect ? " · " : (row.isSelected ? "[x]" : "[ ]")
            muted: !row.canSelect
          }
          Label {
            width: parent.width - check.width - size.width - stateLabel.width - Style.spacing.md * 3
            wrapMode: Text.NoWrap
            elide: Text.ElideRight
            text: row.modelData.title
            font.bold: true
          }
          Label {
            id: size
            wrapMode: Text.NoWrap
            text: row.modelData.partialMeasurement
              ? pane.panel.tr("ui.partial_size", [pane.panel.bytes(row.modelData.allocatedBytes)])
              : pane.panel.bytes(row.modelData.allocatedBytes)
          }
          Label {
            id: stateLabel
            wrapMode: Text.NoWrap
            text: row.modelData.worktree ? row.modelData.worktree.statusTitle : row.modelData.stateTitle
            color: pane.panel.stateColor(row.modelData.state)
            font.pixelSize: Style.font.caption
          }
        }
        Label {
          width: parent.width
          wrapMode: Text.NoWrap
          elide: Text.ElideMiddle
          muted: true
          font.pixelSize: Style.font.caption
          text: row.modelData.path + (row.modelData.worktree && row.modelData.worktree.branch ? "  ·  " + row.modelData.worktree.branch : "")
        }
        Label {
          width: parent.width
          muted: true
          font.pixelSize: Style.font.caption
          text: row.modelData.reason
            + (row.modelData.state === "ready" && row.modelData.freeableBytes < row.modelData.allocatedBytes
               ? " · " + pane.panel.tr("ui.freeable", [pane.panel.bytes(row.modelData.freeableBytes)]) : "")
        }
        Column {
          visible: row.expanded
          width: parent.width
          spacing: Style.spacing.xxs
          Label {
            width: parent.width
            muted: true
            font.pixelSize: Style.font.caption
            text: pane.panel.tr("ui.measures", [pane.panel.bytes(row.modelData.logicalBytes), pane.panel.bytes(row.modelData.allocatedBytes)])
          }
          Repeater {
            model: row.expanded ? row.modelData.details : []
            delegate: Label {
              required property string modelData
              width: rowColumn.width
              muted: true
              font.pixelSize: Style.font.caption
              text: "· " + modelData
            }
          }
          Row {
            spacing: Style.spacing.controlGap
            Button {
              visible: row.modelData.path.indexOf("docker://") !== 0
              text: pane.panel.tr("ui.exclude")
              onClicked: pane.panel.config(["--exclude", row.modelData.path])
            }
            Button {
              visible: row.modelData.state === "ready" && !pane.panel.enabled(row.modelData.category)
              text: pane.panel.tr("ui.enable_category", [row.modelData.categoryTitle])
              onClicked: pane.panel.config(["--enable", row.modelData.category])
            }
          }
        }
      }
    }
  }

  Row {
    width: parent.width
    spacing: Style.spacing.controlGap
    Label {
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width - reviewButton.width - Style.spacing.controlGap
      text: pane.panel.tr("ui.selected", [String(pane.panel.selectedItems.length), pane.panel.bytes(pane.panel.selectedBytes)])
    }
    Button {
      id: reviewButton
      text: pane.panel.tr("ui.review")
      enabled: !pane.panel.busy && pane.panel.selectedItems.length > 0
      onClicked: pane.panel.review()
    }
  }
}
