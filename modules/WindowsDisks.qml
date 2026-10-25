import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Module: windows-disks page. The on/off switch lives on the panel's list;
// here the user ticks up to two mounted disks (or any folder by path). Each
// one shows the \\host.lan share it becomes inside Windows.
Column {
  id: root

  property var tool: null
  property var status: ({})

  readonly property color fg: tool ? tool.barForeground : Commons.Color.foreground
  readonly property bool active: status.enabled === true
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
    function detail(path, extra, saved) {
      var text = saved && saved.share ? saved.share + " · " + path : path
      return text + extra
    }
    for (var i = 0; i < candidates.length; i++) {
      var c = candidates[i]
      seen[c.path] = true
      var saved = savedNames[c.path]
      list.push({
        path: c.path,
        name: saved ? saved.name : (c.label || c.path.split("/").pop()),
        detail: detail(c.path, c.size ? " · " + c.size : "", saved),
        selected: c.selected === true,
        label: c.label || ""
      })
    }
    for (var j = 0; j < disks.length; j++) {
      if (seen[disks[j].path]) continue
      list.push({
        path: disks[j].path,
        name: disks[j].name,
        detail: detail(disks[j].path, disks[j].available ? "" : " · no conectado", disks[j]),
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

  Text {
    textFormat: Text.PlainText
    text: root.vmInstalled
      ? "Marca hasta 2 discos. En Windows salen en \\\\host.lan, junto a la carpeta Shared. Los cambios piden tu contraseña y se ven al volver a abrir Windows."
      : "Instala Windows desde el menú de Omarchy para usar esto."
    color: Qt.darker(root.fg, 1.5)
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.Wrap
    width: parent.width
  }

  Text {
    textFormat: Text.PlainText
    text: "Discos (" + (root.status.disks ? root.status.disks.length : 0) + " de " + (root.status.max || 2) + ")"
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
      opacity: root.active ? 1 : 0.6
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

  // Drive letters: picked here, set inside Windows by "Activar discos".
  Text {
    textFormat: Text.PlainText
    visible: root.active && (root.status.disks || []).length > 0
    text: "Letras en Windows"
    color: Qt.darker(root.fg, 1.4)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    font.bold: true
    topPadding: Style.space(4)
  }

  Repeater {
    model: root.active ? (root.status.disks || []) : []

    Item {
      required property var modelData
      width: root.width
      implicitHeight: letterButton.implicitHeight

      Text {
        textFormat: Text.PlainText
        text: modelData.name + "  ·  " + modelData.share
        color: root.fg
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
        anchors.left: parent.left
        anchors.right: letterButton.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
      }

      Button {
        id: letterButton
        text: modelData.letter + ":"
        tooltipText: "Cambiar letra"
        bordered: true
        foreground: root.fg
        anchors.right: parent.right
        onClicked: root.run(["windows-disks", "letter", modelData.path, "next"])
      }
    }
  }

  Text {
    textFormat: Text.PlainText
    visible: root.active && (root.status.disks || []).length > 0
    text: root.status.lettersSet
      ? "Si cambias letras o discos, vuelve a abrir \"Activar discos\" en Windows."
      : "Para que salgan con su letra, abre una vez en Windows: escritorio › Shared › Omarchy Tool › Activar discos."
    color: Qt.darker(root.fg, 1.5)
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.Wrap
    width: parent.width
  }
}
