import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Sniff panel: scan, review, select, plan, confirm and clean. Every decision
// is made by the `sniff` binary (Rust core); this file only presents its JSON
// and passes the user's explicit choices back as argv.
Panel {
  id: root
  moduleName: "io.github.johnrenatodev.sniff"
  ipcTarget: "io.github.johnrenatodev.sniff"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // Settings from the widget's shell.json entry.
  readonly property string binary: String(setting("sniffBinary", "sniff") || "sniff")
  readonly property string language: String(setting("language", "auto") || "auto")
  readonly property string motionSetting: String(setting("reduceMotion", "auto") || "auto")

  // Data from the CLI.
  property var strings: ({})
  property var scanData: null
  property var prefs: null
  property var planData: null
  property var resultData: null
  property string errorText: ""
  property string statusText: ""
  property bool binaryMissing: false

  // UI state.
  property string view: "list"          // list | review | result
  property string busyKind: ""          // scan | plan | clean | ""
  readonly property bool busy: busyKind !== ""
  property string filter: "all"
  property string search: ""
  property var selected: ({})
  property int selectionVersion: 0
  property int cursor: 0
  property string expandedPath: ""
  property bool hyprAnimations: true
  readonly property bool reduceMotion: motionSetting === "on" || (motionSetting === "auto" && !hyprAnimations)

  readonly property var filters: ["all", "ready", "pending", "in-use", "preserved"]
  readonly property var items: {
    var _v = selectionVersion
    var list = scanData && scanData.items ? scanData.items : []
    var q = search.toLowerCase()
    return list.filter(function(it) {
      if (filter === "ready" && it.state !== "ready") return false
      if (filter === "pending" && !(it.worktree && it.worktree.pending)) return false
      if (filter === "in-use" && it.state !== "in_use") return false
      if (filter === "preserved" && ["protected", "review", "inaccessible"].indexOf(it.state) < 0) return false
      if (q !== "") {
        var branch = it.worktree && it.worktree.branch ? String(it.worktree.branch).toLowerCase() : ""
        if (String(it.path).toLowerCase().indexOf(q) < 0 && branch.indexOf(q) < 0) return false
      }
      return true
    })
  }
  readonly property var selectedItems: {
    var _v = selectionVersion
    var list = scanData && scanData.items ? scanData.items : []
    return list.filter(function(it) { return root.selected[it.path] === true })
  }
  readonly property real selectedBytes: {
    var sum = 0
    for (var i = 0; i < selectedItems.length; i++) sum += Number(selectedItems[i].allocatedBytes) || 0
    return sum
  }
  readonly property string barTooltip: busy ? tr("ui.sniffing") : tr("ui.tagline")

  function tr(key, args) {
    var s = strings[key] !== undefined ? String(strings[key]) : key
    if (args) for (var i = 0; i < args.length; i++) s = s.split("{" + i + "}").join(String(args[i]))
    return s
  }

  function bytes(n) {
    n = Number(n) || 0
    var units = ["B", "KB", "MB", "GB", "TB"]
    var u = 0
    while (n >= 1024 && u < units.length - 1) { n /= 1024; u++ }
    var s = u === 0 ? String(Math.round(n)) : (n >= 100 ? n.toFixed(0) : n.toFixed(1))
    var lang = strings["__lang"] || "en"
    if (lang !== "en") s = s.replace(".", ",")
    return s + " " + units[u]
  }

  function langArgs() {
    return language === "auto" ? [] : ["--language", language]
  }

  function enabled(category) {
    return prefs && prefs.enabledCategories ? prefs.enabledCategories.indexOf(category) >= 0 : false
  }

  function selectable(it) {
    return it && it.state === "ready" && enabled(it.category)
  }

  // --- lifecycle ------------------------------------------------------------

  function open() {
    root.controller.show()
    errorText = ""
    if (!stringsCall.running) stringsCall.start([binary, "strings", "--json"].concat(langArgs()))
    loadPrefs()
    if (!busy && view === "list") listCall.start([binary, "list", "--json"].concat(langArgs()))
    hyprCall.running = true
  }

  function close() { root.controller.hide() }
  function toggle() { if (root.opened) root.close(); else root.open() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function") return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function loadPrefs() {
    if (!configCall.running) configCall.start([binary, "config", "--json"].concat(langArgs()))
  }

  // --- actions --------------------------------------------------------------

  function scan(mode) {
    if (busy) return
    errorText = ""
    statusText = tr("ui.sniffing")
    var argv = [binary, "scan", "--json", "--progress"]
    if (mode === "quick") argv.push("--quick")
    if (mode === "worktrees") argv.push("--worktrees")
    busyKind = "scan"
    selected = ({})
    selectionVersion++
    if (!scanCall.start(argv.concat(langArgs()))) busyKind = ""
  }

  function toggleSelect(it) {
    if (!selectable(it)) return
    var s = selected
    if (s[it.path]) delete s[it.path]; else s[it.path] = true
    selected = s
    selectionVersion++
  }

  function review() {
    if (busy || selectedItems.length === 0) return
    var argv = [binary, "plan", "--json", "--save"]
    for (var i = 0; i < selectedItems.length; i++) argv.push("--path", selectedItems[i].path)
    errorText = ""
    busyKind = "plan"
    if (!planCall.start(argv.concat(langArgs()))) busyKind = ""
  }

  function confirmClean() {
    if (busy || !planData || !planData.planFile) return
    busyKind = "clean"
    statusText = tr("ui.cleaning")
    if (!cleanCall.start([binary, "clean", "--plan", planData.planFile, "--yes", "--json"].concat(langArgs()))) busyKind = ""
  }

  function exclude(path) {
    if (busy) return
    excludeCall.start([binary, "config", "--exclude", path, "--json"].concat(langArgs()))
  }

  function enableCategory(category) {
    if (busy) return
    excludeCall.start([binary, "config", "--enable", category, "--json"].concat(langArgs()))
  }

  function cycleFilter() {
    filter = filters[(filters.indexOf(filter) + 1) % filters.length]
    cursor = 0
  }

  function failMessage(code, data) {
    if (code === 127 || code === -1) { binaryMissing = true; return tr("ui.binary_missing") }
    if (data && data.error) return String(data.error)
    return tr("ui.error", [String(code)])
  }

  // --- CLI calls --------------------------------------------------------------

  CliCall {
    id: stringsCall
    onFinished: function(code, data) {
      if (code === 0 && data && data.strings) {
        var s = data.strings
        s["__lang"] = data.language
        root.strings = s
        root.binaryMissing = false
      } else if (code === 127) {
        root.binaryMissing = true
      }
    }
  }

  CliCall {
    id: configCall
    onFinished: function(code, data) { if (code === 0 && data) root.prefs = data }
  }

  CliCall {
    id: listCall
    onFinished: function(code, data) {
      if (code === 0 && data) root.scanData = data
      else if (code === 127) root.binaryMissing = true
    }
  }

  CliCall {
    id: scanCall
    onProgress: function(text) { root.statusText = text }
    onFinished: function(code, data) {
      root.busyKind = ""
      root.statusText = ""
      if (code === 0 && data) { root.scanData = data; root.cursor = 0 }
      else root.errorText = root.failMessage(code, data)
    }
  }

  CliCall {
    id: planCall
    onFinished: function(code, data) {
      root.busyKind = ""
      if (code === 0 && data && data.planFile) { root.planData = data; root.view = "review" }
      else root.errorText = root.failMessage(code, data)
    }
  }

  CliCall {
    id: cleanCall
    onFinished: function(code, data) {
      root.busyKind = ""
      root.statusText = ""
      if ((code === 0 || code === 4) && data && data.outcomes) {
        root.resultData = data
        root.view = "result"
        root.selected = ({})
        root.selectionVersion++
        listCall.start([root.binary, "list", "--json"].concat(root.langArgs()))
      } else {
        root.errorText = root.failMessage(code, data)
        root.view = "list"
      }
    }
  }

  CliCall {
    id: excludeCall
    onFinished: function(code, data) {
      if (code === 0 && data) { root.prefs = data; root.statusText = root.tr("ui.excluded") }
      else root.errorText = root.failMessage(code, data)
    }
  }

  // Hyprland's global animation switch doubles as the reduce-motion signal.
  Process {
    id: hyprCall
    command: ["hyprctl", "-j", "getoption", "animations:enabled"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.hyprAnimations = JSON.parse(String(text || "{}")).int !== 0 } catch (e) {}
      }
    }
  }

  // --- view -----------------------------------------------------------------

  readonly property color fg: Commons.Color.popups.text
  readonly property color dim: Qt.darker(fg, 1.5)
  readonly property color accentColor: Commons.Color.accent
  readonly property color urgentColor: Commons.Color.urgent

  function stateColor(state) {
    if (state === "ready") return accentColor
    if (state === "in_use" || state === "inaccessible") return urgentColor
    return dim
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(620))
    contentHeight: panel.fittedContentHeight(Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: searchField.activeFocus
      property bool enterPressed: false
      onCloseRequested: {
        if (root.view !== "list" && !root.busy) root.view = "list"
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (root.view !== "list") return
        if (dx !== 0) { root.cycleFilter(); return }
        root.cursor = Math.max(0, Math.min(root.items.length - 1, root.cursor + dy))
        list.positionViewAtIndex(root.cursor, ListView.Contain)
      }
      onReturnRequested: enterPressed = true
      onActivateRequested: {
        var wasEnter = enterPressed
        enterPressed = false
        if (root.view === "review") { if (wasEnter) root.confirmClean(); return }
        if (root.view === "result") { root.view = "list"; return }
        var it = root.items[root.cursor]
        if (!it) return
        if (wasEnter) root.expandedPath = root.expandedPath === it.path ? "" : it.path
        else root.toggleSelect(it)
      }
      onTextKey: function(t) {
        if (root.view !== "list") return
        if (t === "r") root.scan("quick")
        else if (t === "R") root.scan("full")
        else if (t === "w") root.scan("worktrees")
        else if (t === "f") root.cycleFilter()
        else if (t === "/") searchField.forceActiveFocus()
        else if (t === "p") root.review()
      }

      Column {
        id: content
        anchors.fill: parent
        spacing: Style.spacing.rowGap

        // Header: the dog moves only while the CLI is working.
        Row {
          width: parent.width
          spacing: Style.spacing.panelGap
          SniffDog {
            width: Style.space(96)
            height: Style.space(59)
            ink: root.fg
            active: root.busy
            reduceMotion: root.reduceMotion
          }
          Column {
            width: parent.width - Style.space(96) - Style.spacing.panelGap
            spacing: Style.spacing.xs
            Text {
              text: root.tr("ui.title")
              color: root.fg
              font.family: Style.font.family
              font.pixelSize: Style.font.heading
              font.bold: true
            }
            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              color: root.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              text: root.binaryMissing ? root.tr("ui.binary_missing")
                : root.busy ? (root.statusText || root.tr("ui.sniffing"))
                : root.errorText !== "" ? root.errorText
                : root.statusText !== "" ? root.statusText
                : root.scanData ? root.tr("ui.last_scan", [String(root.scanData.scannedAt).replace("T", " ").replace("Z", " UTC")])
                : root.tr("ui.idle_hint")
            }
            Row {
              spacing: Style.spacing.controlGap
              visible: root.view === "list"
              Button { text: root.tr("ui.scan_quick"); enabled: !root.busy; onClicked: root.scan("quick") }
              Button { text: root.tr("ui.scan_full"); enabled: !root.busy; onClicked: root.scan("full") }
              Button { text: root.tr("ui.scan_worktrees"); enabled: !root.busy; onClicked: root.scan("worktrees") }
            }
          }
        }

        PanelSeparator { width: parent.width; foreground: root.fg }

        // --- list view ---
        Column {
          width: parent.width
          spacing: Style.spacing.rowGap
          visible: root.view === "list"

          Row {
            spacing: Style.spacing.sm
            Repeater {
              model: root.filters
              delegate: Button {
                required property string modelData
                text: root.tr("ui.filter_" + modelData.replace("-", "_"))
                selected: root.filter === modelData
                onClicked: { root.filter = modelData; root.cursor = 0 }
              }
            }
          }

          TextField {
            id: searchField
            width: parent.width
            placeholderText: root.tr("ui.search")
            onTextChanged: { root.search = text; root.cursor = 0 }
            Keys.onEscapePressed: keyCatcher.forceActiveFocus()
            Keys.onReturnPressed: keyCatcher.forceActiveFocus()
          }

          ListView {
            id: list
            width: parent.width
            height: Style.space(300)
            clip: true
            model: root.items
            boundsBehavior: Flickable.StopAtBounds
            currentIndex: root.cursor
            spacing: Style.spacing.xs

            Text {
              anchors.centerIn: parent
              visible: list.count === 0
              color: root.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              text: root.scanData ? root.tr("ui.empty") : root.tr("ui.idle_hint")
            }

            delegate: Rectangle {
              id: row
              required property var modelData
              required property int index
              readonly property bool isCursor: index === root.cursor
              readonly property bool isSelected: root.selectionVersion >= 0 && root.selected[modelData.path] === true
              readonly property bool expanded: root.expandedPath === modelData.path
              width: list.width
              height: rowColumn.implicitHeight + Style.spacing.md * 2
              color: isCursor ? Style.hoverFill : "transparent"
              radius: Style.cornerRadius

              Accessible.role: Accessible.CheckBox
              Accessible.name: modelData.title + ", " + modelData.stateTitle + ", " + modelData.path
              Accessible.checkable: root.selectable(modelData)
              Accessible.checked: isSelected

              MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: function(mouse) {
                  root.cursor = row.index
                  if (mouse.button === Qt.RightButton) root.expandedPath = row.expanded ? "" : row.modelData.path
                  else root.toggleSelect(row.modelData)
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
                  Text {
                    id: check
                    text: !root.selectable(row.modelData) ? "·" : (row.isSelected ? "[x]" : "[ ]")
                    color: root.selectable(row.modelData) ? root.fg : root.dim
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    width: parent.width - check.width - size.width - stateLabel.width - Style.spacing.md * 3
                    elide: Text.ElideRight
                    text: row.modelData.title
                    color: root.fg
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }
                  Text {
                    id: size
                    text: row.modelData.partialMeasurement ? root.tr("ui.partial_size", [root.bytes(row.modelData.allocatedBytes)]) : root.bytes(row.modelData.allocatedBytes)
                    color: root.fg
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    id: stateLabel
                    text: row.modelData.worktree ? row.modelData.worktree.statusTitle : row.modelData.stateTitle
                    color: root.stateColor(row.modelData.state)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }
                Text {
                  width: parent.width
                  elide: Text.ElideMiddle
                  text: row.modelData.path + (row.modelData.worktree && row.modelData.worktree.branch ? "  ·  " + row.modelData.worktree.branch : "")
                  color: root.dim
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                Text {
                  width: parent.width
                  wrapMode: Text.WordWrap
                  text: row.modelData.reason
                  color: root.dim
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                Column {
                  visible: row.expanded
                  width: parent.width
                  spacing: Style.spacing.xxs
                  Text {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    color: root.dim
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    text: root.tr("ui.measures", [root.bytes(row.modelData.logicalBytes), root.bytes(row.modelData.allocatedBytes)])
                  }
                  Repeater {
                    model: row.expanded ? row.modelData.details : []
                    delegate: Text {
                      required property string modelData
                      width: rowColumn.width
                      wrapMode: Text.WordWrap
                      text: "· " + modelData
                      color: root.dim
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }
                  }
                  Row {
                    spacing: Style.spacing.controlGap
                    Button {
                      visible: row.modelData.path.indexOf("docker://") !== 0
                      text: root.tr("ui.exclude")
                      onClicked: root.exclude(row.modelData.path)
                    }
                    Button {
                      visible: row.modelData.state === "ready" && !root.enabled(row.modelData.category) && row.modelData.category !== "docker"
                      text: root.tr("ui.enable_category", [row.modelData.categoryTitle])
                      onClicked: root.enableCategory(row.modelData.category)
                    }
                  }
                }
              }
            }
          }

          Row {
            width: parent.width
            spacing: Style.spacing.controlGap
            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - reviewButton.width - Style.spacing.controlGap
              text: root.tr("ui.selected", [String(root.selectedItems.length), root.bytes(root.selectedBytes)])
              color: root.fg
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
            Button {
              id: reviewButton
              text: root.tr("ui.review")
              enabled: !root.busy && root.selectedItems.length > 0
              onClicked: root.review()
            }
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.tr("ui.keys")
            color: root.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        // --- review view ---
        Column {
          width: parent.width
          spacing: Style.spacing.rowGap
          visible: root.view === "review"

          Text {
            text: root.tr("ui.review_title")
            color: root.fg
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
          }
          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.tr("ui.review_body")
            color: root.fg
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
          Text {
            text: root.planData ? root.tr("ui.expires", [String(root.planData.expiresAt).replace("T", " ").replace("Z", " UTC")]) : ""
            color: root.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          ListView {
            width: parent.width
            height: Style.space(260)
            clip: true
            model: root.planData ? root.planData.items : []
            delegate: Column {
              required property var modelData
              width: ListView.view.width
              bottomPadding: Style.spacing.sm
              Text {
                width: parent.width
                wrapMode: Text.WrapAnywhere
                text: root.bytes(modelData.allocatedBytes) + "  " + modelData.path
                color: root.fg
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }
              Text {
                visible: modelData.category === "worktree"
                width: parent.width
                wrapMode: Text.WordWrap
                text: root.tr("detail.no_backup")
                color: root.urgentColor
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }
          Row {
            spacing: Style.spacing.controlGap
            Button { text: root.tr("ui.cancel"); enabled: !root.busy; onClicked: root.view = "list" }
            Button {
              text: root.busy ? root.tr("ui.cleaning") : root.tr("ui.confirm")
              enabled: !root.busy
              foreground: root.urgentColor
              onClicked: root.confirmClean()
            }
          }
        }

        // --- result view ---
        Column {
          width: parent.width
          spacing: Style.spacing.rowGap
          visible: root.view === "result"

          Text {
            text: root.tr("ui.result")
            color: root.fg
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
          }
          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            color: root.fg
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            text: {
              if (!root.resultData) return ""
              var net = root.resultData.netFreeSpaceChange
              var measured = net === null || net === undefined ? "—" : ((net >= 0 ? "+" : "−") + root.bytes(Math.abs(net)))
              return root.tr("ui.result_summary", [root.bytes(root.resultData.estimatedFreedBytes), measured])
            }
          }
          ListView {
            width: parent.width
            height: Style.space(280)
            clip: true
            model: root.resultData ? root.resultData.outcomes : []
            delegate: Column {
              required property var modelData
              width: ListView.view.width
              bottomPadding: Style.spacing.sm
              Text {
                width: parent.width
                wrapMode: Text.WrapAnywhere
                text: (modelData.removed ? "✓ " : (modelData.partiallyRemoved ? "◐ " : "• ")) + modelData.path
                color: modelData.removed ? root.fg : root.urgentColor
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }
              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: modelData.message
                color: root.dim
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }
          Button { text: root.tr("ui.done"); onClicked: root.view = "list" }
        }
      }
    }
  }
}
