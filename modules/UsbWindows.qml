import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Module: usb-windows page. The on/off switch lives on the panel's list;
// here each connected USB device has its own switch: on means "in Windows".
// Kept short: one compact row per device, one line per hint.
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
        state: root.status.vmRunning ? (c.inWindows ? "en Windows" : "") : "" })
    }
    for (var j = 0; j < devices.length; j++) {
      if (seen[devices[j].id]) continue
      list.push({ id: devices[j].id, name: devices[j].name, selected: true, state: "no conectado" })
    }
    return list
  }

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(6)

  function run(args) {
    if (tool) tool.run(args)
  }

  component Hint: Text {
    textFormat: Text.PlainText
    color: Qt.darker(root.fg, 1.5)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    wrapMode: Text.Wrap
    width: root.width
  }

  Hint {
    visible: root.status.vmInstalled === false
    text: "Instala Windows desde el menú de Omarchy para usar esto."
  }

  Hint {
    text: "Encendido: el dispositivo pasa a Windows. Devolver todo: SUPER + ALT + U."
    color: root.fg
  }

  Hint {
    text: "No pases el teclado o ratón que usas, ni el Bluetooth."
    color: Commons.Color.urgent
  }

  Hint {
    visible: root.active && root.status.vmRunning === true && root.status.liveReady !== true
    text: "Cierra y abre Windows una vez para poder pasarle dispositivos."
    color: Commons.Color.urgent
  }

  Repeater {
    model: root.rows

    // Compact row: name (and where it is) plus its switch.
    BorderSurface {
      id: row
      required property var modelData
      readonly property bool hot: mouse.containsMouse

      width: root.width
      implicitHeight: toggle.implicitHeight + Style.space(4)
      radius: Style.cornerRadius
      color: Style.controlFill(false, hot, root.fg, Commons.Color.accent)
      borderSpec: Border.controlSpec(hot ? "hover-cursor" : "normal", root.fg, Commons.Color.accent)
      opacity: root.active ? 1 : 0.6

      Text {
        textFormat: Text.PlainText
        text: row.modelData.name
        color: root.fg
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        elide: Text.ElideRight
        anchors.left: parent.left
        anchors.right: stateText.left
        anchors.leftMargin: Style.spacing.rowPaddingX
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: stateText
        textFormat: Text.PlainText
        text: row.modelData.state
        color: Commons.Color.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        anchors.right: toggle.left
        anchors.rightMargin: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
      }

      ToggleSwitch {
        id: toggle
        checked: row.modelData.selected
        interactive: false
        cursorRing: false
        foreground: root.fg
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.rowPaddingX
        anchors.verticalCenter: parent.verticalCenter
      }

      MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.run(["usb-windows", row.modelData.selected ? "remove" : "add", row.modelData.id])
      }
    }
  }

  // The passed mouse's cursor only shows on Windows' own screen.
  Hint {
    visible: root.active
    topPadding: Style.space(4)
    text: root.status.rdpOpen
      ? "¿No ves el cursor? Cierra la ventana de Windows y ábrelo aquí:"
      : "¿No ves el cursor? Ábrelo en su propia pantalla:"
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
