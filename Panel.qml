import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.therealasclepius.touchpad-comfortable"
  ipcTarget: "io.github.therealasclepius.touchpad-comfortable"
  manageIpc: true

  // Each panel instance can select a device; the helper serializes writes across bars.
  property var devices: []
  property string selectedDevice: "apple"
  property string selectedLabel: "Apple"
  property bool deviceConnected: false
  property string deviceName: ""
  property bool touchpadEnabled: true
  property bool naturalScroll: false
  property bool tapToClick: true
  property bool disableWhileTyping: true
  property bool clickfingerBehavior: true
  property bool pointerAcceleration: true
  property bool canRestorePreset: false
  property bool presetPending: false
  property real scrollFactor: 0.2
  property real pointerSpeed: 0.0
  property real pendingPointerSpeed: 0.0
  property string settingsError: ""
  property var pendingActions: []
  property int editGeneration: 0
  property int stateGeneration: 0
  property bool refreshPending: false
  readonly property string backend: String(Qt.resolvedUrl("trackpads.py")).replace(/^file:\/\//, "")

  function updateState(raw) {
    var data
    try { data = JSON.parse(raw) } catch (e) { settingsError = "Could not read trackpad settings"; return }
    if (data.error) { settingsError = data.error; return }
    devices = data.devices || []
    presetPending = false
    loadSelection()
  }

  function loadSelection() {
    var row = null
    for (var i = 0; i < devices.length; i++) {
      if (devices[i].id === selectedDevice) row = devices[i]
    }
    if (!row && devices.length) { row = devices[0]; selectedDevice = row.id }
    if (!row) return
    selectedLabel = row.label
    deviceConnected = row.connected
    deviceName = row.names[0] || ""
    var v = row.settings
    canRestorePreset = !!row.before_comfortable
    touchpadEnabled = v.enabled
    naturalScroll = v.natural_scroll
    tapToClick = v.tap_to_click
    disableWhileTyping = v.disable_while_typing
    clickfingerBehavior = v.clickfinger_behavior
    pointerAcceleration = v.accel_profile !== "flat"
    scrollFactor = v.scroll_factor
    pendingScrollFactor = scrollFactor
    pointerSpeed = v.sensitivity
    pendingPointerSpeed = pointerSpeed
  }

  function selectDevice(key) {
    // Flush pending slider edits against the OLD device before changing selection.
    if (scrollDebounce.running) { scrollDebounce.stop(); commitScrollFactor() }
    if (pointerDebounce.running) { pointerDebounce.stop(); commitPointerSpeed() }
    selectedDevice = key
    settingsError = ""
    loadSelection()
  }

  function enqueue(option, value) {
    editGeneration++
    settingsError = ""
    var queue = pendingActions.slice()
    queue.push({ device: selectedDevice, option: option, value: value })
    pendingActions = queue
    // Keep the local snapshot consistent while queued writes finish.
    for (var i = 0; i < devices.length; i++) {
      if (devices[i].id === selectedDevice) devices[i].settings[option] = value
    }
    runNextAction()
  }

  function runNextAction() {
    if (actionProc.running || pendingActions.length === 0) return
    var queue = pendingActions.slice()
    var next = queue.shift()
    pendingActions = queue
    actionProc.command = next.command
      ? bounded(10, ["python3", backend, next.command, next.device])
      : bounded(10, ["python3", backend, "set", next.device, next.option, JSON.stringify(next.value)])
    actionProc.running = true
  }

  function applyPreset(restore) {
    if (presetPending || !deviceName || (restore && !canRestorePreset)) return
    // Finish slider edits first, so undo returns to the user's latest settings.
    if (scrollDebounce.running) { scrollDebounce.stop(); commitScrollFactor() }
    if (pointerDebounce.running) { pointerDebounce.stop(); commitPointerSpeed() }
    editGeneration++
    settingsError = ""
    presetPending = true
    var queue = pendingActions.slice()
    queue.push({ device: selectedDevice, command: restore ? "restore" : "preset" })
    pendingActions = queue
    runNextAction()
  }

  // Pending scroll factor while dragging the slider.
  property real pendingScrollFactor: 0.4
  property bool scrollSetQueued: false

  // Carry sub-notch touchpad deltas between wheel events.
  property real wheelAccumulator: 0

  // ---- Cursor navigation ----
  // Sections: "header" (enable/disable toggle), "scroll" (scroll speed slider),
  // then toggle rows: "natural", "tap", "typing", "clickfinger"
  property string focusSection: "header"
  property int selectedIndex: 0
  property bool cursorActive: false

  readonly property var allSections: ["device", "preset", "restore", "header", "scroll", "pointer", "acceleration", "natural", "tap", "typing", "clickfinger"]

  readonly property string icon: {
    if (!deviceName) return ""
    return touchpadEnabled ? "󰟸" : "󰤳"
  }

  // Agent-flavored phrases for the hero status line, rotated on a timer so the
  // panel feels alive -- the same trick the built-in network, bluetooth, and
  // power panels use. Two sets, picked by whether the pad is listening or not.
  readonly property var enabledPhrases: [
    "Tracking fingers",
    "Counting taps",
    "Reading swipes",
    "Sensing capacitance",
    "Herding pixels",
    "Chasing gestures",
    "Smoothing jitter",
    "Polling deltas",
    "Feeling around"
  ]
  readonly property var disabledPhrases: [
    "Keyboardpunk",
    "Palms rejected",
    "Homerow purist",
    "Hjkl forever",
    "Sensor napping",
    "Ignoring thumbs",
    "Refusing swipes",
    "Gone tactile"
  ]
  property int phraseIndex: 0

  // Whichever list is "active" given the current touchpad state. Empty when
  // there is no device, which is what parks the rotation on a static label.
  readonly property var activePhrases: {
    if (!deviceName) return []
    return touchpadEnabled ? enabledPhrases : disabledPhrases
  }
  readonly property bool rotatingPhrases: false

  // Guard on the list itself rather than on deviceName. Bindings settle in
  // arbitrary order, so there is a tick where deviceName is already set but
  // activePhrases has not re-evaluated yet -- phraseIndex % 0 is NaN there,
  // and the lookup returns undefined, which QML refuses to assign to a string.
  readonly property string heroStatusText: deviceConnected
    ? (touchpadEnabled ? "Settings saved separately" : "Trackpad disabled")
    : "Disconnected · settings remembered"

  readonly property color hoverFill: bar
    ? Style.hoverFillFor(bar.foreground, Color.accent)
    : "transparent"
  readonly property color selectedFill: bar
    ? Style.selectedFillFor(bar.foreground, Color.accent)
    : "transparent"

  function moveCursor(delta) {
    var sections = allSections
    var sIdx = sections.indexOf(focusSection)
    if (sIdx < 0) { focusSection = sections[0]; return }

    if (delta > 0) {
      if (sIdx < sections.length - 1) focusSection = sections[sIdx + 1]
    } else {
      if (sIdx > 0) focusSection = sections[sIdx - 1]
    }
  }

  function moveCursorH(delta) {
    if (presetPending) return
    if (focusSection === "device") {
      var index = devices.findIndex(function(d) { return d.id === selectedDevice })
      var next = Math.max(0, Math.min(devices.length - 1, index + delta))
      if (devices[next]) selectDevice(devices[next].id)
    } else if (focusSection === "scroll") {
      adjustScrollFactor(delta > 0 ? 0.1 : -0.1)
    } else if (focusSection === "pointer") {
      adjustPointerSpeed(delta > 0 ? 0.1 : -0.1)
    }
  }

  function activateCursor() {
    if (presetPending) return
    if (focusSection === "preset") { applyPreset(false); return }
    if (focusSection === "restore") { applyPreset(true); return }
    if (focusSection === "acceleration") { togglePointerAcceleration(); return }
    if (focusSection === "header") { toggleTouchpad(); return }
    if (focusSection === "natural") { toggleNaturalScroll(); return }
    if (focusSection === "tap") { toggleTapToClick(); return }
    if (focusSection === "typing") { toggleDisableWhileTyping(); return }
    if (focusSection === "clickfinger") { toggleClickfingerBehavior(); return }
  }

  // ---- Process discipline ----
  //
  // Nothing this widget launches may outlive its usefulness. Every spawn goes
  // through here, so a wedged hyprctl, a stuck omarchy-* tool or a helper
  // blocked on something unforeseen is reaped rather than accumulating one
  // orphan per click.
  //
  // timeout(1) without --foreground runs the command in its own process group
  // and signals that group, so a shell's children die with it instead of being
  // left behind; -k follows SIGTERM with SIGKILL for anything that ignores it.
  function bounded(seconds, argv) {
    return ["timeout", "-k", "2", String(seconds)].concat(argv)
  }

  // ---- Actions: every change is scoped to the selected trackpad. ----
  function toggleTouchpad() {
    if (!deviceName) return
    touchpadEnabled = !touchpadEnabled
    enqueue("enabled", touchpadEnabled)
  }

  function toggleNaturalScroll() {
    var next = !naturalScroll
    naturalScroll = next
    setHyprOption("natural_scroll", next)
  }

  function toggleTapToClick() {
    var next = !tapToClick
    tapToClick = next
    setHyprOption("tap_to_click", next)
  }

  function toggleDisableWhileTyping() {
    var next = !disableWhileTyping
    disableWhileTyping = next
    setHyprOption("disable_while_typing", next)
  }

  function toggleClickfingerBehavior() {
    var next = !clickfingerBehavior
    clickfingerBehavior = next
    setHyprOption("clickfinger_behavior", next)
  }

  function setHyprOption(option, value) { enqueue(option, value) }

  function togglePointerAcceleration() {
    if (!touchpadEnabled) return
    pointerAcceleration = !pointerAcceleration
    enqueue("accel_profile", pointerAcceleration ? "adaptive" : "flat")
  }

  function adjustScrollFactor(delta) {
    var next = Model.clampScrollFactor(scrollFactor + delta)
    scrollFactor = next
    pendingScrollFactor = next
    scrollDebounce.restart()
  }

  function setScrollFactor(value) {
    var clamped = Model.clampScrollFactor(value)
    scrollFactor = clamped
    pendingScrollFactor = clamped
    scrollDebounce.restart()
  }

  function commitScrollFactor() {
    setHyprOption("scroll_factor", pendingScrollFactor)
  }

  function adjustPointerSpeed(delta) {
    var next = Model.clampSensitivity(pointerSpeed + delta)
    pointerSpeed = next
    pendingPointerSpeed = next
    pointerDebounce.restart()
  }

  function setPointerSpeed(value) {
    var clamped = Model.clampSensitivity(value)
    pointerSpeed = clamped
    pendingPointerSpeed = clamped
    pointerDebounce.restart()
  }

  function commitPointerSpeed() {
    enqueue("sensitivity", Model.clampSensitivity(pendingPointerSpeed))
  }

  function refresh() {
    refreshPending = true
    if (!stateProc.running && !actionProc.running && pendingActions.length === 0
        && !scrollDebounce.running && !pointerDebounce.running) {
      refreshPending = false
      stateGeneration = editGeneration
      stateProc.running = true
    }
  }

  function receiveState(raw) {
    // A read remains stale even after the newer write has finished.
    if (stateGeneration !== editGeneration || actionProc.running || pendingActions.length
        || scrollDebounce.running || pointerDebounce.running) {
      refreshPending = true
      return
    }
    updateState(raw)
  }

  function finishStateRead(code) {
    if (code !== 0) presetPending = false
    if (code !== 0 && !settingsError) settingsError = "Could not read trackpad settings"
    if (refreshPending) refresh()
  }

  function finishAction(code) {
    if (code !== 0 && !settingsError) settingsError = "Could not save trackpad settings"
    if (pendingActions.length) runNextAction()
    else refresh()
  }

  // ---- Lifecycle ----
  visible: deviceName !== ""
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: refresh()

  onOpenedChanged: {
    if (opened) {
      refresh()
      focusSection = "device"
      cursorActive = false
    }
  }

  // Poll while open so external changes are reflected.
  Timer {
    interval: 3000
    running: root.opened || root.devices.length === 0
    repeat: true
    onTriggered: root.refresh()
  }

  // Rotate the hero phrase while the panel is open and a device is present.
  // The swap is wrapped in a fade so the changeover reads as one motion
  // rather than a hard cut.
  Timer {
    id: phraseTimer
    interval: 2800
    running: root.opened && root.rotatingPhrases
    repeat: true
    triggeredOnStart: false
    onTriggered: phraseSwap.restart()
  }

  SequentialAnimation {
    id: phraseSwap
    PropertyAnimation {
      target: heroStatus; property: "opacity"
      to: 0.0; duration: 180; easing.type: Easing.OutQuad
    }
    ScriptAction {
      script: {
        var n = root.activePhrases.length
        if (n > 0) root.phraseIndex = (root.phraseIndex + 1) % n
      }
    }
    PropertyAnimation {
      target: heroStatus; property: "opacity"
      to: 1.0; duration: 260; easing.type: Easing.InQuad
    }
  }

  // Toggling the pad swaps phrase sets, so restart the cycle from the top --
  // otherwise index 4 of "enabled" carries over as index 4 of "disabled" and
  // the label looks like it skipped. Leaving a rotating state entirely (device
  // unplugged) halts a mid-flight fade so "NO DEVICE" is never stuck dimmed.
  Connections {
    target: root
    function onActivePhrasesChanged() {
      phraseSwap.stop()
      heroStatus.opacity = 1.0
      root.phraseIndex = 0
    }
  }

  // Give omarchy-toggle-input-device and the reload time to land, then
  // reconcile the panel against real state.
  Timer {
    id: enableSettle
    interval: 600
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: scrollDebounce
    interval: 200
    repeat: false
    onTriggered: root.commitScrollFactor()
  }

  Timer {
    id: pointerDebounce
    interval: 200
    repeat: false
    onTriggered: root.commitPointerSpeed()
  }

  Process {
    id: stateProc
    command: root.bounded(15, ["python3", root.backend, "state"])
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.receiveState(String(text))
      }
    }
    onExited: function(code, status) {
      Qt.callLater(function() { root.finishStateRead(code) })
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var data = JSON.parse(String(text))
          if (data.error) root.settingsError = data.error
        } catch (e) { root.settingsError = "Could not save trackpad settings" }
      }
    }
    onExited: function(code, status) {
      Qt.callLater(function() { root.finishAction(code) })
    }
  }

  // ---- Bar icon ----
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleTouchpad()
      else root.toggle()
    }
  }

  // ---- Popup panel ----
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.moveCursorH(dx)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        enabled: !root.presetPending
        anchors.fill: parent
        spacing: Style.space(14)

        Row {
          width: parent.width
          spacing: Style.space(8)
          Repeater {
            model: root.devices
            CursorSurface {
              required property var modelData
              width: (column.width - Style.space(8) * (root.devices.length - 1)) / Math.max(1, root.devices.length)
              height: Style.space(38)
              foreground: root.bar.foreground
              fill: root.selectedDevice === modelData.id ? root.selectedFill : root.hoverFill
              current: root.selectedDevice === modelData.id
              hasCursor: root.cursorActive && root.focusSection === "device" && root.selectedDevice === modelData.id
              Text {
                anchors.centerIn: parent
                text: modelData.label
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                font.bold: root.selectedDevice === modelData.id
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: { root.selectDevice(parent.modelData.id); root.focusSection = "device" }
              }
            }
          }
        }

        Text {
          width: parent.width
          visible: root.settingsError !== ""
          text: root.settingsError
          wrapMode: Text.Wrap
          color: Color.urgent
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }

        Column {
          width: parent.width
          spacing: Style.space(6)
          Text {
            width: parent.width
            text: "Comfortable preset"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
          }
          Text {
            width: parent.width
            text: "Balanced pointer speed, responsive scrolling and light taps. Keeps your scroll direction."
            wrapMode: Text.WordWrap
            color: root.bar.foreground
            opacity: 0.7
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }
          Row {
            width: parent.width
            spacing: Style.space(8)
            PresetButton {
              width: (parent.width - parent.spacing) / 2
              label: root.presetPending ? "Saving…" : "Apply preset"
              sectionName: "preset"
              onClicked: root.applyPreset(false)
            }
            PresetButton {
              width: (parent.width - parent.spacing) / 2
              label: "Undo preset"
              sectionName: "restore"
              enabled: root.canRestorePreset
              opacity: enabled ? 1 : 0.4
              onClicked: root.applyPreset(true)
            }
          }
        }

        // ========== Hero: Touchpad icon + status + power toggle ==========
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, powerSwitch.implicitHeight)

          Text {
            id: heroIcon
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.icon
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            opacity: root.touchpadEnabled ? 1.0 : 0.5
          }

          ToggleSwitch {
            id: powerSwitch
            visible: root.deviceName !== ""
            checked: root.touchpadEnabled
            hasCursor: root.cursorActive && root.focusSection === "header"
            foreground: root.bar.foreground
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            onHovered: function(on) {
              if (on) {
                root.cursorActive = true
                root.focusSection = "header"
              }
            }
            onToggled: root.toggleTouchpad()

            PanelToolTip {
              visible: powerSwitch.containsMouse
              text: root.touchpadEnabled ? "Disable touchpad" : "Enable touchpad"
              fontFamily: root.bar.fontFamily
            }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.rightMargin: powerSwitch.visible ? powerSwitch.width + Style.space(12) : 0
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: root.selectedLabel + " Trackpad"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              id: heroStatus
              text: root.heroStatusText.toUpperCase()
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }
        }

        PanelSeparator {
          foreground: root.bar.foreground
        }

        // ========== Scroll speed slider ==========
        Column {
          width: parent.width
          spacing: Style.space(8)
          opacity: root.touchpadEnabled ? 1.0 : 0.4

          Item {
            width: parent.width
            implicitHeight: scrollLabel.implicitHeight

            Text {
              id: scrollLabel
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Scroll Speed"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: {
                var v = scrollSlider.dragging ? scrollSlider.liveValue : root.scrollFactor
                return Model.scrollSpeedLabel(v) + "  " + v.toFixed(2)
              }
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Item {
            width: parent.width
            implicitHeight: Math.max(minusBtn.implicitHeight, scrollRow.implicitHeight, plusBtn.implicitHeight)

            // Minus button
            CursorSurface {
              id: minusSurface
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(32)
              height: Style.space(32)
              hasCursor: false
              foreground: root.bar.foreground
              fill: root.hoverFill

              Text {
                id: minusBtn
                anchors.centerIn: parent
                text: "−"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.heading
                opacity: root.scrollFactor <= 0.1 ? 0.3 : 1.0
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.adjustScrollFactor(-0.1)
                onContainsMouseChanged: if (containsMouse) {
                  root.cursorActive = true
                  root.focusSection = "scroll"
                }
              }
            }

            // Slider track
            CursorSurface {
              id: scrollRow
              anchors.left: minusSurface.right
              anchors.right: plusSurface.left
              anchors.leftMargin: Style.space(4)
              anchors.rightMargin: Style.space(4)
              anchors.verticalCenter: parent.verticalCenter
              height: scrollSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "scroll"
              foreground: root.bar.foreground
              outline: true

              PanelSlider {
                id: scrollSlider
                bar: root.bar
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 0.1
                maximum: 2.0
                step: 0.1
                value: root.scrollFactor
                onMoved: function(v) { root.setScrollFactor(v) }
                onReleased: function(v) {
                  scrollDebounce.stop()
                  root.setScrollFactor(v)
                  root.commitScrollFactor()
                }
              }

              HoverHandler {
                onHoveredChanged: if (hovered) {
                  root.cursorActive = true
                  root.focusSection = "scroll"
                }
              }
            }

            // Plus button
            CursorSurface {
              id: plusSurface
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(32)
              height: Style.space(32)
              hasCursor: false
              foreground: root.bar.foreground
              fill: root.hoverFill

              Text {
                id: plusBtn
                anchors.centerIn: parent
                text: "+"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.heading
                opacity: root.scrollFactor >= 2.0 ? 0.3 : 1.0
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.adjustScrollFactor(0.1)
                onContainsMouseChanged: if (containsMouse) {
                  root.cursorActive = true
                  root.focusSection = "scroll"
                }
              }
            }
          }
        }

        PanelSeparator {
          foreground: root.bar.foreground
        }

        // ========== Pointer speed slider ==========
        // Range is Hyprland's [-1.0, 1.0], centered on 0.0 rather than running
        // low-to-high like the scroll slider above it.
        Column {
          width: parent.width
          spacing: Style.space(8)
          opacity: root.touchpadEnabled ? 1.0 : 0.4

          Item {
            width: parent.width
            implicitHeight: pointerLabel.implicitHeight

            Text {
              id: pointerLabel
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Pointer Speed"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: {
                var v = pointerSlider.dragging ? pointerSlider.liveValue : root.pointerSpeed
                return Model.pointerSpeedLabel(v) + "  " + v.toFixed(1)
              }
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Item {
            width: parent.width
            implicitHeight: Math.max(pMinusBtn.implicitHeight, pointerRow.implicitHeight, pPlusBtn.implicitHeight)

            CursorSurface {
              id: pMinusSurface
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(32)
              height: Style.space(32)
              hasCursor: false
              foreground: root.bar.foreground
              fill: root.hoverFill

              Text {
                id: pMinusBtn
                anchors.centerIn: parent
                text: "−"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.heading
                opacity: root.pointerSpeed <= -1.0 ? 0.3 : 1.0
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.adjustPointerSpeed(-0.1)
                onContainsMouseChanged: if (containsMouse) {
                  root.cursorActive = true
                  root.focusSection = "pointer"
                }
              }
            }

            CursorSurface {
              id: pointerRow
              anchors.left: pMinusSurface.right
              anchors.right: pPlusSurface.left
              anchors.leftMargin: Style.space(4)
              anchors.rightMargin: Style.space(4)
              anchors.verticalCenter: parent.verticalCenter
              height: pointerSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "pointer"
              foreground: root.bar.foreground
              outline: true

              PanelSlider {
                id: pointerSlider
                bar: root.bar
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: -1.0
                maximum: 1.0
                step: 0.1
                value: root.pointerSpeed
                onMoved: function(v) { root.setPointerSpeed(v) }
                onReleased: function(v) {
                  pointerDebounce.stop()
                  root.setPointerSpeed(v)
                  root.commitPointerSpeed()
                }
              }

              HoverHandler {
                onHoveredChanged: if (hovered) {
                  root.cursorActive = true
                  root.focusSection = "pointer"
                }
              }
            }

            CursorSurface {
              id: pPlusSurface
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(32)
              height: Style.space(32)
              hasCursor: false
              foreground: root.bar.foreground
              fill: root.hoverFill

              Text {
                id: pPlusBtn
                anchors.centerIn: parent
                text: "+"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.heading
                opacity: root.pointerSpeed >= 1.0 ? 0.3 : 1.0
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.adjustPointerSpeed(0.1)
                onContainsMouseChanged: if (containsMouse) {
                  root.cursorActive = true
                  root.focusSection = "pointer"
                }
              }
            }
          }
        }

        PanelSeparator {
          foreground: root.bar.foreground
        }

        // ========== Toggle rows ==========
        Column {
          width: parent.width
          spacing: Style.space(6)
          opacity: root.touchpadEnabled ? 1.0 : 0.4

          ToggleRow {
            width: parent.width
            label: "Pointer Acceleration"
            description: root.pointerAcceleration
              ? "Move faster to travel farther"
              : "Constant response at any hand speed"
            checked: root.pointerAcceleration
            sectionName: "acceleration"
            enabled: root.touchpadEnabled
            onToggled: root.togglePointerAcceleration()
          }

          ToggleRow {
            width: parent.width
            label: "Natural Scrolling"
            description: "Scroll content in the direction of finger movement"
            checked: root.naturalScroll
            sectionName: "natural"
            enabled: root.touchpadEnabled
            onToggled: root.toggleNaturalScroll()
          }

          ToggleRow {
            width: parent.width
            label: "Tap to Click"
            description: "Tap the touchpad to click"
            checked: root.tapToClick
            sectionName: "tap"
            enabled: root.touchpadEnabled
            onToggled: root.toggleTapToClick()
          }

          ToggleRow {
            width: parent.width
            label: "Disable While Typing"
            description: "Ignore touchpad input while typing"
            checked: root.disableWhileTyping
            sectionName: "typing"
            enabled: root.touchpadEnabled
            onToggled: root.toggleDisableWhileTyping()
          }

          ToggleRow {
            width: parent.width
            label: "Two-Finger Right Click"
            description: "Press with two fingers for right-click"
            checked: root.clickfingerBehavior
            sectionName: "clickfinger"
            enabled: root.touchpadEnabled
            onToggled: root.toggleClickfingerBehavior()
          }
        }
      }
    }
  }

  component PresetButton: CursorSurface {
    required property string label
    required property string sectionName
    signal clicked()
    height: Style.space(36)
    foreground: root.bar.foreground
    fill: root.hoverFill
    hasCursor: root.cursorActive && root.focusSection === sectionName
    Text {
      anchors.centerIn: parent
      text: parent.label
      color: root.bar.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body
    }
    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: parent.clicked()
      onContainsMouseChanged: if (containsMouse) {
        root.cursorActive = true
        root.focusSection = parent.sectionName
      }
    }
  }

  // ========== Reusable toggle row component ==========
  component ToggleRow: CursorSurface {
    id: toggleRow
    required property string label
    required property string description
    required property bool checked
    required property string sectionName
    property bool enabled: true

    signal toggled()

    hasCursor: root.cursorActive && root.focusSection === sectionName
    foreground: root.bar.foreground
    fill: root.hoverFill

    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) {
        root.cursorActive = true
        root.focusSection = toggleRow.sectionName
      }
      onClicked: if (toggleRow.enabled) toggleRow.toggled()
    }

    Item {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      implicitHeight: Math.max(rowLabels.implicitHeight, rowSwitch.implicitHeight)

      Column {
        id: rowLabels
        anchors.left: parent.left
        anchors.right: rowSwitch.left
        anchors.rightMargin: Style.space(12)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          text: toggleRow.label
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          width: parent.width
        }

        Text {
          visible: toggleRow.description !== ""
          text: toggleRow.description
          color: Qt.darker(root.bar.foreground, 1.5)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          width: parent.width
          wrapMode: Text.WordWrap
        }
      }

      ToggleSwitch {
        id: rowSwitch
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        checked: toggleRow.checked
        foreground: root.bar.foreground
        onToggled: if (toggleRow.enabled) toggleRow.toggled()
      }
    }
  }
}
