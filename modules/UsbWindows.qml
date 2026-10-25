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
      list.push({ id: candidates[i].id, name: candidates[i].name, selected: candidates[i].selected === true,
        detail: candidates[i].id + (root.status.vmRunning ? (candidates[i].inWindows ? " · en Windows" : " · en Linux") : "") })
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
      : "Para apps que solo existen en Windows (Glorious CORE, iCUE...). Enciende un dispositivo y pasa a Windows: al momento si está abierto, o en cuanto lo abras. Apágalo y vuelve a Linux. Mientras esté en Windows, Linux no lo tiene."
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
    text: "Para devolverlo todo a Linux sin ratón: SUPER + ALT + U (funciona aunque Windows tenga el teclado), o dentro de Windows abre Shared › Omarchy Tool › Periféricos › Devolver periféricos a Linux."
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

  Text {
    textFormat: Text.PlainText
    visible: root.active && root.status.vmRunning === true && root.status.liveReady !== true
    text: "Windows se abrió antes de preparar esto: ciérralo y ábrelo una vez para poder pasarle dispositivos."
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
}
