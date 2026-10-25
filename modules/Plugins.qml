import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Module: plugins page, with no switch of its own on the panel's list: each
// installed plugin has its own switch here, through `omarchy plugin
// enable|disable`. Plugins added later show up by themselves.
Column {
  id: root

  property var tool: null
  property var status: ({})
  function t(source) { return tool ? tool.t(source) : source }

  readonly property color fg: tool ? tool.barForeground : Commons.Color.foreground
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

    Loader {
      required property var modelData
      width: root.width
      sourceComponent: modelData.toggleable === false ? fixedRow : switchRow

      Component {
        id: switchRow
        Toggle {
          label: modelData.name
          description: root.kindText(modelData.kinds)
          checked: modelData.enabled === true
          foreground: root.fg
          onClicked: root.run(["plugins", modelData.enabled ? "off" : "on", modelData.id])
        }
      }

      // A full bar can't be turned off, only swapped with `omarchy bar use`:
      // same row, no switch.
      Component {
        id: fixedRow
        BorderSurface {
          implicitHeight: Math.max(54, fixedLabels.implicitHeight + Style.spacing.huge)
          radius: Style.cornerRadius
          color: Style.controlFill(false, false, root.fg, Commons.Color.accent)
          borderSpec: Border.controlSpec("normal", root.fg, Commons.Color.accent)

          Column {
            id: fixedLabels
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: parent.borderLeft + Style.spacing.rowPaddingX
            anchors.rightMargin: parent.borderRight + Style.spacing.rowPaddingX
            spacing: Style.spacing.xs

            Text {
              textFormat: Text.PlainText
              text: modelData.name
              color: root.fg
              font.family: Style.font.family
              font.pixelSize: Style.font.subtitle
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: modelData.enabled ? root.t("Barra completa · en uso") : root.t("Barra completa · se elige con omarchy bar use")
              color: Qt.darker(root.fg, 1.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              width: parent.width
            }
          }
        }
      }
    }
  }
}
