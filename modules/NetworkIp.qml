import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Module: network-ip. The switch lives in Extras. Each connected adapter gets
// IP (DHCP or static) and DNS (DHCP, Cloudflare, Google or own servers)
// buttons here, the same choices its rows offer in Omarchy's menu (Setup ›
// Network › IP and › DNS). Values go to the backend as plain arguments and
// the helper validates them.
Column {
  id: root

  property var tool: null
  property var status: ({})
  function t(source) { return tool ? tool.t(source) : source }

  readonly property color fg: tool ? tool.barForeground : Commons.Color.foreground
  readonly property bool active: status.enabled === true
  readonly property var network: status.network || ({})
  readonly property var adapters: network.adapters || []
  // Omarchy's DNS for every adapter overrides each adapter's own.
  readonly property bool dnsPerAdapter: !network.globalDns || network.globalDns === "DHCP"

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(8)

  function run(args) {
    if (tool) tool.run(["network-ip"].concat(args))
  }

  Text {
    textFormat: Text.PlainText
    text: root.t("Cambia la IP y los DNS de cada adaptador aquí o desde el menú de Omarchy: Setup › Network › IP y Setup › Network › DNS.")
    color: Qt.darker(root.fg, 1.5)
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.Wrap
    width: parent.width
  }

  Text {
    visible: root.active && !root.dnsPerAdapter
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
      id: card
      required property var modelData
      // "" | "ip" | "dns": which inline editor is open.
      property string editing: ""
      readonly property string device: modelData.device

      width: root.width
      spacing: Style.space(6)

      function apply(args) {
        editing = ""
        if (root.tool) root.tool.typing = false
        root.run(args)
      }

      PanelSeparator { foreground: root.fg }

      Text {
        textFormat: Text.PlainText
        text: (card.modelData.type === "wifi" ? "Wi-Fi" : "Ethernet") + " (" + card.device + ")"
          + (card.modelData.connected ? " · " + card.modelData.connection : "")
        color: root.fg
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        elide: Text.ElideRight
        width: parent.width
      }

      Text {
        textFormat: Text.PlainText
        text: card.modelData.connected
          ? card.modelData.address + (card.modelData.gateway ? root.t(" · puerta de enlace ") + card.modelData.gateway : "")
          : root.t("Sin conexión")
        color: Qt.darker(root.fg, 1.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.Wrap
        width: parent.width
      }

      // IP: DHCP or a static address.
      Row {
        visible: card.modelData.connected === true
        spacing: Style.space(6)

        Text {
          textFormat: Text.PlainText
          text: "IP"
          width: Style.space(40)
          anchors.verticalCenter: parent.verticalCenter
          color: Qt.darker(root.fg, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }

        Button {
          text: "DHCP"
          bordered: true
          fontSize: Style.font.bodySmall
          foreground: root.fg
          active: card.modelData.ip === "DHCP"
          onClicked: if (card.modelData.ip !== "DHCP") card.apply(["ip", card.device, "DHCP"])
        }

        Button {
          text: root.t("Fija")
          bordered: true
          fontSize: Style.font.bodySmall
          foreground: root.fg
          active: card.modelData.ip === "Custom"
          onClicked: card.editing = card.editing === "ip" ? "" : "ip"
        }
      }

      Row {
        visible: card.editing === "ip"
        width: parent.width
        spacing: Style.space(6)

        TextField {
          id: addressField
          width: (parent.width - parent.spacing) * 0.55
          text: card.modelData.address || ""
          placeholderText: "192.168.1.20/24"
          foreground: root.fg
          onAccepted: gatewayField.forceActiveFocus()
          onActiveFocusChanged: if (root.tool) root.tool.typing = activeFocus
        }

        TextField {
          id: gatewayField
          width: (parent.width - parent.spacing) * 0.45
          text: card.modelData.gateway || ""
          placeholderText: root.t("Puerta de enlace")
          foreground: root.fg
          onAccepted: card.apply(["ip", card.device, "Custom", addressField.text.trim(), gatewayField.text.trim()])
          onActiveFocusChanged: if (root.tool) root.tool.typing = activeFocus
        }
      }

      Row {
        visible: card.editing === "ip"
        spacing: Style.space(6)

        Button {
          text: root.t("Aplicar")
          bordered: true
          foreground: root.fg
          onClicked: card.apply(["ip", card.device, "Custom", addressField.text.trim(), gatewayField.text.trim()])
        }

        Button {
          text: root.t("Cancelar")
          bordered: true
          foreground: root.fg
          onClicked: { card.editing = ""; if (root.tool) root.tool.typing = false }
        }
      }

      // DNS for this adapter only.
      Row {
        visible: card.modelData.connected === true
        spacing: Style.space(6)
        opacity: root.dnsPerAdapter ? 1 : 0.5

        Text {
          textFormat: Text.PlainText
          text: "DNS"
          width: Style.space(40)
          anchors.verticalCenter: parent.verticalCenter
          color: Qt.darker(root.fg, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }

        Repeater {
          model: ["DHCP", "Cloudflare", "Google"]

          Button {
            required property string modelData
            text: modelData
            bordered: true
            fontSize: Style.font.bodySmall
            foreground: root.fg
            active: card.modelData.dns === modelData
            onClicked: if (root.dnsPerAdapter && card.modelData.dns !== modelData) card.apply(["dns", card.device, modelData])
          }
        }

        Button {
          text: "Custom"
          bordered: true
          fontSize: Style.font.bodySmall
          foreground: root.fg
          active: card.modelData.dns === "Custom"
          onClicked: if (root.dnsPerAdapter) card.editing = card.editing === "dns" ? "" : "dns"
        }
      }

      Row {
        visible: card.editing === "dns"
        width: parent.width
        spacing: Style.space(6)

        TextField {
          id: serversField
          width: parent.width - dnsApply.width - dnsCancel.width - parent.spacing * 2
          text: card.modelData.dns === "Custom" ? (card.modelData.dnsServers || "") : ""
          placeholderText: "9.9.9.9 149.112.112.112"
          foreground: root.fg
          onAccepted: card.apply(["dns", card.device, "Custom", serversField.text.trim()])
          onActiveFocusChanged: if (root.tool) root.tool.typing = activeFocus
        }

        Button {
          id: dnsApply
          text: root.t("Aplicar")
          bordered: true
          foreground: root.fg
          anchors.verticalCenter: serversField.verticalCenter
          onClicked: card.apply(["dns", card.device, "Custom", serversField.text.trim()])
        }

        Button {
          id: dnsCancel
          text: root.t("Cancelar")
          bordered: true
          foreground: root.fg
          anchors.verticalCenter: serversField.verticalCenter
          onClicked: { card.editing = ""; if (root.tool) root.tool.typing = false }
        }
      }
    }
  }
}
