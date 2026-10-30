import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Module: exe-proton. The switch lives in Extras. Copies of the prefix's data
// work with the module off, because switching it off keeps the prefix. tool.run
// discards output, so the page reads listings with its own Process; changes go
// through the tool's queue.
Column {
  id: root

  property var tool: null
  property var status: ({})
  function t(source) { return tool ? tool.t(source) : source }

  readonly property color fg: tool ? tool.barForeground : Commons.Color.foreground
  property var listing: ({ prefixExists: false, groups: [], copies: [] })
  property string selectedCopy: ""
  property var preview: null
  property string readError: ""
  // A read's answer only counts if nothing made it stale since it was asked.
  property int readGeneration: 0
  property int listGeneration: 0
  property var activeRead: null
  property var pendingReads: []
  readonly property bool canChange: tool !== null && !tool.busy

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(8)

  onToolChanged: if (tool) requestRead(["saves-list"])
  onListingChanged: if (!folderField.activeFocus) folderField.text = listing.folder || ""

  Connections {
    target: root.tool
    function onBusyChanged() {
      if (!root.tool.busy) root.requestRead(["saves-list"])
    }
  }

  Process {
    id: readProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.finishRead(root.activeRead, text)
    }
    onRunningChanged: if (!running) Qt.callLater(root.pumpRead)
  }

  // One read at a time; the newest request of each kind waits for its turn.
  function requestRead(args) {
    var request = { args: args, generation: args[0] === "saves-list" ? listGeneration : readGeneration }
    pendingReads = pendingReads.filter(function(waiting) { return waiting.args[0] !== args[0] }).concat([request])
    pumpRead()
  }

  function pumpRead() {
    if (readProc.running || activeRead !== null || pendingReads.length === 0) return
    activeRead = pendingReads[0]
    pendingReads = pendingReads.slice(1)
    readProc.command = [tool.toolPath, "exe-proton"].concat(activeRead.args)
    readProc.running = true
  }

  function finishRead(request, output) {
    activeRead = null
    var isList = request.args[0] === "saves-list"
    if (request.generation === (isList ? listGeneration : readGeneration)) {
      var answer = null
      try { answer = JSON.parse(output) } catch (e) { answer = null }
      var failed = answer === null || typeof answer !== "object" || !!answer.error
      if (failed) {
        readError = t(answer && answer.error ? answer.error : "No se pudo leer la copia")
      } else if (isList) {
        readError = ""
        listing = answer
      } else {
        readError = ""
        preview = answer
      }
    }
    Qt.callLater(pumpRead)
  }

  function viewCopy(name) {
    selectedCopy = name
    preview = null
    readError = ""
    readGeneration += 1
    requestRead(["saves-preview", name])
  }

  function cancelView() {
    selectedCopy = ""
    preview = null
    readError = ""
    readGeneration += 1
  }

  // Anything read before a change no longer describes what is on disk.
  function change(args) {
    cancelView()
    listGeneration += 1
    tool.run(["exe-proton"].concat(args))
  }

  function saveData() {
    if (tool && !tool.busy) change(["saves-save"])
  }

  function loadData() {
    if (!tool || tool.busy || activeRead !== null || preview === null || preview.name !== selectedCopy) return
    change(["saves-load", selectedCopy])
  }

  function setFolder(path) {
    if (tool && !tool.busy) change(["saves-folder", path.trim()])
  }

  function setAuto(on) {
    if (tool && !tool.busy) change(["saves-auto", on ? "on" : "off"])
  }

  function formatBytes(bytes) {
    var units = ["B", "KB", "MB", "GB", "TB"]
    var value = bytes
    var unit = 0
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024
      unit += 1
    }
    var shown = unit > 0 && value < 10 ? String(Math.round(value * 10) / 10) : String(Math.round(value))
    return (tool.language === "es" ? shown.replace(".", ",") : shown) + " " + units[unit]
  }

  function areaLabel(area) {
    if (area === "Saved Games") return t("Partidas guardadas")
    if (area === "Documents") return t("Documentos")
    return area
  }

  function formatDate(timestamp) {
    return new Date(timestamp * 1000).toLocaleString(Qt.locale(tool ? tool.language : "en"), Locale.ShortFormat)
  }

  function kindLabel(kind) {
    if (kind === "automatica") return " · " + t("Automática")
    if (kind === "antes-de-cargar") return " · " + t("Copia previa a cargar")
    return ""
  }

  Text {
    textFormat: Text.PlainText
    text: root.t("Abre programas de Windows (.exe/.msi) con doble clic para ejecutarlos con GE-Proton.")
    color: Qt.darker(root.fg, 1.5)
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.Wrap
    width: parent.width
  }

  Column {
    visible: root.listing.prefixExists === true
    width: parent.width
    spacing: Style.space(6)

    PanelSeparator { foreground: root.fg }

    Text {
      textFormat: Text.PlainText
      text: root.t("Partidas y datos")
      color: root.fg
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      width: parent.width
    }

    Text {
      textFormat: Text.PlainText
      text: root.listing.groups && root.listing.groups.length > 0 ? root.t("Guardar incluirá:") : root.t("No hay nada que guardar.")
      color: Qt.darker(root.fg, 1.5)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      width: parent.width
    }

    GroupList {
      model: root.listing.groups || []
    }

    Button {
      text: root.t("Guardar")
      bordered: true
      foreground: root.fg
      enabled: root.canChange && root.listing.groups && root.listing.groups.length > 0
      onClicked: root.saveData()
    }

    PanelSeparator { foreground: root.fg }

    Text {
      textFormat: Text.PlainText
      text: root.t("Carpeta de copias")
      color: root.fg
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      width: parent.width
    }

    Row {
      width: parent.width
      spacing: Style.space(6)

      TextField {
        id: folderField
        width: parent.width - folderApply.width - parent.spacing
        foreground: root.fg
        onAccepted: root.setFolder(folderField.text)
        onActiveFocusChanged: if (root.tool) root.tool.typing = activeFocus
      }

      Button {
        id: folderApply
        text: root.t("Aplicar")
        bordered: true
        foreground: root.fg
        enabled: root.canChange
        anchors.verticalCenter: folderField.verticalCenter
        onClicked: root.setFolder(folderField.text)
      }
    }

    Text {
      visible: root.listing.folderAvailable === false
      textFormat: Text.PlainText
      text: root.t("la carpeta de copias no está disponible; comprueba que el disco esté conectado")
      color: Commons.Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.Wrap
      width: parent.width
    }

    Button {
      text: root.t("Copia automática al encender")
      bordered: true
      fontSize: Style.font.bodySmall
      foreground: root.fg
      active: root.listing.auto === true
      enabled: root.canChange
      onClicked: root.setAuto(root.listing.auto !== true)
    }

    PanelSeparator { foreground: root.fg }

    Text {
      textFormat: Text.PlainText
      text: root.listing.copies && root.listing.copies.length > 0 ? root.t("Copias:") : root.t("Todavía no hay copias.")
      color: root.fg
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      width: parent.width
    }

    Repeater {
      model: root.listing.copies || []

      Column {
        id: copyRow
        required property var modelData
        readonly property bool selected: root.selectedCopy === modelData.name
        readonly property bool previewed: selected && root.preview !== null && root.preview.name === modelData.name

        width: parent.width
        spacing: Style.space(6)

        Row {
          width: parent.width
          spacing: Style.space(6)

          Text {
            textFormat: Text.PlainText
            text: root.formatDate(copyRow.modelData.timestamp) + " · " + root.formatBytes(copyRow.modelData.bytes) + root.kindLabel(copyRow.modelData.kind)
            color: Qt.darker(root.fg, 1.3)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
            width: parent.width - viewButton.width - parent.spacing
            anchors.verticalCenter: viewButton.verticalCenter
          }

          Button {
            id: viewButton
            text: root.t("Ver")
            bordered: true
            fontSize: Style.font.bodySmall
            foreground: root.fg
            active: copyRow.selected
            onClicked: root.viewCopy(copyRow.modelData.name)
          }
        }

        Text {
          visible: copyRow.previewed
          textFormat: Text.PlainText
          text: root.preview && root.preview.groups.length > 0 ? root.t("Esta copia contiene:") : root.t("Esta copia no contiene archivos.")
          color: Qt.darker(root.fg, 1.5)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          width: parent.width
        }

        GroupList {
          visible: copyRow.previewed
          model: copyRow.previewed ? root.preview.groups : []
        }

        Row {
          visible: copyRow.previewed
          spacing: Style.space(6)

          Button {
            text: root.t("Cargar")
            bordered: true
            foreground: root.fg
            enabled: root.canChange
            onClicked: root.loadData()
          }

          Button {
            text: root.t("Cancelar")
            bordered: true
            foreground: root.fg
            onClicked: root.cancelView()
          }
        }
      }
    }

    Text {
      visible: root.readError !== ""
      textFormat: Text.PlainText
      text: root.readError
      color: Commons.Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.Wrap
      width: parent.width
    }
  }

  // "God of War · Partidas guardadas · 32 MB". Names come from outside the plugin.
  component GroupList: Column {
    property alias model: rows.model

    width: parent ? parent.width : implicitWidth
    spacing: Style.space(2)

    Repeater {
      id: rows

      Text {
        required property var modelData
        textFormat: Text.PlainText
        text: modelData.name + " · " + root.areaLabel(modelData.area) + " · " + root.formatBytes(modelData.bytes)
        color: Qt.darker(root.fg, 1.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.Wrap
        width: parent ? parent.width : implicitWidth
      }
    }
  }
}
