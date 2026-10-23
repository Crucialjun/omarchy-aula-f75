import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// The lighting popup for the AULA F75. All state and device calls live on
// the host BarWidget (hostWidget); this file only lays the controls out.
Panel {
  id: root
  moduleName: "crucialjun.aula-f75"
  ipcTarget: "crucialjun.aula-f75"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  readonly property var kb: hostWidget

  readonly property var status: kb && kb.status ? kb.status : ({})
  readonly property bool connected: kb ? kb.connected === true : false
  readonly property bool busy: kb ? kb.busy === true : false
  readonly property string lastError: kb ? String(kb.lastError || "") : ""
  readonly property bool permissionDenied: kb ? kb.permissionDenied === true : false
  readonly property bool showHidden: kb ? kb.showHiddenEffects === true : false
  readonly property bool hasStatus: connected && status.effect !== undefined

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property int contentW: Style.space(380)

  // Dropdown assigns its own `value` when the user picks, which breaks the
  // binding to the keyboard state; push fresh state into them by hand.
  readonly property Item effectControl: panel.loadedContent ? panel.loadedContent.effectDropdown : null
  readonly property Item sleepControl: panel.loadedContent ? panel.loadedContent.sleepDropdown : null
  readonly property Item debounceControl: panel.loadedContent ? panel.loadedContent.debounceDropdown : null

  function syncControls() {
    if (!root.hasStatus) return
    if (root.effectControl) root.effectControl.value = String(root.status.effect)
    if (root.sleepControl) root.sleepControl.value = Model.sleepValue(root.status)
    if (root.debounceControl) root.debounceControl.value = String(root.status.debounce)
  }
  onStatusChanged: syncControls()

  function open() {
    if (kb) kb.refresh()
    root.controller.show()
    Qt.callLater(syncControls)
  }
  function close() { root.controller.hide() }
  function toggle() { opened ? close() : open() }
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(root.contentW)
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias effectDropdown: effectDropdown
      property alias sleepDropdown: sleepDropdown
      property alias debounceDropdown: debounceDropdown
      implicitHeight: column.implicitHeight
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (dy !== 0 && root.kb) root.kb.nudgeBrightness(-dy)
      }
      onTextKey: function(t) {
        if (!root.kb) return
        if (t === "t" || t === "T") root.kb.applyTheme()
        else if (t === "o" || t === "O") root.kb.toggleLighting()
        else if (t === "r" || t === "R") root.kb.refresh()
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.spacing.panelGap

        // ---- Hero ---------------------------------------------------
        PanelHero {
          width: parent.width
          title: "AULA F75"
          meta: root.hasStatus
            ? Model.describe(root.status)
            : (root.connected ? (root.lastError !== "" ? root.lastError : "Reading…") : "Plug the keyboard in or pair the dongle")
          detail: root.connected ? (root.kb.transport === "wireless" ? "2.4 GHz" : "USB") : ""
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconOpacity: root.connected && !(root.status && root.status.effect === 0) ? 1.0 : 0.5
          iconComponent: Component {
            Text {
              text: "󰌌"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
          trailingControl: Component {
            ToggleSwitch {
              checked: root.hasStatus && root.status.effect !== 0
              interactive: root.connected && !root.busy
              busy: root.busy
              foreground: root.foreground
              onToggled: if (root.kb) root.kb.toggleLighting()
            }
          }
        }

        // ---- Permission help ------------------------------------------
        Column {
          width: parent.width
          spacing: Style.spacing.labelGap
          visible: root.permissionDenied

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "The shell cannot open the keyboard's HID interface yet. Install the udev rule once (polkit will ask for your password)."
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
          Button {
            text: "Grant access"
            iconText: "󰌾"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: if (root.kb) root.kb.installUdev()
          }
        }

        // ---- Effect ---------------------------------------------------
        PanelSeparator { width: parent.width; foreground: root.foreground }
        PanelSectionHeader { text: "Effect"; foreground: root.foreground; fontFamily: root.fontFamily }

        Dropdown {
          id: effectDropdown
          width: parent.width
          showLabel: false
          enabled: root.hasStatus && !root.busy
          foreground: root.foreground
          fontFamily: root.fontFamily
          options: Model.effectOptions(root.status, root.showHidden)
          value: root.hasStatus ? String(root.status.effect) : ""
          onChanged: function(v) {
            if (root.kb && v !== "" && String(root.status.effect) !== v) root.kb.setEffect(parseInt(v))
          }
        }

        // ---- Brightness / speed ---------------------------------------
        Column {
          width: parent.width
          spacing: Style.spacing.labelGap
          visible: root.hasStatus && root.status.effect !== 0

          Item {
            width: parent.width
            height: brightnessHeader.implicitHeight
            PanelSectionHeader {
              id: brightnessHeader
              anchors.left: parent.left
              text: "Brightness"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            Text {
              anchors.right: parent.right
              anchors.baseline: brightnessHeader.baseline
              text: root.hasStatus ? root.status.brightness + " / " + (root.status.brightness_max || 9) : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
          PanelSlider {
            bar: root.bar
            width: parent.width
            minimum: 0
            maximum: root.hasStatus ? (root.status.brightness_max || 9) : 9
            step: 1
            integer: true
            tickCount: 10
            value: root.hasStatus ? root.status.brightness : 0
            enabled: root.hasStatus && !root.busy
            onReleased: function(v) { if (root.kb) root.kb.setBrightness(Math.round(v)) }
          }
        }

        Column {
          width: parent.width
          spacing: Style.spacing.labelGap
          visible: root.hasStatus && root.status.has_speed === true

          PanelSectionHeader { text: "Speed"; foreground: root.foreground; fontFamily: root.fontFamily }
          PanelSlider {
            bar: root.bar
            width: parent.width
            minimum: 0
            maximum: root.hasStatus ? (root.status.speed_max || 4) : 4
            step: 1
            integer: true
            tickCount: 5
            value: root.hasStatus ? root.status.speed : 0
            enabled: root.hasStatus && !root.busy
            onReleased: function(v) { if (root.kb) root.kb.setSpeed(Math.round(v)) }
          }
        }

        // ---- Colour ---------------------------------------------------
        Column {
          width: parent.width
          spacing: Style.spacing.labelGap
          visible: root.hasStatus && root.status.has_colour === true

          PanelSeparator { width: parent.width; foreground: root.foreground }
          PanelSectionHeader { text: "Colour"; foreground: root.foreground; fontFamily: root.fontFamily }

          Toggle {
            width: parent.width
            label: "Colourful"
            description: "Let the effect cycle through every colour instead of one"
            checked: root.hasStatus && root.status.colorful === true
            foreground: root.foreground
            fontFamily: root.fontFamily
            enabled: !root.busy
            onClicked: if (root.kb) root.kb.setColorful(!checked)
          }

          Flow {
            width: parent.width
            spacing: Style.space(6)
            opacity: root.hasStatus && root.status.colorful ? 0.45 : 1.0

            Repeater {
              model: [
                { label: "theme accent", colour: Model.hexColor(Commons.Color.accent) },
                { label: "theme text", colour: Model.hexColor(Commons.Color.foreground) },
                { label: "theme urgent", colour: Model.hexColor(Commons.Color.urgent) }
              ].concat(Model.palette(root.status).map(function(c) { return { label: c, colour: c } }))

              Rectangle {
                required property var modelData
                readonly property bool current: root.hasStatus && !root.status.colorful && root.status.colour === modelData.colour
                width: Style.space(28)
                height: Style.space(28)
                radius: Style.cornerRadius > 0 ? Style.space(6) : 0
                color: modelData.colour
                border.width: current ? 2 : (swatchMouse.containsMouse ? 1 : 0)
                border.color: root.foreground

                MouseArea {
                  id: swatchMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: if (root.kb) root.kb.setColour(modelData.colour)
                  onEntered: if (root.bar && typeof root.bar.showTooltip === "function") root.bar.showTooltip(parent, modelData.label)
                  onExited: if (root.bar && typeof root.bar.hideTooltip === "function") root.bar.hideTooltip(parent)
                }
              }
            }
          }
        }

        // ---- Settings -------------------------------------------------
        PanelSeparator { width: parent.width; foreground: root.foreground }
        PanelSectionHeader { text: "Keyboard settings"; foreground: root.foreground; fontFamily: root.fontFamily }

        RowLayout {
          width: parent.width
          spacing: Style.spacing.rowGap

          Dropdown {
            id: sleepDropdown
            Layout.fillWidth: true
            label: "Sleep (wireless)"
            enabled: root.hasStatus && !root.busy
            foreground: root.foreground
            fontFamily: root.fontFamily
            options: Model.SLEEP_OPTIONS
            value: Model.sleepValue(root.status)
            onChanged: function(v) { if (root.kb && v !== Model.sleepValue(root.status)) root.kb.setSleep(v) }
          }

          Dropdown {
            id: debounceDropdown
            Layout.fillWidth: true
            label: "Debounce"
            enabled: root.hasStatus && !root.busy
            foreground: root.foreground
            fontFamily: root.fontFamily
            options: Model.DEBOUNCE_OPTIONS
            value: root.hasStatus ? String(root.status.debounce) : ""
            onChanged: function(v) { if (root.kb && v !== "" && String(root.status.debounce) !== v) root.kb.setDebounce(parseInt(v)) }
          }
        }

        // ---- Actions --------------------------------------------------
        PanelSeparator { width: parent.width; foreground: root.foreground }

        Row {
          width: parent.width
          spacing: Style.spacing.controlGap

          Button {
            text: "Match theme"
            iconText: "󰏘"
            tooltipText: "Set the keyboard colour to the Omarchy accent (T)"
            foreground: root.foreground
            fontFamily: root.fontFamily
            enabled: root.connected && !root.busy
            onClicked: if (root.kb) root.kb.applyTheme()
          }
          Button {
            text: "Refresh"
            iconText: "󰑐"
            tooltipText: "Read the keyboard again (R)"
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconSpinning: root.busy
            onClicked: if (root.kb) { root.kb.detect(); root.kb.refresh() }
          }
        }

        Text {
          width: parent.width
          visible: root.lastError !== "" && !root.permissionDenied
          wrapMode: Text.WordWrap
          text: root.lastError
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          text: "Changes are written straight to the keyboard's onboard memory and survive unplugging. Per-key colours: aula-f75 perkey …"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
