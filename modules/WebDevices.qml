import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Module: web-devices page. The on/off switch lives on the panel's list;
// here the user ticks which connected USB devices the browser may talk to,
// for web configurators like CORSAIR Web Hub.
Column {
  id: root

  property var tool: null
  property var status: ({})
  function t(source) { return tool ? tool.t(source) : source }

  readonly property color fg: tool ? tool.barForeground : Commons.Color.foreground
  readonly property bool active: status.enabled === true

  // Connected devices first, then saved ones that are unplugged right now.
  readonly property var rows: {
    var list = []
    var seen = {}
    var candidates = status.candidates || []
    var devices = status.devices || []
    for (var i = 0; i < candidates.length; i++) {
      seen[candidates[i].id] = true
      list.push({ id: candidates[i].id, name: candidates[i].name, detail: candidates[i].id, selected: candidates[i].selected === true })
    }
    for (var j = 0; j < devices.length; j++) {
      if (seen[devices[j].id]) continue
      list.push({ id: devices[j].id, name: devices[j].name, detail: devices[j].id + root.t(" · no conectado"), selected: true })
    }
    return list
  }

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(8)

  function run(args) {
    if (tool) tool.run(args)
  }

  Text {
    textFormat: Text.PlainText
    text: root.t("Deja que el navegador configure estos dispositivos, para páginas como CORSAIR Web Hub. Solo tu sesión tiene acceso. Los cambios piden tu contraseña; después recarga la página y dale a conectar.")
    color: Qt.darker(root.fg, 1.5)
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.Wrap
    width: parent.width
  }

  Text {
    textFormat: Text.PlainText
    text: root.t("Dispositivos USB")
    color: Qt.darker(root.fg, 1.4)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    font.bold: true
    topPadding: Style.space(4)
  }

  Text {
    textFormat: Text.PlainText
    visible: root.rows.length === 0
    text: root.t("No hay dispositivos USB de este tipo conectados.")
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
      onClicked: root.run(["web-devices", modelData.selected ? "remove" : "add", modelData.id])
    }
  }
}
