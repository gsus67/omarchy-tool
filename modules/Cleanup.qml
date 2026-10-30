import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Module: cleanup, in Extras, with no switch: nothing stays on. One row per thing
// to clean, each with its own Limpiar and a confirmation that says what will go.
// Inside Caché de programas, a switch per program marks what the outer Limpiar
// removes. tool.run discards output, so the page reads with its own Process;
// changes go through the tool's queue, which also re-reads when they end.
Column {
  id: root

  property var tool: null
  property var status: ({})
  function t(source) { return tool ? tool.t(source) : source }

  readonly property color fg: tool ? tool.barForeground : Commons.Color.foreground
  property var listing: ({ categories: [] })
  property bool listed: false
  property string readError: ""
  // A read's answer only counts if nothing made it stale since it was asked.
  property int readGeneration: 0
  property var activeRead: null
  property bool pendingRead: false
  property var readOutput: null
  property var readExit: null
  property bool cacheView: false
  property var confirmation: null
  readonly property var cacheCategory: findCategory("cache")

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(8)

  onToolChanged: if (tool) requestRead()

  Connections {
    target: root.tool
    function onBusyChanged() { root.busyChanged() }
  }

  Process {
    id: readProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.collectRead(text)
    }
    onExited: function(exitCode) { root.exitRead(exitCode) }
    onRunningChanged: if (!running) Qt.callLater(root.pumpRead)
  }

  // A change may come from elsewhere, and what was read no longer describes the disk.
  function busyChanged() {
    if (tool.busy) {
      confirmation = null
      readGeneration += 1
    } else requestRead()
  }

  function requestRead() {
    pendingRead = true
    pumpRead()
  }

  function pumpRead() {
    if (readProc.running || activeRead !== null || !pendingRead) return
    pendingRead = false
    activeRead = { generation: readGeneration }
    readOutput = null
    readExit = null
    readProc.command = [tool.toolPath, "cleanup", "list"]
    readProc.running = true
  }

  // The output and the exit arrive in either order; an answer needs both.
  function collectRead(output) {
    readOutput = output
    completeRead()
  }

  function exitRead(exitCode) {
    readExit = exitCode
    completeRead()
  }

  function completeRead() {
    if (activeRead === null || readOutput === null || readExit === null) return
    var request = activeRead
    activeRead = null
    finishRead(request, readOutput, readExit)
    Qt.callLater(pumpRead)
  }

  function validListing(answer) {
    if (answer === null || typeof answer !== "object" || !Array.isArray(answer.categories)) return false
    return answer.categories.every(function(item) {
      return item !== null && typeof item === "object" && typeof item.id === "string"
        && typeof item.bytes === "number" && Array.isArray(item.names) && Array.isArray(item.rows)
    })
  }

  function finishRead(request, output, exitCode) {
    if (request.generation !== readGeneration) return
    var answer = null
    try { answer = JSON.parse(output) } catch (e) { answer = null }
    confirmation = null
    if (exitCode !== 0 || !validListing(answer)) {
      listed = false
      listing = { categories: [] }
      cacheView = false
      readError = answer && typeof answer.error === "string" ? t(answer.error) : t("No se pudo revisar qué limpiar")
      return
    }
    readError = ""
    listed = true
    listing = answer
    if (!answer.categories.some(function(item) { return item.id === "cache" })) cacheView = false
  }

  function findCategory(id) {
    return listing.categories.filter(function(item) { return item.id === id })[0] || null
  }

  function openCache() {
    if (findCategory("cache")) {
      confirmation = null
      cacheView = true
    }
  }

  function closeCache() {
    cacheView = false
  }

  function setMarked(row, on) {
    if (!tool || tool.busy) return
    var names = row.folders.map(function(folder) { return folder.name })
    tool.run(["cleanup", "cache-mark", JSON.stringify(names), on ? "on" : "off"])
  }

  function selectedFolders() {
    var names = []
    var cache = findCategory("cache")
    if (!cache) return names
    cache.rows.forEach(function(row) {
      row.folders.forEach(function(folder) { if (folder.marked) names.push(folder.name) })
    })
    return names
  }

  function selectedBytes() {
    var total = 0
    var cache = findCategory("cache")
    if (!cache) return total
    cache.rows.forEach(function(row) {
      row.folders.forEach(function(folder) { if (folder.marked) total += folder.bytes })
    })
    return total
  }

  // What is shown here is exactly what gets confirmed, whatever changes behind it.
  function beginClean(id) {
    if (!tool || tool.busy || !listed || activeRead !== null || pendingRead) return
    var item = findCategory(id)
    if (!item) return
    var names = item.names
    var bytes = item.bytes
    var selection = item.revision
    if (id === "cache") {
      names = selectedFolders()
      bytes = selectedBytes()
      if (names.length === 0) return
      selection = JSON.stringify(names)
    }
    confirmation = { id: id, title: item.title, summary: item.summary, warning: item.warning, bytes: bytes,
      names: names, selection: selection, requiresPassword: item.requiresPassword }
  }

  function cancelClean() {
    confirmation = null
  }

  function confirmClean() {
    if (!tool || tool.busy || confirmation === null) return
    var chosen = confirmation
    confirmation = null
    readGeneration += 1
    tool.run(["cleanup", "clean", chosen.id, chosen.selection])
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

  function markedSummary(cache) {
    return t("%1 de %2 marcadas: %3").replace("%1", selectedFolders().length).replace("%2", cache.count)
      .replace("%3", formatBytes(selectedBytes()))
  }

  Text {
    textFormat: Text.PlainText
    text: root.cacheView ? root.t("Marca lo que quieres borrar y pulsa Limpiar afuera.")
      : root.t("Limpia cada cosa por separado. Primero se muestra qué se va a borrar.")
    color: Qt.darker(root.fg, 1.5)
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.Wrap
    width: parent.width
  }

  Text {
    visible: !root.listed && root.readError === ""
    textFormat: Text.PlainText
    text: root.t("Calculando…")
    color: root.fg
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    width: parent.width
  }

  Text {
    visible: root.listed && root.listing.categories.length === 0
    textFormat: Text.PlainText
    text: root.t("No hay nada que limpiar.")
    color: root.fg
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    width: parent.width
  }

  // The list.
  Repeater {
    model: root.cacheView ? [] : root.listing.categories

    Column {
      id: row
      required property var modelData
      readonly property bool isCache: modelData.id === "cache"
      readonly property bool confirming: root.confirmation !== null && root.confirmation.id === modelData.id

      width: root.width
      spacing: Style.space(6)

      PanelSeparator { foreground: root.fg }

      Item {
        width: parent.width
        implicitHeight: Math.max(rowTitle.implicitHeight, rowButtons.implicitHeight)

        Text {
          id: rowTitle
          textFormat: Text.PlainText
          text: root.t(row.modelData.title) + " · " + root.formatBytes(row.modelData.bytes)
          color: root.fg
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          wrapMode: Text.Wrap
          anchors.left: parent.left
          anchors.right: rowButtons.left
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
        }

        Row {
          id: rowButtons
          spacing: Style.space(6)
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter

          Button {
            visible: row.isCache
            text: root.t("Elegir")
            bordered: true
            fontSize: Style.font.bodySmall
            foreground: root.fg
            onClicked: root.openCache()
          }

          Button {
            text: root.t("Limpiar")
            bordered: true
            fontSize: Style.font.bodySmall
            foreground: root.fg
            enabled: root.tool !== null && !root.tool.busy && root.activeRead === null && !root.pendingRead
              && (!row.isCache || root.selectedFolders().length > 0)
            onClicked: root.beginClean(row.modelData.id)
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        text: row.isCache ? root.t(row.modelData.summary) + " " + root.markedSummary(row.modelData) : root.t(row.modelData.summary)
        color: Qt.darker(root.fg, 1.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.Wrap
        width: parent.width
      }

      // The confirmation: what goes, how much, and what it costs.
      Text {
        visible: row.confirming
        textFormat: Text.PlainText
        text: row.confirming ? root.t("Se borrará: %1").replace("%1", root.formatBytes(root.confirmation.bytes)) : ""
        color: root.fg
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        wrapMode: Text.Wrap
        width: parent.width
      }

      Text {
        visible: row.confirming && root.confirmation.names.length > 0
        textFormat: Text.PlainText
        text: row.confirming ? root.confirmation.names.join(", ") : ""
        color: root.fg
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.Wrap
        width: parent.width
      }

      Text {
        visible: row.confirming && root.confirmation.warning !== ""
        textFormat: Text.PlainText
        text: row.confirming ? root.t(root.confirmation.warning) : ""
        color: Commons.Color.urgent
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.Wrap
        width: parent.width
      }

      Text {
        visible: row.confirming && root.confirmation.requiresPassword === true
        textFormat: Text.PlainText
        text: root.t("Pedirá tu contraseña.")
        color: Qt.darker(root.fg, 1.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        width: parent.width
      }

      Row {
        visible: row.confirming
        spacing: Style.space(6)

        Button {
          text: root.t("Confirmar")
          bordered: true
          foreground: root.fg
          onClicked: root.confirmClean()
        }

        Button {
          text: root.t("Cancelar")
          bordered: true
          foreground: root.fg
          onClicked: root.cancelClean()
        }
      }
    }
  }

  // Inside the cache: one switch per program.
  Button {
    visible: root.cacheView
    text: root.t("Volver a la lista")
    bordered: true
    fontSize: Style.font.bodySmall
    foreground: root.fg
    onClicked: root.closeCache()
  }

  Repeater {
    model: root.cacheView && root.cacheCategory ? root.cacheCategory.rows : []

    Column {
      id: cacheRow
      required property var modelData
      readonly property int markedCount: modelData.folders.filter(function(folder) { return folder.marked }).length
      readonly property bool allMarked: markedCount === modelData.folders.length

      width: root.width
      spacing: Style.space(4)

      PanelSeparator { foreground: root.fg }

      Item {
        width: parent.width
        implicitHeight: Math.max(cacheTexts.implicitHeight, cacheSwitch.implicitHeight)

        Column {
          id: cacheTexts
          spacing: Style.space(2)
          anchors.left: parent.left
          anchors.right: cacheSwitch.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter

          Text {
            textFormat: Text.PlainText
            text: root.t(cacheRow.modelData.title) + " · " + root.formatBytes(cacheRow.modelData.bytes)
            color: root.fg
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            wrapMode: Text.Wrap
            width: parent.width
          }

          Text {
            textFormat: Text.PlainText
            text: root.t(cacheRow.modelData.summary)
              + (cacheRow.markedCount > 0 && !cacheRow.allMarked
                ? " " + root.t("%1 de %2 marcadas.").replace("%1", cacheRow.markedCount).replace("%2", cacheRow.modelData.folders.length) : "")
            color: Qt.darker(root.fg, 1.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
            width: parent.width
          }
        }

        ToggleSwitch {
          id: cacheSwitch
          checked: cacheRow.allMarked
          busy: root.tool !== null && root.tool.busy
          cursorRing: false
          foreground: root.fg
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          onToggled: root.setMarked(cacheRow.modelData, !cacheRow.allMarked)
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
