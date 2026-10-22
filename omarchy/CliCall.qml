import QtQuick
import Quickshell.Io

// Runs one `sniff` command (argv only, never a shell) and reports its JSON.
// Exit and end-of-stream arrive in no guaranteed order, so the result is
// emitted once both are known.
Item {
  id: call

  property bool running: proc.running
  property int exitCode: -1
  property string output: ""
  property bool exited: false
  property bool streamDone: false

  signal finished(int code, var data)
  signal progress(string text)

  function start(argv) {
    if (proc.running) return false
    exited = false
    streamDone = false
    output = ""
    exitCode = -1
    proc.command = argv
    proc.running = true
    watchdog.restart()
    return true
  }

  // A missing executable never reports an exit; surface it as a failure.
  Timer {
    id: watchdog
    interval: 1500
    onTriggered: {
      if (!proc.running && !call.exited) {
        call.exited = true
        call.streamDone = true
        call.exitCode = 127
        call.maybeFinish()
      }
    }
  }

  function maybeFinish() {
    if (!exited || !streamDone) return
    var data = null
    try { data = JSON.parse(output) } catch (e) { data = null }
    call.finished(exitCode, data)
  }

  Process {
    id: proc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        call.output = String(text || "")
        call.streamDone = true
        call.maybeFinish()
      }
    }
    stderr: SplitParser {
      onRead: function(line) {
        try {
          var msg = JSON.parse(line)
          if (msg && msg.progress) call.progress(String(msg.progress))
        } catch (e) {}
      }
    }
    onExited: function(code) {
      call.exitCode = code
      call.exited = true
      call.maybeFinish()
    }
  }
}
