import QtQuick
import Quickshell
import Quickshell.Io

// Owns the single `github daemon` process, which polls GitHub (GraphQL + REST
// traffic and notifications) and the Omarchy marketplace, keeps day-by-day
// history, builds the activity feed and sends desktop alerts. Bar widgets on
// every monitor share this state.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string cli: String(Qt.resolvedUrl("bin/github")).replace(/^file:\/\//, "")

  property var state: ({ status: "starting" })
  property string lastError: ""
  property int serial: 0

  readonly property bool running: daemon.running
  readonly property var config: state.config || ({})
  readonly property var user: state.user || ({})
  readonly property var contrib: state.contrib || ({})
  readonly property var totals: state.totals || ({})
  readonly property var repos: state.repos || []
  readonly property var activity: state.activity || []
  readonly property var inbox: state.inbox || ({})
  readonly property var notifications: (state.notifications || {}).items || []
  readonly property var market: state.market || []
  readonly property var marketTotals: state.marketTotals || ({})
  readonly property int unseen: state.unseen || 0

  function send(cmd, args) {
    if (!daemon.running) return false
    daemon.write(JSON.stringify(Object.assign({ cmd: cmd, id: ++serial }, args || {})) + "\n")
    return true
  }

  function setConfig(key, value) { var a = {}; a[key] = value; return send("config", a) }
  function openUrl(url) { return url ? send("open", { url: url }) : false }

  function handleLine(line) {
    var msg
    try { msg = JSON.parse(line) } catch (e) { return }
    if (msg.type === "state") {
      root.state = msg.state || {}
    } else if (msg.type === "result" && !msg.ok && msg.error) {
      root.lastError = msg.error
      clearError.restart()
    } else if (msg.type === "log" && msg.error) {
      console.warn("grivera.github:", msg.error)
    }
  }

  Process {
    id: daemon
    command: [root.cli, "daemon"]
    running: true
    stdinEnabled: true
    stdout: SplitParser { onRead: function(line) { root.handleLine(line) } }
    onRunningChanged: {
      if (running) return
      root.state = Object.assign({}, root.state, { status: "stopped" })
      restart.restart()
    }
  }

  Timer {
    id: restart
    interval: 10000
    onTriggered: daemon.running = true
  }

  Timer {
    id: clearError
    interval: 8000
    onTriggered: root.lastError = ""
  }
}
