import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Module: usb-windows page. The on/off switch lives on the panel's list;
// here the user ticks which connected USB devices Windows takes over while
// it runs, for Windows-only apps like Glorious CORE.
Column {
  id: root

  property var tool: null
  property var status: ({})

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
      list.push({ id: devices[j].id, name: devices[j].name, detail: devices[j].id + " · no conectado", selected: true })
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
    text: root.status.vmInstalled === false
      ? "Instala Windows desde el menú de Omarchy para usar esto."
      : "Para apps que solo existen en Windows (Glorious CORE, iCUE...). Con el interruptor encendido, Windows queda preparado la próxima vez que lo abras; los dispositivos siguen en Linux hasta que pulses \"Pasar a Windows\". Mientras estén en Windows, Linux no los tiene."
    color: Qt.darker(root.fg, 1.5)
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.Wrap
    width: parent.width
  }

  Text {
    textFormat: Text.PlainText
    text: "Dispositivos USB (" + (root.status.devices ? root.status.devices.length : 0) + " de " + (root.status.max || 4) + ")"
    color: Qt.darker(root.fg, 1.4)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    font.bold: true
    topPadding: Style.space(4)
  }

  Text {
    textFormat: Text.PlainText
    visible: root.rows.length === 0
    text: "No hay dispositivos USB conectados."
    color: Qt.darker(root.fg, 1.5)
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.Wrap
    width: parent.width
  }

  Text {
    textFormat: Text.PlainText
    visible: root.active
    text: "Sin ratón: SUPER + ALT + U devuelve a Linux todo lo que esté en Windows, aunque Windows tenga el teclado."
    color: root.fg
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    font.bold: true
    wrapMode: Text.Wrap
    width: parent.width
  }

  Text {
    textFormat: Text.PlainText
    text: "No pases a Windows el teclado o el ratón que estás usando si no tienes otro a mano, ni el Bluetooth: Linux los pierde mientras estén allí."
    color: Commons.Color.urgent
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
      onClicked: root.run(["usb-windows", modelData.selected ? "remove" : "add", modelData.id])
    }
  }

  // While Windows runs: hand each device back and forth without closing it.
  Text {
    textFormat: Text.PlainText
    visible: root.active && root.status.vmRunning === true && (root.status.devices || []).length > 0
    text: "Windows está abierto"
    color: Qt.darker(root.fg, 1.4)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    font.bold: true
    topPadding: Style.space(4)
  }

  Text {
    textFormat: Text.PlainText
    visible: root.active && root.status.vmRunning === true && root.status.liveReady !== true
    text: "Windows se abrió antes de preparar esto: ciérralo y ábrelo una vez para poder pasarle dispositivos."
    color: Qt.darker(root.fg, 1.5)
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.Wrap
    width: parent.width
  }

  Repeater {
    model: root.active && root.status.liveReady === true ? (root.status.devices || []) : []

    Item {
      required property var modelData
      width: root.width
      implicitHeight: moveButton.implicitHeight

      Text {
        textFormat: Text.PlainText
        text: modelData.name + (modelData.inWindows ? "  ·  en Windows" : "  ·  en Linux")
        color: root.fg
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
        anchors.left: parent.left
        anchors.right: moveButton.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
      }

      Button {
        id: moveButton
        text: modelData.inWindows ? "Devolver a Linux" : "Pasar a Windows"
        bordered: true
        foreground: root.fg
        anchors.right: parent.right
        onClicked: root.run(["usb-windows", "move", modelData.inWindows ? "linux" : "windows", modelData.id])
      }
    }
  }
}
