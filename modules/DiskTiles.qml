import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Column {
  id: root
  property var tool: null
  property var status: ({})
  readonly property color fg: tool ? tool.barForeground : Commons.Color.foreground
  width: parent ? parent.width : implicitWidth
  spacing: Style.space(8)
  Text {
    textFormat: Text.PlainText
    text: root.tool ? root.tool.t("Abre Archivos en Este equipo: discos en mosaicos con espacio libre y total. Las carpetas se abren normalmente. Compatible con Nautilus 50 y 51.") : ""
    color: Qt.darker(root.fg, 1.5)
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.Wrap
    width: parent.width
  }
  Text {
    textFormat: Text.PlainText
    text: root.tool ? root.tool.t("Después de activarlo, cierra todas las ventanas de Archivos y vuelve a abrirlo. Al desactivarlo se retiran la vista y el acceso Este equipo.") : ""
    color: Qt.darker(root.fg, 1.5)
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.Wrap
    width: parent.width
  }
}
