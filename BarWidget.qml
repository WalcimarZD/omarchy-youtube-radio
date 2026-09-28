import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "ui"

// Chip da barra + popup de controles. Toda a logica de player vive no Service
// (uma instancia por sessao); aqui so ha apresentacao, teclado e IPC.
Panel {
  id: root

  moduleName: "youtube-radio"
  ipcTarget: "youtube-radio"
  manageIpc: false

  readonly property string serviceId: "youtube-radio"
  property var service: null

  property string tab: "now"
  property int queueCursor: 0
  property int resultCursor: 0
  property int playlistCursor: 0
  property bool returnHandled: false

  readonly property var svc: root.service
  readonly property color fg: Color.foreground
  readonly property color accentColor: Color.accent
  readonly property color urgentColor: Color.urgent
  readonly property string titleText: root.svc ? String(root.svc.barTitle) : ""
  readonly property bool playingNow: root.svc ? root.svc.playing === true : false
  readonly property bool pausedNow: root.svc ? (root.svc.playerRunning && root.svc.paused) : false
  readonly property bool liveNow: root.svc ? (!root.svc.seekable && root.playingNow) : false
  readonly property string stateGlyph: root.playingNow ? "\uf04b" : (root.pausedNow ? "\uf04c" : "\uf04d")

  implicitWidth: chip.implicitWidth
  implicitHeight: chip.implicitHeight

  // --------------------------------------------------------- service binding
  function acquireService() {
    if (root.service) return
    if (!root.bar || !root.bar.shell) return
    var found = root.bar.shell.serviceFor(root.serviceId)
    if (!found) return
    root.service = found
    root.pushSettings()
  }

  function pushSettings() {
    if (root.service && typeof root.service.applySettings === "function") {
      root.service.applySettings(root.settings)
    }
  }

  // `omarchy bar set` grava strings por padrao (a menos de --json), enquanto o
  // painel de settings grava booleanos de verdade: aceita os dois formatos.
  function flag(name, fallback) {
    var value = root.setting(name, fallback)
    if (value === true || value === 1) return true
    if (value === false || value === 0) return false
    if (typeof value === "string") {
      var text = value.toLowerCase()
      return text === "true" || text === "1" || text === "yes" || text === "on"
    }
    return fallback === true
  }

  Timer {
    id: serviceRetry
    interval: 500
    repeat: true
    running: root.service === null
    onTriggered: root.acquireService()
  }

  onBarChanged: root.acquireService()
  onSettingsChanged: root.pushSettings()
  Component.onCompleted: root.acquireService()

  function screenName() {
    var win = root.QsWindow && root.QsWindow.window ? root.QsWindow.window.screen : null
    return win && win.name ? String(win.name) : ""
  }

  readonly property bool primaryInstance: {
    var screens = Quickshell.screens
    if (!screens || screens.length === 0) return true
    var mine = root.QsWindow && root.QsWindow.window ? root.QsWindow.window.screen : null
    if (!mine) return true
    return mine === screens[0]
  }

  // O pedido de abrir/fechar vem do Service (alvo IPC unico). Cada instancia
  // decide se e a dona: o popup abre no monitor focado.
  Connections {
    target: root.service
    function onPopupTickChanged() {
      if (!root.svc) return
      var action = String(root.svc.popupAction)
      if (action === "close") {
        if (root.opened) root.close()
        return
      }
      var mine = root.screenName()
      var target = String(root.svc.popupMonitor)
      if (target === "") {
        if (!root.primaryInstance) return
      } else if (mine !== "" && mine !== target) {
        return
      }
      root.tab = String(root.svc.popupTab)
      root.open()
    }
  }

  onOpenedChanged: {
    if (root.svc && typeof root.svc.reportPopup === "function") root.svc.reportPopup(root.opened, root.screenName())
    if (!root.opened) return
    root.acquireService()
    if (!root.svc) return
    root.queueCursor = root.svc.currentIndex >= 0 ? root.svc.currentIndex : 0
    var index = root.indexOfCurrentPlaylist()
    root.playlistCursor = index >= 0 ? index : 0
  }

  function indexOfCurrentPlaylist() {
    if (!root.svc) return -1
    for (var i = 0; i < root.svc.playlists.length; i++) {
      if (String(root.svc.playlists[i].id) === String(root.svc.currentPlaylistId)) return i
    }
    return -1
  }

  // ------------------------------------------------------------- chip da barra
  readonly property string chipText: {
    var text = "\uf167 "
    var title = Model.visibleTitle(root.titleText, Number(root.setting("barTitleMaxChars", 42)))
    if (title === "") title = "YouTube Radio"
    text += title
    if (root.playingNow || root.pausedNow) text += " " + root.stateGlyph
    if (root.flag("showTimeInBar", false) && root.svc && root.svc.seekable && root.svc.duration > 0) {
      text += " " + Model.formatTime(root.svc.position)
    }
    return text
  }

  readonly property string tooltipText: {
    if (!root.svc) return "YouTube Radio (servico ainda carregando)"
    var lines = []
    lines.push(root.titleText !== "" ? root.titleText : "YouTube Radio")
    var state = root.playingNow ? "tocando" : (root.pausedNow ? "pausado" : "parado")
    if (root.liveNow) state += " (ao vivo)"
    if (root.svc.seekable && root.svc.duration > 0) {
      state += " · " + Model.formatTime(root.svc.position) + " / " + Model.formatTime(root.svc.duration)
    }
    lines.push(state + " · volume " + root.svc.volume + "%")
    if (root.svc.playlistName !== "") {
      lines.push(root.svc.playlistName + " · item " + (root.svc.currentIndex + 1) + "/" + root.svc.playable.length
        + " · " + Model.modeLabel(root.svc.mode))
    }
    if (root.svc.lastError !== "") lines.push("erro: " + root.svc.lastError)
    lines.push("esquerdo: play/pause · direito: controles · scroll: volume")
    return lines.join("\n")
  }

  WidgetButton {
    id: chip
    anchors.fill: parent
    bar: root.bar
    text: root.chipText
    active: root.playingNow
    fontSize: Style.font.body
    tooltipText: root.tooltipText

    onPressed: function(button) {
      if (button === Qt.RightButton) {
        root.toggle()
        return
      }
      if (button === Qt.MiddleButton) {
        if (root.svc) root.svc.next()
        return
      }
      if (root.svc) root.svc.togglePlayPause()
      else root.toggle()
    }

    onWheelMoved: function(delta) {
      if (!root.svc) return
      root.svc.adjustVolume(delta > 0 ? 5 : -5)
    }
  }

  // ------------------------------------------------------------------- popup
  KeyboardPanel {
    id: panel
    anchorItem: chip
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: searchTab.inputActive || playlistsTab.inputActive

      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onReturnRequested: { root.returnHandled = true; root.activateCursor() }
      onActivateRequested: {
        if (root.returnHandled) {
          root.returnHandled = false
          return
        }
        if (root.svc) root.svc.togglePlayPause()
      }
      onCloseRequested: root.close()
      onDeleteRequested: root.deleteSelected()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) { root.handleTextKey(text) }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: content
          width: scroll.width
          spacing: Style.space(6)

          // ---------------------------------------------------------- header
          Row {
            width: parent.width
            spacing: Style.space(8)

            Text {
              id: heroGlyph
              text: root.stateGlyph
              color: root.playingNow ? root.accentColor : Qt.darker(root.fg, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.iconLarge
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              width: parent.width - heroGlyph.width - Style.space(8)
              spacing: Style.space(1)

              Text {
                width: parent.width
                text: root.titleText !== "" ? root.titleText : "Nada tocando"
                textFormat: Text.PlainText
                elide: Text.ElideRight
                maximumLineCount: 2
                wrapMode: Text.Wrap
                color: root.fg
                font.family: Style.font.family
                font.pixelSize: Style.font.subtitle
              }

              Text {
                width: parent.width
                text: root.statusLine()
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: Qt.darker(root.fg, 1.5)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }

          PanelSeparator { foreground: root.fg }

          // ---------------------------------------------------------- volume
          Row {
            width: parent.width
            spacing: Style.space(6)

            RowButton {
              id: muteButton
              text: root.svc && root.svc.muted ? "\uf026" : "\uf028"
              tooltipText: "Mudo"
              bar: root.bar
              foreground: root.fg
              accent: root.accentColor
              anchors.verticalCenter: parent.verticalCenter
              onClicked: { if (root.svc) root.svc.toggleMute() }
            }

            PanelSlider {
              id: volumeSlider
              width: parent.width - muteButton.width - volumeLabel.width - Style.space(12)
              bar: root.bar
              minimum: 0
              maximum: 130
              step: 5
              value: root.svc ? root.svc.volume : 80
              anchors.verticalCenter: parent.verticalCenter
              onMoved: function(value) { if (root.svc) root.svc.setVolumeValue(value) }
            }

            Text {
              id: volumeLabel
              width: Style.space(38)
              text: (root.svc ? root.svc.volume : 0) + "%"
              color: Qt.darker(root.fg, 1.3)
              horizontalAlignment: Text.AlignRight
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          // ------------------------------------------------------- transporte
          Row {
            width: parent.width
            spacing: Style.space(4)

            RowButton {
              text: "\uf048"
              tooltipText: "Faixa anterior"
              bar: root.bar
              foreground: root.fg
              accent: root.accentColor
              onClicked: { if (root.svc) root.svc.previous() }
            }
            RowButton {
              text: "\uf0e2"
              tooltipText: "Voltar 15s"
              bar: root.bar
              foreground: root.fg
              accent: root.accentColor
              onClicked: { if (root.svc) root.svc.seekBy(-15) }
            }
            RowButton {
              text: root.playingNow ? "\uf04c" : "\uf04b"
              tooltipText: "Play/pause"
              bar: root.bar
              foreground: root.fg
              accent: root.accentColor
              onClicked: { if (root.svc) root.svc.togglePlayPause() }
            }
            RowButton {
              text: "\uf01e"
              tooltipText: "Avancar 15s"
              bar: root.bar
              foreground: root.fg
              accent: root.accentColor
              onClicked: { if (root.svc) root.svc.seekBy(15) }
            }
            RowButton {
              text: "\uf051"
              tooltipText: "Proxima faixa"
              bar: root.bar
              foreground: root.fg
              accent: root.accentColor
              onClicked: { if (root.svc) root.svc.next() }
            }
            RowButton {
              text: "\uf04d"
              tooltipText: "Parar (mantem o mpv pronto)"
              bar: root.bar
              foreground: root.fg
              accent: root.urgentColor
              onClicked: { if (root.svc) root.svc.stop() }
            }
            RowButton {
              text: "\uf011"
              tooltipText: "Sair do mpv (libera memoria)"
              bar: root.bar
              foreground: root.fg
              accent: root.urgentColor
              onClicked: { if (root.svc) root.svc.quitPlayer() }
            }
            RowButton {
              text: root.svc ? Model.modeLabel(root.svc.mode) : "Sequencial"
              tooltipText: "Cicla sequencial / repetir faixa / repetir playlist / aleatorio"
              bar: root.bar
              foreground: root.fg
              accent: root.accentColor
              onClicked: { if (root.svc) root.svc.cycleMode() }
            }
          }

          // ----------------------------------------------------------- abas
          Row {
            width: parent.width
            spacing: Style.space(4)

            RowButton {
              text: "Tocando"
              bar: root.bar
              foreground: root.tab === "now" ? root.accentColor : root.fg
              accent: root.accentColor
              onClicked: { root.tab = "now" }
            }
            RowButton {
              text: "Buscar"
              bar: root.bar
              foreground: root.tab === "search" ? root.accentColor : root.fg
              accent: root.accentColor
              onClicked: root.focusSearch()
            }
            RowButton {
              text: "Playlists"
              bar: root.bar
              foreground: root.tab === "playlists" ? root.accentColor : root.fg
              accent: root.accentColor
              onClicked: { root.tab = "playlists" }
            }
          }

          PanelSeparator { foreground: root.fg }

          // --------------------------------------------------------- conteudo
          QueueList {
            id: queueList
            visible: root.tab === "now"
            height: visible ? implicitHeight : 0
            svc: root.svc
            bar: root.bar
            foreground: root.fg
            accent: root.accentColor
            urgent: root.urgentColor
            cursor: root.queueCursor
            onActivated: function(index) { root.playQueueIndex(index) }
            onRemoved: function(index) {
              if (root.svc) root.svc.removePlaylistItem(root.svc.currentPlaylistId, index)
            }
            onMoved: function(index, delta) {
              if (root.svc) root.svc.movePlaylistItem(root.svc.currentPlaylistId, index, delta)
            }
            onSaveRequested: { root.tab = "playlists" }
            onReloadRequested: { if (root.svc) root.svc.reloadQueue() }
          }

          SearchTab {
            id: searchTab
            visible: root.tab === "search"
            height: visible ? implicitHeight : 0
            svc: root.svc
            bar: root.bar
            foreground: root.fg
            accent: root.accentColor
            urgent: root.urgentColor
            cursor: root.resultCursor
            onSubmitted: function(text) { root.submitInput(text) }
            onPicked: function(index) { root.resultCursor = index; root.playResult(index) }
          }

          PlaylistsTab {
            id: playlistsTab
            visible: root.tab === "playlists"
            height: visible ? implicitHeight : 0
            svc: root.svc
            bar: root.bar
            foreground: root.fg
            accent: root.accentColor
            urgent: root.urgentColor
            cursor: root.playlistCursor
            onPlayRequested: function(id) { if (root.svc) root.svc.playPlaylist(id) }
            onCreateRequested: function(name) { if (root.svc) root.svc.createPlaylist(name) }
            onRenameRequested: function(id, name) { if (root.svc) root.svc.renamePlaylist(id, name) }
            onDeleteRequested: function(id) { if (root.svc) root.svc.deletePlaylist(id) }
            onItemRemoved: function(id, index) { if (root.svc) root.svc.removePlaylistItem(id, index) }
            onItemMoved: function(id, index, delta) { if (root.svc) root.svc.movePlaylistItem(id, index, delta) }
            onAddCurrentRequested: function(id) { if (root.svc) root.svc.addCurrentToPlaylist(id) }
          }

          // --------------------------------------------------- erro e rodape
          Text {
            width: parent.width
            visible: root.svc !== null && root.svc.lastError !== ""
            text: root.svc ? root.svc.lastError : ""
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.urgentColor
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Text {
            width: parent.width
            text: "Enter ativa · espaco play/pause · setas navegam · ← → ±15s · x remove · m modo\n"
              + "n/b/p abas · v busca · 1-9 resultado · r recarrega fila · q sai do mpv · esc fecha"
            textFormat: Text.PlainText
            color: Qt.darker(root.fg, 1.8)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  function statusLine() {
    if (!root.svc) return "servico ainda carregando"
    var parts = []
    var state = root.playingNow ? "tocando" : (root.pausedNow ? "pausado" : "parado")
    if (root.liveNow) state = "ao vivo"
    parts.push(state)
    if (root.svc.seekable && root.svc.duration > 0) {
      parts.push(Model.formatTime(root.svc.position) + " / " + Model.formatTime(root.svc.duration))
    }
    if (root.svc.playlistName !== "") {
      parts.push(root.svc.playlistName + " " + (root.svc.currentIndex + 1) + "/" + root.svc.playable.length)
    }
    parts.push(Model.modeLabel(root.svc.mode))
    if (root.svc.expandedQueue) parts.push("playlist do YouTube expandida")
    if (!root.svc.playerRunning) parts.push("mpv parado")
    return parts.join("  ·  ")
  }

  function focusSearch() {
    root.tab = "search"
    Qt.callLater(function() { searchTab.fieldItem.forceActiveFocus() })
  }

  function submitInput(text) {
    if (!root.svc) return
    if (Model.looksLikeUrl(text)) root.svc.playUrl(Model.normalizeUrl(text))
    else root.svc.search(text)
  }

  function playQueueIndex(index) {
    if (!root.svc) return
    root.queueCursor = index
    if (typeof root.svc.playQueueIndex === "function") root.svc.playQueueIndex(index)
  }

  function playResult(index) {
    if (!root.svc) return
    root.svc.playSearchResult(index)
  }

  function moveCursor(dx, dy) {
    if (!root.svc) return
    if (root.tab === "now") {
      if (dx !== 0) {
        root.svc.seekBy(dx * 15)
        return
      }
      if (dy === 0) return
      root.queueCursor = Math.max(0, Math.min(root.svc.queue.length - 1, root.queueCursor + dy))
      return
    }
    if (root.tab === "search") {
      if (dy === 0) return
      root.resultCursor = Math.max(0, Math.min(root.svc.searchResults.length - 1, root.resultCursor + dy))
      return
    }
    if (root.tab === "playlists") {
      if (dy === 0) return
      root.playlistCursor = Math.max(0, Math.min(root.svc.playlists.length - 1, root.playlistCursor + dy))
    }
  }

  function activateCursor() {
    if (!root.svc) return
    if (root.tab === "now") {
      root.playQueueIndex(root.queueCursor)
      return
    }
    if (root.tab === "search") {
      if (root.svc.searchResults.length === 0) {
        root.focusSearch()
        return
      }
      root.playResult(root.resultCursor)
      return
    }
    if (root.tab === "playlists") {
      var id = playlistsTab.selectedId
      if (id !== "") root.svc.playPlaylist(id)
    }
  }

  function deleteSelected() {
    if (!root.svc) return
    if (root.tab === "now") {
      if (root.svc.currentPlaylistId !== "") root.svc.removePlaylistItem(root.svc.currentPlaylistId, root.queueCursor)
      return
    }
    if (root.tab === "playlists") playlistsTab.requestDeleteSelected()
  }

  function handleTextKey(text) {
    if (!root.svc) return
    if (text === "m") {
      root.svc.cycleMode()
      return
    }
    if (text === "n") {
      root.tab = "now"
      return
    }
    if (text === "b") {
      root.tab = "search"
      return
    }
    if (text === "p") {
      root.tab = "playlists"
      return
    }
    if (text === "v" || text === "s") {
      root.focusSearch()
      return
    }
    if (text === "r") {
      root.svc.reloadQueue()
      return
    }
    if (text === "q") {
      root.svc.quitPlayer()
      return
    }
    if (text === "R" && root.tab === "playlists") {
      playlistsTab.startRenameSelected()
      return
    }
    if (text.length === 1 && text >= "1" && text <= "9") {
      var index = Number(text) - 1
      if (root.tab === "search" && index < root.svc.searchResults.length) root.playResult(index)
    }
  }

  // ---------------------------------------------------------------- IPC
  // O alvo IPC "youtube-radio" pertence ao Service (instancia unica). Aqui ha
  // uma instancia por monitor, entao registrar o mesmo alvo duas vezes faria o
  // shell descartar um dos handlers.
}
