import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Omarchy Tool: one bar icon, one panel, a stack of switchable modules.
//
// All state and side effects live in bin/omarchy-tool; this file only shows
// `omarchy-tool status` and runs module actions. Each module's UI is a QML
// file under modules/ that receives `status` (its slice of the status JSON)
// and calls `tool.run([...])`. Add a module by listing it in `modules` below.
Panel {
  id: root
  moduleName: "gsus.tool"
  ipcTarget: "gsus.tool"

  readonly property var modules: [
    { id: "windows-disks", source: "modules/WindowsDisks.qml" }
  ]

  readonly property string toolPath: decodeURIComponent(String(Qt.resolvedUrl("bin/omarchy-tool")).replace(/^file:\/\//, ""))
  property var status: ({})
  property string error: ""
  property bool busy: false
  property var queue: []

  function moduleStatus(id) {
    var mods = status && status.modules ? status.modules : null
    return mods && mods[id] ? mods[id] : ({})
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

  onOpenedChanged: if (opened) refresh()

  // Re-sync side effects at shell start: Omarchy may have rewritten the
  // Windows entry (reinstall) while the shell was down.
  Component.onCompleted: run(["apply"])

  Process {
    id: statusProc
    command: [root.toolPath, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.status = JSON.parse(text)
        } catch (e) {
          root.error = "No se pudo leer el estado del plugin"
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
      onCloseRequested: root.close()
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

          Row {
            width: parent.width
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              text: "Omarchy Tool"
              color: root.barForeground
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              textFormat: Text.PlainText
              text: root.status.version ? "v" + root.status.version : ""
              color: Qt.darker(root.barForeground, 1.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          Repeater {
            model: root.modules

            Column {
              required property var modelData
              width: column.width
              spacing: Style.space(10)

              PanelSeparator { foreground: root.barForeground }

              Loader {
                width: parent.width
                source: Qt.resolvedUrl(modelData.source)
                onLoaded: {
                  item.tool = root
                  item.status = Qt.binding(function() { return root.moduleStatus(modelData.id) })
                }
              }
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

  // Modules set this while a text field has focus so typed keys reach it.
  property bool typing: false
}
