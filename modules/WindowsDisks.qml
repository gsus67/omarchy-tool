import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Module: windows-disks. Switch on to open the Omarchy Windows VM with the
// ticked disks attached; tick mounted disks or add any folder by path.
Column {
  id: root

  property var tool: null
  property var status: ({})

  readonly property color fg: tool ? tool.barForeground : Commons.Color.foreground
  readonly property bool enabled: status.enabled === true
  readonly property bool vmInstalled: status.vmInstalled === true

  // Mounted disks first, then saved folders that are not a mounted disk
  // (custom paths, or a disk that is unplugged right now).
  readonly property var rows: {
    var list = []
    var seen = {}
    var candidates = status.candidates || []
    var disks = status.disks || []
    var savedNames = {}
    for (var d = 0; d < disks.length; d++) savedNames[disks[d].path] = disks[d]
    for (var i = 0; i < candidates.length; i++) {
      var c = candidates[i]
      seen[c.path] = true
      var saved = savedNames[c.path]
      list.push({
        path: c.path,
        name: saved ? saved.name : (c.label || c.path.split("/").pop()),
        detail: c.path + (c.size ? " · " + c.size : ""),
        selected: c.selected === true,
        label: c.label || ""
      })
    }
    for (var j = 0; j < disks.length; j++) {
      if (seen[disks[j].path]) continue
      list.push({
        path: disks[j].path,
        name: disks[j].name,
        detail: disks[j].path + (disks[j].available ? "" : " · no conectado"),
        selected: true,
        label: ""
      })
    }
    return list
  }

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(8)

  function run(args) {
    if (tool) tool.run(args)
  }

  function addPath() {
    var path = pathField.text.trim()
    if (path === "") return
    run(["windows-disks", "add", path])
    pathField.text = ""
  }

  PanelSectionHeader {
    text: "WINDOWS · DISCOS"
    foreground: root.fg
  }

  Toggle {
    width: parent.width
    label: "Abrir Windows con mis discos"
    description: root.vmInstalled
      ? "Al abrir Windows desde Omarchy se conectan los discos marcados."
      : "Instala Windows desde el menú de Omarchy para usar esto."
    checked: root.enabled
    foreground: root.fg
    onClicked: root.run(["windows-disks", root.enabled ? "disable" : "enable"])
  }

  Text {
    textFormat: Text.PlainText
    text: "Discos"
    color: Qt.darker(root.fg, 1.4)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    font.bold: true
    topPadding: Style.space(4)
  }

  Text {
    textFormat: Text.PlainText
    visible: root.rows.length === 0
    text: "No hay discos montados en /mnt, /media o /run/media."
    color: Qt.darker(root.fg, 1.5)
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.Wrap
    width: parent.width
  }

  Repeater {
    model: root.rows

    Toggle {
      required property var modelData
      width: root.width
      label: modelData.name
      description: modelData.detail
      checked: modelData.selected
      foreground: root.fg
      opacity: root.enabled ? 1 : 0.6
      onClicked: modelData.selected
        ? root.run(["windows-disks", "remove", modelData.path])
        : root.run(["windows-disks", "add", modelData.path].concat(modelData.label ? [modelData.label] : []))
    }
  }

  Row {
    width: parent.width
    spacing: Style.space(8)

    TextField {
      id: pathField
      width: parent.width - addButton.width - parent.spacing
      placeholderText: "Otra carpeta, ej. /mnt/juegos"
      foreground: root.fg
      onAccepted: root.addPath()
      onActiveFocusChanged: if (root.tool) root.tool.typing = activeFocus
      Keys.onEscapePressed: { focus = false; if (root.tool) root.tool.close() }
    }

    Button {
      id: addButton
      text: "Añadir"
      bordered: true
      foreground: root.fg
      anchors.verticalCenter: pathField.verticalCenter
      onClicked: root.addPath()
    }
  }
}
