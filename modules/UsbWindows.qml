import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Module: usb-windows page, laid out like the other pages (Discos en
// Windows): a short note, a section header, standard Toggle rows, buttons.
// The on/off switch lives on the panel's list; here each connected USB device
// has its own switch: on means "in Windows".
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
      var c = candidates[i]
      seen[c.id] = true
      list.push({ id: c.id, name: c.name, selected: c.selected === true,
        detail: c.id + (root.status.vmRunning && c.inWindows ? " · en Windows" : "") })
    }
    for (var j = 0; j < devices.length; j++) {
      if (seen[devices[j].id]) continue
      list.push({ id: devices[j].id, name: devices[j].name, selected: true, detail: devices[j].id + " · no conectado" })
    }
    return list
  }

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(8)

  function run(args) {
    if (tool) tool.run(args)
  }

  component Note: Text {
    textFormat: Text.PlainText
    color: Qt.darker(root.fg, 1.5)
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.Wrap
    width: root.width
  }

  component Header: Text {
    textFormat: Text.PlainText
    color: Qt.darker(root.fg, 1.4)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    font.bold: true
    topPadding: Style.space(4)
  }

  Note {
    text: root.status.vmInstalled === false
      ? "Instala Windows desde el menú de Omarchy para usar esto."
      : "Enciende un dispositivo y pasa a Windows; apágalo y vuelve a Linux. Devolver todo: SUPER + ALT + U."
  }

  Note {
    visible: root.active && root.status.vmRunning === true && root.status.liveReady !== true
    text: "Cierra y abre Windows una vez para poder pasarle dispositivos."
    color: Commons.Color.urgent
  }

  Header {
    text: "Dispositivos (" + (root.status.devices ? root.status.devices.length : 0) + " de " + (root.status.max || 4) + ")"
  }

  Note {
    visible: root.rows.length === 0
    text: "No hay dispositivos USB conectados."
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

  Note {
    text: "No pases el teclado o ratón que usas, ni el Bluetooth."
    color: Commons.Color.urgent
  }

  // The passed mouse's cursor only shows on Windows' own screen.
  Header {
    visible: root.active
    text: "Ver el cursor"
  }

  Note {
    visible: root.active
    text: root.status.rdpOpen
      ? "Cierra la ventana de Windows y ábrelo en su propia pantalla."
      : "Abre Windows en su propia pantalla, donde se ve el cursor del ratón pasado."
  }

  Row {
    visible: root.active
    spacing: Style.space(8)

    Button {
      text: "Abrir con mi ratón"
      bordered: true
      foreground: root.fg
      opacity: root.status.rdpOpen ? 0.5 : 1
      onClicked: if (!root.status.rdpOpen && root.tool) {
        Quickshell.execDetached([root.tool.toolPath, "usb-windows", "console-open"])
        root.tool.close()
      }
    }

    Button {
      visible: root.status.vmRunning === true && !root.status.rdpOpen
      text: "Apagar Windows"
      bordered: true
      foreground: root.fg
      onClicked: root.run(["usb-windows", "console-close"])
    }
  }
}
