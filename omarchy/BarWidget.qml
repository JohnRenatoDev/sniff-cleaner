import QtQuick
import qs.Commons
import qs.Ui

// Bar entry point. The popup lives in Panel.qml; this item owns the bar slot
// and forwards the open/close contract the bar and `omarchy-shell shell
// summon` expect.
BarWidget {
  id: root
  moduleName: "io.github.johnrenatodev.sniff"

  readonly property var panelItem: panelLoader.item
  readonly property bool opened: panelItem ? panelItem.opened === true : false
  readonly property bool popoutSwitchClosing: panelItem ? panelItem.popoutSwitchClosing === true : false

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function open() { if (panelItem) panelItem.open() }
  function close() { if (panelItem) panelItem.close() }
  function toggle() { if (panelItem) panelItem.toggle() }
  function closeForPopoutSwitch() { if (panelItem) panelItem.closeForPopoutSwitch() }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Nerd Font "dog" (nf-md-dog).
    text: "\uDB82\uDE43"
    slotSize: Style.bar.statusSlot
    active: root.panelItem ? root.panelItem.busy === true : false
    useActiveColor: false
    tooltipText: root.panelItem ? root.panelItem.barTooltip : "Sniff"

    onPressed: function(b) {
      if (b === Qt.MiddleButton) { if (root.panelItem) root.panelItem.scan("quick") }
      else root.toggle()
    }
  }
}
