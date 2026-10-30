import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Module: network-ip. The switch lives in Extras; IP and DNS are set per
// adapter from Omarchy's menu (Setup › Network › IP and › DNS), so this page
// only shows each adapter and offers the way back to DHCP.
Column {
  id: root

  property var tool: null
  property var status: ({})
  function t(source) { return tool ? tool.t(source) : source }

  readonly property color fg: tool ? tool.barForeground : Commons.Color.foreground
  readonly property bool active: status.enabled === true
  readonly property var network: status.network || ({})
  readonly property var adapters: network.adapters || []

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(8)

  function modeText(mode) {
    return mode === "Custom" ? root.t("fija") : mode
  }

  Text {
    textFormat: Text.PlainText
    text: root.t("Elige el adaptador y cambia su IP o sus DNS desde el menú de Omarchy: Setup › Network › IP y Setup › Network › DNS.")
    color: Qt.darker(root.fg, 1.5)
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.Wrap
    width: parent.width
  }

  Text {
    visible: root.active && root.network.globalDns && root.network.globalDns !== "DHCP"
    textFormat: Text.PlainText
    text: root.t("Los DNS de Omarchy están en %1 para todos los adaptadores; ponlos en DHCP para elegirlos por adaptador.").replace("%1", root.network.globalDns || "")
    color: root.fg
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.Wrap
    width: parent.width
  }

  Repeater {
    model: root.active ? root.adapters : []

    Column {
      required property var modelData
      width: root.width
      spacing: Style.space(4)

      Text {
        textFormat: Text.PlainText
        text: (modelData.type === "wifi" ? "Wi-Fi" : "Ethernet") + " (" + modelData.device + ")"
        color: root.fg
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }

      Text {
        textFormat: Text.PlainText
        text: modelData.connected
          ? "IP " + root.modeText(modelData.ip) + ": " + modelData.address
            + (modelData.gateway ? root.t(" · puerta de enlace ") + modelData.gateway : "")
            + " · DNS " + modelData.dns
          : root.t("Sin conexión")
        color: Qt.darker(root.fg, 1.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.Wrap
        width: parent.width
      }

      Button {
        visible: modelData.connected === true && modelData.ip === "Custom"
        text: root.t("Volver a DHCP")
        bordered: true
        foreground: root.fg
        onClicked: if (root.tool) root.tool.run(["network-ip", "dhcp", modelData.device])
      }
    }
  }
}
