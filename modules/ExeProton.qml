import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Module: exe-proton. The switch lives in Extras.
Column {
  id: root

  property var tool: null
  property var status: ({})
  function t(source) { return tool ? tool.t(source) : source }

  readonly property color fg: tool ? tool.barForeground : Commons.Color.foreground
  width: parent ? parent.width : implicitWidth
  spacing: Style.space(8)

  Text {
    textFormat: Text.PlainText
    text: root.t("Abre programas de Windows (.exe/.msi) con doble clic para ejecutarlos con GE-Proton.")
    color: Qt.darker(root.fg, 1.5)
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.Wrap
    width: parent.width
  }
}
