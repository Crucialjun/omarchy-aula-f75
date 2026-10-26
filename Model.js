.pragma library

// Pure helpers shared by BarWidget.qml and Panel.qml. No QML objects in
// here so the logic stays testable by eye.

function localPath(url) {
  return String(url).replace(/^file:\/\//, "")
}

// Qt prints a colour with alpha as #AARRGGBB; the CLI wants #rrggbb.
function hexColor(c) {
  var s = String(c)
  if (s.length === 9) s = "#" + s.slice(3)
  return s.toLowerCase()
}

function parseJson(text) {
  try { return JSON.parse(String(text || "")) } catch (e) { return null }
}

var DEFAULT_PALETTE = ["#ff0000", "#00ff00", "#0000ff", "#ffff00", "#ff00ff", "#00ffff", "#ffffff"]

var SLEEP_OPTIONS = [
  { value: "0", label: "Off" },
  { value: "1", label: "1 min" },
  { value: "1.5", label: "1.5 min" },
  { value: "2", label: "2 min" },
  { value: "3", label: "3 min" },
  { value: "4", label: "4 min" },
  { value: "5", label: "5 min" },
  { value: "10", label: "10 min" },
  { value: "15", label: "15 min" },
  { value: "20", label: "20 min" }
]

var DEBOUNCE_OPTIONS = [
  { value: "1", label: "1 (fastest)" },
  { value: "2", label: "2" },
  { value: "3", label: "3" },
  { value: "4", label: "4 (most filtering)" }
]

// The current sleep value as one of SLEEP_OPTIONS, nearest match.
function sleepValue(status) {
  var minutes = status && status.sleep_minutes !== undefined ? Number(status.sleep_minutes) : 0
  if (!minutes) return "0"
  var best = SLEEP_OPTIONS[1], bestDiff = Infinity
  for (var i = 1; i < SLEEP_OPTIONS.length; i++) {
    var d = Math.abs(Number(SLEEP_OPTIONS[i].value) - minutes)
    if (d < bestDiff) { best = SLEEP_OPTIONS[i]; bestDiff = d }
  }
  return best.value
}

function effectOptions(status, showHidden) {
  var list = status && status.effects ? status.effects : []
  var out = []
  for (var i = 0; i < list.length; i++) {
    var e = list[i]
    if (e.hidden && !showHidden) continue
    out.push({ value: String(e.id), label: e.hidden ? e.name + " (hidden)" : e.name })
  }
  return out
}

function effectById(status, id) {
  var list = status && status.effects ? status.effects : []
  for (var i = 0; i < list.length; i++) if (list[i].id === id) return list[i]
  return null
}

function palette(status) {
  if (status && status.palette && status.palette.length === 7) return status.palette
  return DEFAULT_PALETTE
}

function describe(status) {
  if (!status || status.effect === undefined) return ""
  var parts = [status.effect_name]
  if (status.effect !== 0) parts.push("brightness " + status.brightness)
  if (status.has_speed) parts.push("speed " + status.speed)
  if (status.has_colour) parts.push(status.colorful ? "colourful" : (status.colour || "colour slot " + status.colour_index))
  return parts.join(" · ")
}

var LOCK_KEYS = [
  { key: "caps", label: "Caps", full: "Caps Lock" },
  { key: "num", label: "Num", full: "Num Lock" },
  { key: "scroll", label: "Scroll", full: "Scroll Lock" }
]

// " · Caps Lock · Num Lock" for the locks that are on, "" when none / unknown.
function describeLocks(locks, sep) {
  if (!locks || locks.available !== true) return ""
  var out = ""
  for (var i = 0; i < LOCK_KEYS.length; i++)
    if (locks[LOCK_KEYS[i].key] === true) out += (sep || " · ") + LOCK_KEYS[i].full
  return out
}

var LINK_NAMES = { wired: "USB", wireless: "2.4 GHz", bluetooth: "Bluetooth" }

function linkName(link) { return LINK_NAMES[link] || (link ? String(link) : "") }

// "2.4 GHz · 87%" for the hero; "" when unknown.
function describeLink(kb) {
  if (!kb || !kb.connected) return ""
  var s = linkName(kb.transport)
  if (kb.battery !== null && kb.battery !== undefined) s += " · " + kb.battery + "%" + (kb.charging ? " charging" : "")
  return s
}

// Everything the host can see: "USB cable, dongle plugged, Bluetooth paired".
function describeLinks(links, active) {
  if (!links) return ""
  var out = []
  if (links.usb) out.push(active === "wired" ? "USB (active)" : "USB cable plugged")
  if (links.dongle) out.push(active === "wireless" ? "2.4 GHz dongle (active)" : "2.4 GHz dongle plugged")
  if (links.bluetooth) out.push("Bluetooth" + (links.bluetooth_battery !== null && links.bluetooth_battery !== undefined ? " (" + links.bluetooth_battery + "%)" : ""))
  return out.join(", ")
}

function batteryIcon(pct, charging) {
  if (pct === null || pct === undefined) return "󰂑"
  if (charging) return "󰂄"
  var icons = ["󰂎", "󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
  return icons[Math.max(0, Math.min(10, Math.round(pct / 10)))]
}

var MODE_OPTIONS = [
  { value: "windows", label: "Windows" },
  { value: "android", label: "Android" },
  { value: "mac", label: "macOS" }
]
