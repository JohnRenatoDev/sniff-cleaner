import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Format.js" as Format

// Sniff panel controller: state, CLI calls and keyboard. Every decision is
// made by the `sniff` binary (Rust core); the panes only present its JSON
// and pass the user's explicit choices back as argv.
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
  property string lang: "en"
  property var scanData: null
  property var prefs: null
  property var categories: []
  property var planData: null
  property var resultData: null
  property var historyData: []
  property var scheduleData: null
  property string errorText: ""
  property string statusText: ""
  property bool binaryMissing: false

  // UI state.
  property string tab: "cleanup"        // cleanup | history | settings
  property string view: "list"          // list | review | result (cleanup tab)
  property string busyKind: ""          // scan | plan | clean | config | schedule
  readonly property bool busy: busyKind !== ""
  readonly property bool working: busyKind === "scan" || busyKind === "plan" || busyKind === "clean"
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
  // Space expected to be freed: shared (hardlinked) blocks are not counted.
  readonly property real selectedBytes: {
    var sum = 0
    for (var i = 0; i < selectedItems.length; i++) sum += Number(selectedItems[i].freeableBytes) || 0
    return sum
  }
  readonly property string barTooltip: working ? tr("ui.sniffing") : tr("ui.tagline")

  function tr(key, args) { return Format.fill(strings[key] !== undefined ? strings[key] : key, args) }
  function bytes(n) { return Format.bytes(n, lang) }
  function signedBytes(n) { return Format.signedBytes(n, lang) }
  function time(iso) { return Format.localTime(iso, lang) }
  function langArgs() { return language === "auto" ? [] : ["--language", language] }
  function enabled(category) { return prefs && prefs.enabledCategories ? prefs.enabledCategories.indexOf(category) >= 0 : false }
  function selectable(it) { return it && it.state === "ready" && enabled(it.category) }
  function focusKeys() { keyCatcher.forceActiveFocus() }

  readonly property color fg: Commons.Color.popups.text
  readonly property color dim: Qt.darker(fg, 1.5)
  readonly property color accentColor: Commons.Color.accent
  readonly property color urgentColor: Commons.Color.urgent

  function stateColor(state) {
    if (state === "ready") return accentColor
    if (state === "in_use" || state === "inaccessible") return urgentColor
    return dim
  }

  // --- lifecycle ------------------------------------------------------------

  function open() {
    root.controller.show()
    errorText = ""
    run(stringsCall, ["strings", "--json"])
    run(categoriesCall, ["categories", "--json"])
    refreshPrefs()
    if (!working && view === "list") run(listCall, ["list", "--json"])
    if (tab === "history") run(historyCall, ["history", "--json"])
    if (tab === "settings") run(scheduleStatusCall, ["schedule", "status", "--json"])
    hyprCall.running = true
  }

  function close() { root.controller.hide() }
  function toggle() { if (root.opened) root.close(); else root.open() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function") return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function run(call, args) { return call.start([binary].concat(args).concat(langArgs())) }
  function refreshPrefs() { run(configCall, ["config", "--json"]) }

  function showTab(name) {
    tab = name
    if (name === "history") run(historyCall, ["history", "--json"])
    if (name === "settings") { refreshPrefs(); run(scheduleStatusCall, ["schedule", "status", "--json"]) }
  }

  // --- actions --------------------------------------------------------------

  function scan(mode) {
    if (busy) return
    errorText = ""
    statusText = tr("ui.sniffing")
    var args = ["scan", "--json", "--progress"]
    if (mode === "quick") args.push("--quick")
    if (mode === "worktrees") args.push("--worktrees")
    busyKind = "scan"
    tab = "cleanup"
    view = "list"
    selected = ({})
    selectionVersion++
    if (!run(scanCall, args)) busyKind = ""
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
    var args = ["plan", "--json", "--save"]
    for (var i = 0; i < selectedItems.length; i++) args.push("--path", selectedItems[i].path)
    errorText = ""
    busyKind = "plan"
    if (!run(planCall, args)) busyKind = ""
  }

  function confirmClean() {
    if (busy || !planData || !planData.planFile) return
    busyKind = "clean"
    statusText = tr("ui.cleaning")
    if (!run(cleanCall, ["clean", "--plan", planData.planFile, "--yes", "--json"])) busyKind = ""
  }

  property bool lastConfigExcluded: false
  function config(args) {
    if (busy) return
    busyKind = "config"
    lastConfigExcluded = args.indexOf("--exclude") >= 0
    if (!run(configChangeCall, ["config"].concat(args).concat(["--json"]))) busyKind = ""
  }

  function schedule(args) {
    if (busy) return
    busyKind = "schedule"
    if (!run(scheduleCall, ["schedule"].concat(args).concat(["--json"]))) busyKind = ""
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

  // --- CLI calls ------------------------------------------------------------

  CliCall {
    id: stringsCall
    onFinished: function(code, data) {
      if (code === 0 && data && data.strings) {
        root.strings = data.strings
        root.lang = data.language || "en"
        root.binaryMissing = false
      } else if (code === 127) {
        root.binaryMissing = true
      }
    }
  }
  CliCall { id: categoriesCall; onFinished: function(code, data) { if (code === 0 && data) root.categories = data.categories } }
  CliCall { id: configCall; onFinished: function(code, data) { if (code === 0 && data) root.prefs = data } }
  CliCall { id: historyCall; onFinished: function(code, data) { if (code === 0 && data) root.historyData = data } }
  CliCall { id: scheduleStatusCall; onFinished: function(code, data) { if (code === 0 && data) root.scheduleData = data } }
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
        root.run(listCall, ["list", "--json"])
      } else {
        root.errorText = root.failMessage(code, data)
        root.view = "list"
      }
    }
  }
  CliCall {
    id: configChangeCall
    onFinished: function(code, data) {
      root.busyKind = ""
      if (code === 0 && data) { root.prefs = data; root.statusText = root.lastConfigExcluded ? root.tr("ui.excluded") : "" }
      else root.errorText = root.failMessage(code, data)
    }
  }
  CliCall {
    id: scheduleCall
    onFinished: function(code, data) {
      root.busyKind = ""
      if (code === 0 && data) root.scheduleData = data
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

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(640))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: listPane.searchField.activeFocus || settingsPane.editing
      property bool enterPressed: false
      onCloseRequested: {
        if (root.tab === "cleanup" && root.view !== "list" && !root.busy) root.view = "list"
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (root.tab === "settings") {
          settingsPane.contentY = Math.max(0, Math.min(settingsPane.contentHeight - settingsPane.height, settingsPane.contentY + dy * Style.space(40)))
          return
        }
        if (root.tab !== "cleanup" || root.view !== "list") return
        if (dx !== 0) { root.cycleFilter(); return }
        root.cursor = Math.max(0, Math.min(root.items.length - 1, root.cursor + dy))
        listPane.list.positionViewAtIndex(root.cursor, ListView.Contain)
      }
      onReturnRequested: enterPressed = true
      onActivateRequested: {
        var wasEnter = enterPressed
        enterPressed = false
        if (root.tab !== "cleanup") return
        if (root.view === "review") { if (wasEnter) root.confirmClean(); return }
        if (root.view === "result") { root.view = "list"; return }
        var it = root.items[root.cursor]
        if (!it) return
        if (wasEnter) root.expandedPath = root.expandedPath === it.path ? "" : it.path
        else root.toggleSelect(it)
      }
      onTextKey: function(t) {
        if (t === "1") root.showTab("cleanup")
        else if (t === "2") root.showTab("history")
        else if (t === "3") root.showTab("settings")
        if (root.tab !== "cleanup" || root.view !== "list") return
        if (t === "r") root.scan("quick")
        else if (t === "R") root.scan("full")
        else if (t === "w") root.scan("worktrees")
        else if (t === "f") root.cycleFilter()
        else if (t === "/") listPane.searchField.forceActiveFocus()
        else if (t === "p") root.review()
      }

      Column {
        id: content
        width: parent.width
        spacing: Style.spacing.rowGap

        // Header: the dog moves only while a scan, plan or cleanup runs.
        Row {
          width: parent.width
          spacing: Style.spacing.panelGap
          SniffDog {
            width: Style.space(96)
            height: Style.space(59)
            ink: root.fg
            active: root.working
            reduceMotion: root.reduceMotion
          }
          Column {
            width: parent.width - Style.space(96) - Style.spacing.panelGap
            spacing: Style.spacing.xs
            Label { text: root.tr("ui.title"); font.pixelSize: Style.font.heading; font.bold: true }
            Label {
              width: parent.width
              muted: true
              font.pixelSize: Style.font.bodySmall
              text: root.binaryMissing ? root.tr("ui.binary_missing")
                : root.working ? (root.statusText || root.tr("ui.sniffing"))
                : root.errorText !== "" ? root.errorText
                : root.statusText !== "" ? root.statusText
                : root.scanData ? root.tr("ui.last_scan", [root.time(root.scanData.scannedAt)])
                : root.tr("ui.idle_hint")
            }
            Row {
              spacing: Style.spacing.controlGap
              Button { text: root.tr("ui.scan_quick"); enabled: !root.busy; onClicked: root.scan("quick") }
              Button { text: root.tr("ui.scan_full"); enabled: !root.busy; onClicked: root.scan("full") }
              Button { text: root.tr("ui.scan_worktrees"); enabled: !root.busy; onClicked: root.scan("worktrees") }
            }
          }
        }

        Row {
          spacing: Style.spacing.sm
          Repeater {
            model: ["cleanup", "history", "settings"]
            delegate: Button {
              required property string modelData
              text: root.tr("ui.tab_" + modelData)
              selected: root.tab === modelData
              onClicked: root.showTab(modelData)
            }
          }
        }

        PanelSeparator { width: parent.width; foreground: root.fg }

        ListPane { id: listPane; panel: root; width: parent.width; visible: root.tab === "cleanup" && root.view === "list" }
        ReviewPane { panel: root; width: parent.width; visible: root.tab === "cleanup" && root.view === "review" }
        ResultPane { panel: root; width: parent.width; visible: root.tab === "cleanup" && root.view === "result" }
        HistoryPane { panel: root; width: parent.width; visible: root.tab === "history" }
        SettingsPane { id: settingsPane; panel: root; width: parent.width; visible: root.tab === "settings" }

        Label {
          width: parent.width
          muted: true
          font.pixelSize: Style.font.caption
          text: root.tr("ui.keys")
        }
      }
    }
  }
}
