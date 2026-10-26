import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Bar icon for the AULA F75 keyboard. This widget owns all the device state
// and the calls into bin/aula-f75; Panel.qml is a view on it.
//
// Left click opens the lighting panel, right click toggles the lighting off
// and back to the last effect, middle click pushes the theme accent to the
// keyboard, and the wheel nudges brightness.
BarWidget {
  id: root
  moduleName: "crucialjun.aula-f75"

  // ---- CLI. The vendor-free driver lives next to this file. It is run
  //      through the system interpreter on purpose: mise shims on PATH
  //      (which Omarchy installs) break "python3" for shell-spawned helpers.
  readonly property string cliPath: Model.localPath(Qt.resolvedUrl("bin/aula-f75"))
  readonly property var cliBase: ["/usr/bin/python3", cliPath, "--json", "--compact"]

  // ---- Settings (shell.json, editable from Setup > Plugins)
  readonly property bool hideWhenDisconnected: setting("hideWhenDisconnected", true) === true
  readonly property bool themeSync: setting("themeSync", false) === true
  readonly property bool showHiddenEffects: setting("showHiddenEffects", false) === true
  readonly property int pollSeconds: Math.max(2, parseInt(setting("pollSeconds", 10)) || 10)

  // ---- Device state
  property bool connected: false
  property string transport: ""
  property string devicePath: ""
  property var status: ({})
  // Caps/Num/Scroll lock, as the kernel reports the keyboard's own LEDs.
  property var locks: ({})
  property bool busy: false
  property string lastError: ""
  property bool permissionDenied: false
  property int lastEffect: 1
  property var queue: []
  property string _statusOut: ""
  property string _actionOut: ""
  property string _actionErr: ""
  property string _detectOut: ""

  readonly property string effectName: status && status.effect_name ? status.effect_name : ""
  readonly property bool lightingOff: status && status.effect === 0
  readonly property bool winLocked: status && status.winlock === true
  readonly property string osMode: status && status.os_mode ? String(status.os_mode) : ""
  readonly property bool locksAvailable: locks && locks.available === true
  readonly property bool locksWritable: locks && locks.writable === true
  readonly property bool shown: connected || !hideWhenDisconnected

  // ---- Commands -------------------------------------------------------
  function detect() {
    if (detectProc.running) return
    detectProc.command = root.cliBase.concat(["detect"])
    detectProc.running = true
  }

  function refresh() {
    if (!root.connected) { detect(); return }
    if (statusProc.running) return
    statusProc.command = root.cliBase.concat(["status"])
    statusProc.running = true
  }

  // Serialised: the keyboard answers one feature-report conversation at a
  // time, and two overlapping read-modify-writes would clobber each other.
  function run(args) {
    var q = root.queue.slice()
    q.push(args)
    root.queue = q
    pump()
  }

  function pump() {
    if (actionProc.running || root.queue.length === 0) return
    var q = root.queue.slice()
    var args = q.shift()
    root.queue = q
    root.busy = true
    actionProc.command = root.cliBase.concat(args)
    actionProc.running = true
  }

  function absorb(parsed, stderrText) {
    if (parsed && parsed.locks) root.locks = parsed.locks
    if (parsed && parsed.connected === false) {
      root.lastError = String(parsed.error || "device error")
      root.permissionDenied = /permission denied/i.test(root.lastError)
      if (/no AULA F75 found/i.test(root.lastError)) root.connected = false
      return
    }
    if (parsed && parsed.effect !== undefined) {
      root.status = parsed
      root.connected = true
      root.lastError = ""
      root.permissionDenied = false
      if (parsed.effect !== 0) root.lastEffect = parsed.effect
      return
    }
    if (stderrText && stderrText.trim() !== "") {
      root.lastError = stderrText.trim().split("\n").pop()
      root.permissionDenied = /permission denied/i.test(root.lastError)
    }
  }

  function setEffect(id) { run(["effect", String(id)]) }
  function setBrightness(level) { run(["brightness", String(Math.round(level))]) }
  function setSpeed(level) { run(["speed", String(Math.round(level))]) }
  function setColour(hex) { run(["colour", Model.hexColor(hex)]) }
  function setColorful(on) { run(["colorful", on ? "on" : "off"]) }
  function setSleep(minutes) { run(["sleep", String(minutes)]) }
  function setDebounce(level) { run(["debounce", String(level)]) }
  function applyTheme() { run(["theme", Model.hexColor(Commons.Color.accent)]) }
  function installUdev() { run(["udev"]) }
  function setMode(mode) { run(["mode", String(mode)]) }
  function toggleMode() { run(["mode", "toggle"]) }
  function setWinLock(on) { run(["winlock", on ? "on" : "off"]) }
  function toggleWinLock() { run(["winlock", "toggle"]) }
  function setLock(key, on) { run(["lock", String(key), on ? "on" : "off"]) }
  function toggleLock(key) { run(["lock", String(key), "toggle"]) }

  // Cheap sysfs read, no device I/O: safe to poll while the panel is open.
  function refreshLocks() {
    if (!root.connected || locksProc.running || actionProc.running) return
    locksProc.command = root.cliBase.concat(["locks"])
    locksProc.running = true
  }

  function toggleLighting() {
    if (!root.connected) return
    if (root.lightingOff) setEffect(root.lastEffect || 1)
    else setEffect(0)
  }

  function nudgeBrightness(delta) {
    if (!root.connected || !root.status || root.status.brightness === undefined) return
    var next = Math.max(0, Math.min(root.status.brightness_max || 9, root.status.brightness + delta))
    if (next !== root.status.brightness) setBrightness(next)
  }

  // ---- Theme sync -----------------------------------------------------
  Connections {
    target: Commons.Color
    function onAccentChanged() {
      if (root.themeSync && root.connected) root.applyTheme()
    }
  }
  onThemeSyncChanged: if (themeSync && connected) applyTheme()
  onConnectedChanged: {
    if (connected) {
      refresh()
      if (themeSync) applyTheme()
    } else {
      root.status = ({})
      root.locks = ({})
    }
  }

  // ---- Processes ------------------------------------------------------
  Process {
    id: detectProc
    running: false
    command: []
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root._detectOut = text }
    onExited: function(exitCode) {
      var parsed = Model.parseJson(root._detectOut)
      root._detectOut = ""
      if (!parsed) { root.lastError = "aula-f75 detect failed (python3 missing?)"; return }
      var was = root.connected
      var sel = parsed.selected
      root.connected = !!(parsed.connected && sel)
      root.transport = sel ? String(sel.transport) : ""
      root.devicePath = sel ? String(sel.path) : ""
      root.locks = parsed.locks || ({})
      if (root.connected && !was) root.refresh()
    }
  }

  Process {
    id: statusProc
    running: false
    command: []
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root._statusOut = text }
    onExited: function(exitCode) {
      root.absorb(Model.parseJson(root._statusOut), "")
      root._statusOut = ""
    }
  }

  Process {
    id: actionProc
    running: false
    command: []
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root._actionOut = text }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: root._actionErr = text }
    onExited: function(exitCode) {
      var parsed = Model.parseJson(root._actionOut)
      root.absorb(parsed, root._actionErr)
      root._actionOut = ""
      root._actionErr = ""
      root.busy = false
      if (root.queue.length > 0) root.pump()
      // No status came back (udev install, or a failure): read the board
      // again so the panel shows what it is really doing now.
      else if (!parsed || (parsed.effect === undefined && parsed.locks === undefined)) root.refresh()
    }
  }

  Process {
    id: locksProc
    running: false
    command: []
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root._locksOut = text }
    onExited: function(exitCode) {
      var parsed = Model.parseJson(root._locksOut)
      root._locksOut = ""
      if (parsed && parsed.locks) root.locks = parsed.locks
    }
  }
  property string _locksOut: ""

  // Lock keys change under the user's fingers, so while the panel is open
  // follow them closely (sysfs only, the keyboard is not touched).
  Timer {
    interval: 1000
    running: root.opened && root.connected
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshLocks()
  }

  Timer {
    interval: root.pollSeconds * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.detect()
  }

  // ---- Panel plumbing (same contract as the built-in clock) -----------
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: shown ? button.implicitWidth : 0
  implicitHeight: button.implicitHeight
  visible: shown

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

  ShellIpc {
    target: "crucialjun.aula-f75"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function refresh(): void { root.detect(); root.refresh() }
    function effect(name: string): void { root.run(["effect", name]) }
    function brightness(level: int): void { root.setBrightness(level) }
    function colour(hex: string): void { root.setColour(hex) }
    function theme(): void { root.applyTheme() }
    function lightsToggle(): void { root.toggleLighting() }
    function lock(key: string): void { root.toggleLock(key) }
    function winlock(): void { root.toggleWinLock() }
    function mode(name: string): void { root.setMode(name === "" ? "toggle" : name) }
  }

  readonly property real openPanelIndicatorWidth: button.labelWidth
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰌌"
    dimmed: !root.connected || root.lightingOff
    tooltipText: root.connected
      ? "AULA F75 · " + (root.effectName || "…") + (root.transport === "wireless" ? " (2.4 GHz)" : "") + (root.osMode === "mac" ? " · Mac mode" : root.osMode === "android" ? " · Android mode" : "") + (root.winLocked ? " · Win locked" : "") + Model.describeLocks(root.locks, " · ")
      : "AULA F75 not connected"

    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleLighting()
      else if (b === Qt.MiddleButton) root.applyTheme()
      else root.togglePanel()
    }
    onWheelMoved: function(delta) { root.nudgeBrightness(delta > 0 ? 1 : -1) }
  }
}
