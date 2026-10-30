import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Module: network-ip. The switch lives in Extras; the IP itself is set from
// Omarchy's menu (Setup › Network › IP), so this page only shows the active
// connection and offers the way back to DHCP.
Column {
  id: root

  property var tool: null
  property var status: ({})
  function t(source) { return tool ? tool.t(source) : source }

  readonly property color fg: tool ? tool.barForeground : Commons.Color.foreground
  readonly property bool active: status.enabled === true
  readonly property var network: status.network || ({})

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(8)

  Text {
    textFormat: Text.PlainText
    text: root.t("Pon una IP fija o vuelve a DHCP desde el menú de Omarchy: Setup › Network › IP, junto a DNS.")
    color: Qt.darker(root.fg, 1.5)
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.Wrap
    width: parent.width
  }

  Text {
    visible: root.active
    textFormat: Text.PlainText
    text: root.network.connection
      ? root.network.connection + " · " + (root.network.mode === "Custom" ? root.t("IP fija") : root.network.mode) + "\n"
        + root.network.address + (root.network.gateway ? root.t(" · puerta de enlace ") + root.network.gateway : "")
      : root.t("No hay ninguna conexión por cable o Wi-Fi activa.")
    color: root.fg
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.Wrap
    width: parent.width
  }

  Button {
    visible: root.active && root.network.mode === "Custom"
    text: root.t("Volver a DHCP")
    bordered: true
    foreground: root.fg
    onClicked: if (root.tool) root.tool.run(["network-ip", "dhcp"])
  }
}
