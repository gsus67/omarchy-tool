import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Omarchy Tool: one bar icon, one panel. The panel opens on a list with one
// button per module; a button opens that module's own page.
//
// All state and side effects live in bin/omarchy-tool; this file only shows
// `omarchy-tool status` and runs module actions. Each module's page is a QML
// file under modules/ that receives `status` (its slice of the status JSON)
// and calls `tool.run([...])`. Every module reports `status.enabled` and has
// `enable`/`disable` actions for its list switch. Add a module by listing it
// in `modules` below.
Panel {
  id: root
  moduleName: "io.github.gsus67.omarchy-tool"
  ipcTarget: "omarchy-tool"
  // Own handler (the base one has no page()): omarchy-shell omarchy-tool page <module-id>
  manageIpc: false

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function language(): string { return root.language }
    function page(id: string): void {
      for (var i = 0; i < root.modules.length; i++) {
        if (root.modules[i].id === id) {
          root.open()
          root.openModule(root.modules[i])
          return
        }
      }
    }
  }

  // Listed in this order, under a header per group; keep a group's modules
  // next to each other.
  readonly property var modules: [
    { id: "windows-disks", group: "Windows", title: root.t("Discos en Windows"), source: "modules/WindowsDisks.qml" },
    { id: "usb-windows", group: "Windows", title: root.t("Periféricos en Windows"), hint: root.t("SUPER + ALT + U: devolver todo a Linux"), source: "modules/UsbWindows.qml" },
    { id: "web-devices", group: root.t("Navegador"), title: root.t("Periféricos en navegador"), source: "modules/WebDevices.qml" },
    { id: "extras", group: "Omarchy", title: root.t("Extras"), switchable: false },
    { id: "disk-tiles", parent: "extras", title: root.t("Discos en mosaicos"), source: "modules/DiskTiles.qml" },
    { id: "exe-icons", parent: "extras", title: root.t("Iconos de .exe"), source: "modules/ExeIcons.qml" },
    { id: "exe-proton", parent: "extras", title: root.t("Abrir .exe con Proton"), source: "modules/ExeProton.qml" },
    { id: "network-ip", parent: "extras", title: root.t("IP de red"), source: "modules/NetworkIp.qml" },
    { id: "plugins", group: "Omarchy", title: root.t("Plugins"), source: "modules/Plugins.qml", switchable: false }
  ]

  // Both levels use the same list delegate and ModuleButton below.
  readonly property var listModules: modules.filter(function(module) {
    return current === null ? !module.parent : current.id === "extras" && module.parent === "extras"
  })
  readonly property string toolPath: decodeURIComponent(String(Qt.resolvedUrl("bin/omarchy-tool")).replace(/^file:\/\//, ""))
  property var status: ({})
  property var translations: ({})
  readonly property string language: (Quickshell.env("LC_ALL") || Quickshell.env("LC_MESSAGES") || Quickshell.env("LANG") || Qt.locale().name).toLowerCase().split(/[_.-]/)[0] === "es" ? "es" : "en"
  function t(source) {
    var catalog = translations[language] || ({})
    return catalog[source] || source
  }
  FileView {
    path: root.toolPath.replace(/\/bin\/omarchy-tool$/, "/i18n/messages.json")
    onLoaded: { try { root.translations = JSON.parse(text()) } catch (e) { root.translations = ({}) } }
  }
  property string error: ""
  property bool busy: false
  property var queue: []
  property var current: null
  // Keyboard cursor on the list (-1: none until an arrow key is pressed).
  property int cursorIndex: -1
  // Modules set this while a text field has focus so typed keys reach it.
  property bool typing: false

  function moduleStatus(id) {
    var mods = status && status.modules ? status.modules : null
    return mods && mods[id] ? mods[id] : ({})
  }

  function openModule(module) {
    error = ""
    current = module
    cursorIndex = -1
  }

  function moveCursor(delta) {
    if (listModules.length === 0) return
    cursorIndex = cursorIndex < 0 ? 0 : Math.max(0, Math.min(listModules.length - 1, cursorIndex + delta))
  }

  function back() {
    error = ""
    typing = false
    current = current && current.parent ? modules.filter(function(module) { return module.id === "extras" })[0] : null
    cursorIndex = -1
  }

  // Run `omarchy-tool <args...>`, then refresh. Actions run one at a time in
  // order so quick clicks can't race each other on the config file.
  function run(args) {
    queue = queue.concat([args])
    pump()
  }

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function pump() {
    if (actionProc.running || queue.length === 0) return
    var next = queue[0]
    queue = queue.slice(1)
    busy = true
    actionProc.command = [toolPath].concat(next)
    actionProc.running = true
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (opened) refresh()
    else { current = null; back() }
  }

  readonly property string pluginDir: toolPath.replace(/\/bin\/omarchy-tool$/, "")

  // Re-sync side effects at shell start: Omarchy may have rewritten the
  // Windows entry (reinstall) while the shell was down.
  Component.onCompleted: run(["apply"])

  // `omarchy plugin remove` deletes our folder and then unloads us, without
  // running any plugin code. Hand off to the uninstaller copy outside the
  // folder; it does nothing unless the folder is really gone, so a shell
  // restart or a hot reload leaves everything as is.
  Component.onDestruction: {
    var uninstaller = status && status.uninstaller ? String(status.uninstaller) : ""
    if (uninstaller === "") return
    Quickshell.execDetached(["bash", "-c", 'sleep 3; [ -f "$1" ] && exec bash "$1" "$2"',
      "omarchy-tool-cleanup", uninstaller, pluginDir])
  }

  // Auto-update: check GitHub a couple of minutes after the shell starts,
  // then every six hours. `omarchy-tool self-update` does nothing when there
  // is no newer version.
  Process {
    id: updateProc
    command: [root.toolPath, "self-update"]
  }

  Timer {
    interval: 2 * 60 * 1000
    running: true
    onTriggered: {
      updateProc.running = true
      updateTimer.running = true
    }
  }

  Timer {
    id: updateTimer
    interval: 6 * 60 * 60 * 1000
    repeat: true
    onTriggered: if (!updateProc.running) updateProc.running = true
  }

  // Periféricos en Windows: every couple of seconds a cheap probe tells
  // whether Windows is running (QEMU pid) and whether "Devolver periféricos a
  // Linux" was run inside it. When Windows appears, devices whose switch is on
  // go over (sync-live); a request gives everything back. Every bar instance
  // probes, the tool serializes and later runs find nothing left to do.
  readonly property var usbStatus: moduleStatus("usb-windows")
  readonly property bool usbWatch: usbStatus.enabled === true && !!usbStatus.watcher
  property string usbVmPid: ""

  Process {
    id: usbProbe
    command: ["bash", root.usbStatus.watcher || "", root.usbStatus.requestFile || ""]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var pid = (String(text).match(/pid=(\d*)/) || [])[1] || ""
        if (/request=1/.test(text)) root.run(["usb-windows", "check-request"])
        if (pid !== root.usbVmPid) {
          root.usbVmPid = pid
          if (pid !== "") root.run(["usb-windows", "sync-live"])
          else root.refresh()
        }
      }
    }
  }

  Timer {
    interval: 2000
    repeat: true
    running: root.usbWatch
    onTriggered: if (!usbProbe.running) usbProbe.running = true
  }

  Process {
    id: statusProc
    command: [root.toolPath, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.status = JSON.parse(text)
        } catch (e) {
          root.error = root.t("No se pudo leer el estado del plugin")
        }
      }
    }
  }

  Process {
    id: actionProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text || "").trim()
        if (message !== "") root.error = message.replace(/^omarchy-tool: /, "")
      }
    }
    onRunningChanged: if (running) root.error = ""
    onExited: function(exitCode) {
      root.busy = false
      root.refresh()
      Qt.callLater(root.pump)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰦬"
    tooltipText: "Omarchy Tool"
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.LeftButton) root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.typing
      // Esc steps back to the list first, then closes.
      onCloseRequested: root.current ? root.back() : root.close()
      onMoveRequested: function(dx, dy) { root.moveCursor(dy !== 0 ? dy : dx) }
      onActivateRequested: if (root.listModules.length > 0) root.openModule(root.listModules[Math.max(0, root.cursorIndex)])
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        anchors.fill: parent
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: column
          width: parent.width
          spacing: Style.space(12)

          Item {
            width: parent.width
            implicitHeight: Math.max(backButton.implicitHeight, title.implicitHeight)

            Button {
              id: backButton
              visible: root.current !== null
              iconText: "󰁍"
              tooltipText: root.t("Volver")
              foreground: root.barForeground
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              onClicked: root.back()
            }

            Text {
              id: title
              textFormat: Text.PlainText
              text: root.current ? root.current.title : "Omarchy Tool"
              color: root.barForeground
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
              anchors.left: root.current ? backButton.right : parent.left
              anchors.leftMargin: root.current ? Style.space(6) : 0
              anchors.verticalCenter: parent.verticalCenter
            }

          }

          PanelSeparator { foreground: root.barForeground }

          // List: one button per module, a header where a group starts.
          Repeater {
            model: root.listModules

            Column {
              required property var modelData
              required property int index
              readonly property bool on: root.moduleStatus(modelData.id).enabled === true
              readonly property bool groupStart: !root.current && (index === 0 || root.listModules[index - 1].group !== modelData.group)
              width: column.width
              spacing: Style.space(6)

              PanelSectionHeader {
                visible: parent.groupStart
                text: String(modelData.group || "").toUpperCase()
                foreground: root.barForeground
                topPadding: parent.index === 0 ? Math.ceil(fontSize * 0.15) : Style.space(8)
              }

              ModuleButton {
                width: parent.width
                title: modelData.title
                hint: modelData.hint || ""
                checked: parent.on
                switchable: modelData.switchable !== false
                hasCursor: root.cursorIndex === parent.index
                onClicked: root.openModule(modelData)
                onToggled: root.run([modelData.id, parent.on ? "disable" : "enable"])
              }
            }
          }

          // Page: the open module.
          Loader {
            width: parent.width
            // A Loader keeps the size of the page it last held; hidden, the
            // Column leaves no gap, so the list shrinks back after a page.
            visible: active
            height: active && item ? item.implicitHeight : 0
            active: root.current !== null && root.current.id !== "extras"
            source: active ? Qt.resolvedUrl(root.current.source) : ""
            onLoaded: {
              var id = root.current.id
              item.tool = root
              item.status = Qt.binding(function() { return root.moduleStatus(id) })
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.error !== ""
            text: root.error
            color: Commons.Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
            width: parent.width
          }
        }
      }
    }
  }

  // A module's entry in the list: its name and an on/off switch. The switch
  // runs `<module> enable|disable`; the rest of the row opens the module's
  // page. A module with nothing to turn on (`switchable: false`) shows a
  // chevron instead and the whole row opens it. Same fill, border and cursor tokens as the kit's Toggle rows.
  component ModuleButton: BorderSurface {
    id: entry

    property string title: ""
    property string hint: ""
    property bool checked: false
    property bool switchable: true
    property bool hasCursor: false
    readonly property color fg: root.barForeground
    readonly property bool hot: hasCursor || mouse.containsMouse || toggle.containsMouse
    readonly property var spec: Border.controlSpec(activeFocus ? "focus" : (hot ? "hover-cursor" : "normal"), fg, Commons.Color.accent)

    signal clicked()
    signal toggled()

    activeFocusOnTab: true
    Keys.onReturnPressed: entry.clicked()
    Keys.onEnterPressed: entry.clicked()
    Keys.onSpacePressed: entry.switchable ? entry.toggled() : entry.clicked()

    implicitHeight: Math.max(48, Math.max(toggle.implicitHeight, labels.implicitHeight) + Style.spacing.huge)
    radius: Style.cornerRadius
    color: Style.controlFill(activeFocus, hot, fg, Commons.Color.accent)
    borderSpec: spec

    Behavior on color { ColorAnimation { duration: 100 } }

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: entry.clicked()
    }

    Column {
      id: labels
      anchors.left: parent.left
      anchors.right: entry.switchable ? toggle.left : chevron.left
      anchors.leftMargin: entry.borderLeft + Style.spacing.rowPaddingX
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.xs

      Text {
        textFormat: Text.PlainText
        text: entry.title
        color: entry.fg
        font.family: Style.font.family
        font.pixelSize: Style.font.subtitle
        font.bold: true
        elide: Text.ElideRight
        width: parent.width
      }

      Text {
        textFormat: Text.PlainText
        visible: entry.hint !== ""
        text: entry.hint
        color: Qt.darker(entry.fg, 1.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        width: parent.width
      }
    }

    Text {
      id: chevron
      visible: !entry.switchable
      textFormat: Text.PlainText
      text: "›"
      color: Qt.darker(entry.fg, 1.3)
      font.family: Style.font.family
      font.pixelSize: Style.font.subtitle
      anchors.right: parent.right
      anchors.rightMargin: entry.borderRight + Style.spacing.rowPaddingX
      anchors.verticalCenter: parent.verticalCenter
    }

    ToggleSwitch {
      id: toggle
      visible: entry.switchable
      checked: entry.checked
      cursorRing: false
      foreground: entry.fg
      anchors.right: parent.right
      anchors.rightMargin: entry.borderRight + Style.spacing.rowPaddingX
      anchors.verticalCenter: parent.verticalCenter
      onToggled: entry.toggled()
    }
  }
}
