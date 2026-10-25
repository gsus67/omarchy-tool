import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Module: plugins page. The on/off switch lives on the panel's list; here
// each installed plugin has its own switch, through `omarchy plugin
// enable|disable`. Plugins added later show up by themselves.
Column {
  id: root

  property var tool: null
  property var status: ({})
  function t(source) { return tool ? tool.t(source) : source }

  readonly property color fg: tool ? tool.barForeground : Commons.Color.foreground
  readonly property bool active: status.enabled === true
  readonly property var plugins: status.plugins || []

  function kindText(kinds) {
    var list = kinds || []
    if (list.indexOf("bar-widget") !== -1) return root.t("Icono en la barra")
    if (list.indexOf("panel") !== -1) return root.t("Panel")
    if (list.indexOf("service") !== -1) return root.t("Servicio")
    return list.join(", ")
  }

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(8)

  function run(args) {
    if (tool) tool.run(args)
  }

  Text {
    textFormat: Text.PlainText
    text: root.t("Activa o desactiva tus plugins instalados. Al desactivar un icono de la barra se recuerda su sitio y vuelve ahí al activarlo.")
    color: Qt.darker(root.fg, 1.5)
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.Wrap
    width: parent.width
  }

  Text {
    textFormat: Text.PlainText
    text: root.t("Plugins instalados")
    color: Qt.darker(root.fg, 1.4)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    font.bold: true
    topPadding: Style.space(4)
  }

  Text {
    textFormat: Text.PlainText
    visible: root.plugins.length === 0
    text: root.t("No hay otros plugins instalados.")
    color: Qt.darker(root.fg, 1.5)
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.Wrap
    width: parent.width
  }

  Repeater {
    model: root.plugins

    Toggle {
      required property var modelData
      width: root.width
      label: modelData.name
      description: root.kindText(modelData.kinds)
      checked: modelData.enabled === true
      foreground: root.fg
      enabled: root.active
      opacity: root.active ? 1 : 0.6
      onClicked: root.run(["plugins", modelData.enabled ? "off" : "on", modelData.id])
    }
  }
}
