import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Dono unico do player: fala IPC com o mpv, guarda a fila, as playlists e as
// posicoes de retomada. O widget da barra e apenas uma fachada sobre este
// objeto (bar.shell.serviceFor("youtube-radio")), porque a barra existe uma vez
// por monitor e aqui precisa existir exatamente um dono.
Item {
  id: root
  visible: false
  width: 0
  height: 0

  // ------------------------------------------------------- injetado pelo shell
  property string omarchyPath: ""
  property var shell: null
  property var manifest: null
  property var pluginRegistry: null
  property var barWidgetRegistry: null

  // --------------------------------------------------------------- preferencias
  property var settings: ({})

  readonly property var defaultSettings: ({
    "socketPath": "",
    "maxResults": 10,
    "idleQuitMinutes": 30,
    "stallTimeoutSeconds": 120,
    "resumeMinSeconds": 30,
    "barTitleMaxChars": 42,
    "showTimeInBar": false,
    "ytdlFormat": "bestaudio/best",
    "defaultVolume": 80,
    "extraMpvArgs": ""
  })

  function setting(name, fallback) {
    var value = root.settings ? root.settings[name] : undefined
    if (value === undefined || value === null || value === "") {
      var fallbackValue = fallback === undefined ? root.defaultSettings[name] : fallback
      return fallbackValue === undefined ? "" : fallbackValue
    }
    return value
  }

  function applySettings(values) {
    root.settings = values && typeof values === "object" ? values : ({})
    root.markStatusDirty()
  }

  readonly property int resumeMinSeconds: Number(root.setting("resumeMinSeconds", 30))
  readonly property int stallTimeoutSeconds: Number(root.setting("stallTimeoutSeconds", 120))
  readonly property int idleQuitMinutes: Number(root.setting("idleQuitMinutes", 30))
  readonly property int maxResults: Math.max(1, Number(root.setting("maxResults", 10)))
  readonly property int volumeCeiling: 130

  // ------------------------------------------------------------------ caminhos
  readonly property string runtimeRoot: {
    var dir = Quickshell.env("XDG_RUNTIME_DIR")
    return (dir && dir !== "" ? String(dir) : "/tmp") + "/youtube-radio"
  }

  readonly property string dataRoot: {
    var dir = Quickshell.env("XDG_DATA_HOME")
    if (!dir || dir === "") {
      var home = Quickshell.env("HOME")
      dir = (home && home !== "" ? String(home) : "/tmp") + "/.local/share"
    }
    return String(dir) + "/youtube-radio"
  }

  readonly property string socketPath: {
    var custom = String(root.setting("socketPath", "")).trim()
    return custom !== "" ? custom : root.runtimeRoot + "/mpv.sock"
  }

  readonly property string queueM3uPath: root.runtimeRoot + "/queue.m3u"
  readonly property string queueJsonPath: root.runtimeRoot + "/queue.json"
  readonly property string playlistsPath: root.dataRoot + "/playlists.json"
  readonly property string statePath: root.dataRoot + "/state.json"
  readonly property string statusPath: root.dataRoot + "/status.json"

  // -------------------------------------------------------------------- estado
  property bool storageReady: false
  property bool depsOk: false
  property bool storageBroken: false
  property string storageError: ""
  property string lastError: ""
  property bool ensurePending: false
  property bool wantPlayer: false

  // espelho do mpv
  property bool playerRunning: false
  property bool ipcReady: false
  property bool idle: true
  property bool paused: false
  property bool muted: false
  property bool seekable: false
  property string title: ""
  property string mediaPath: ""
  property real position: 0
  property real duration: -1
  property int volume: 80
  property int mpvPlaylistPos: -1
  property int mpvPlaylistCount: 0
  property bool expandedQueue: false

  // fila e playlists
  property string mode: "sequential"
  property var queue: []
  property var playable: []
  property int currentIndex: -1
  property string currentPlaylistId: ""
  property var playlists: []
  property bool playlistsLoaded: false

  // busca
  property var searchResults: []
  property bool searchBusy: false
  property string searchTerm: ""
  property string searchError: ""

  // persistencia
  property bool stateLoaded: false
  property var resumePositions: ({})
  property bool statusDirty: true
  property bool queuePendingLoad: false
  property bool m3uSaved: false
  property string pendingSeekValue: ""

  // watchdog de transmissao ao vivo
  property real watchedPosition: 0
  property double watchedAt: 0
  property double idleSince: 0

  // popup: o IPC vive aqui (instancia unica); os widgets reagem ao tick e
  // abrem no monitor focado, evitando dois handlers para o mesmo target.
  property int popupTick: 0
  property string popupAction: ""
  property string popupMonitor: ""
  property string popupTab: "now"
  property bool popupOpen: false
  property string popupOpenMonitor: ""

  readonly property bool playing: root.playerRunning && !root.idle && !root.paused
  readonly property bool hasQueue: root.playable.length > 0
  readonly property string playlistName: {
    var playlist = root.playlistById(root.currentPlaylistId)
    return playlist ? playlist.name : ""
  }
  readonly property string barTitle: {
    if (root.title !== "") return root.title
    var value = root.currentItemValue()
    if (value !== "") return value
    return root.playlistName
  }

  // ------------------------------------------------------------------ eventos
  // Ultimos eventos do mpv (para diagnostico ao vivo via IPC).
  property var eventLog: []

  function logEvent(text) {
    var stamp = new Date().toISOString().slice(11, 23)
    var next = root.eventLog.slice(-29)
    next.push(stamp + " " + String(text))
    root.eventLog = next
    root.markStatusDirty()
  }

  function setError(message) {
    root.lastError = String(message === undefined || message === null ? "" : message)
    if (root.lastError !== "") root.logEvent("erro: " + root.lastError)
    root.markStatusDirty()
  }

  function clearError() {
    if (root.lastError === "") return
    root.lastError = ""
    root.markStatusDirty()
  }

  function isoNow() {
    return new Date().toISOString()
  }

  // ------------------------------------------------------------------ startup
  Component.onCompleted: {
    mkdirProc.running = true
    depsProc.running = true
  }

  Process {
    id: mkdirProc
    command: ["mkdir", "-p", root.dataRoot, root.runtimeRoot]
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.setError("nao foi possivel criar " + root.dataRoot)
        return
      }
      root.storageReady = true
      Qt.callLater(function() {
        playlistsFile.reload()
        stateFile.reload()
        root.checkLiveness()
        root.markStatusDirty()
      })
    }
  }

  Process {
    id: depsProc
    command: ["bash", "-lc", "command -v mpv >/dev/null 2>&1 && command -v yt-dlp >/dev/null 2>&1"]
    onExited: function(exitCode) {
      root.depsOk = exitCode === 0
      if (exitCode !== 0) root.setError("mpv e yt-dlp precisam estar no PATH")
      root.markStatusDirty()
    }
  }

  // ------------------------------------------------------------- persistencia
  FileView {
    id: playlistsFile
    path: root.playlistsPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadPlaylists(text())
    onLoadFailed: root.loadPlaylists("")
    onSaveFailed: root.setError("falha ao gravar playlists.json")
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadState(text())
    onLoadFailed: root.loadState("")
    onSaveFailed: root.setError("falha ao gravar state.json")
  }

  FileView {
    id: statusFile
    path: root.statusPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
  }

  FileView {
    id: queueFile
    path: root.queueM3uPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onSaved: root.onQueueSaved()
    onSaveFailed: root.setError("falha ao gravar a fila")
  }

  // Espelho legivel da fila (rotulos + URLs resolvidas) para diagnostico.
  FileView {
    id: queueJsonFile
    path: root.queueJsonPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
  }

  function loadPlaylists(raw) {
    if (root.storageBroken) return
    var parsed = Model.parsePlaylistFile(raw)
    if (!parsed.ok) {
      root.storageBroken = true
      root.storageError = "playlists.json invalido (" + parsed.error + "); o arquivo nao sera sobrescrito"
      root.setError(root.storageError)
      root.playlistsLoaded = true
      return
    }
    root.playlists = parsed.playlists
    root.playlistsLoaded = true
    root.markStatusDirty()
  }

  function savePlaylists() {
    if (root.storageBroken) {
      root.setError("playlists.json invalido; corrija ou remova o arquivo antes de editar")
      return
    }
    playlistsFile.setText(Model.serializePlaylistFile(root.playlists))
  }

  function loadState(raw) {
    var parsed = Model.parseStatusJson(raw)
    root.resumePositions = ({})
    if (parsed) {
      root.resumePositions = parsed.positions && typeof parsed.positions === "object" ? parsed.positions : ({})
      root.volume = Model.clampVolume(parsed.volume === undefined
        ? root.setting("defaultVolume", 80) : parsed.volume, root.volumeCeiling)
      if (typeof parsed.currentPlaylist === "string") root.currentPlaylistId = parsed.currentPlaylist
      if (typeof parsed.mode === "string") root.mode = Model.normalizeMode(parsed.mode)
    } else {
      root.volume = Model.clampVolume(root.setting("defaultVolume", 80), root.volumeCeiling)
    }
    root.stateLoaded = true
    root.markStatusDirty()
  }

  function scheduleStateSave() {
    if (!root.storageReady) return
    stateSaveTimer.restart()
  }

  function flushState() {
    if (!root.storageReady) return
    stateFile.setText(JSON.stringify({
      version: 1,
      currentPlaylist: root.currentPlaylistId,
      mode: root.mode,
      volume: root.volume,
      positions: root.resumePositions
    }, null, 2) + "\n")
  }

  Timer {
    id: stateSaveTimer
    interval: 400
    onTriggered: root.flushState()
  }

  Timer {
    id: statusTimer
    interval: 1000
    repeat: true
    running: root.storageReady
    onTriggered: {
      if (!root.statusDirty) return
      root.statusDirty = false
      root.publishStatus()
    }
  }

  function markStatusDirty() {
    root.statusDirty = true
  }

  function statusText() {
    return JSON.stringify({
      version: 1,
      updated: root.isoNow(),
      storageReady: root.storageReady,
      storageBroken: root.storageBroken,
      storageError: root.storageError,
      depsOk: root.depsOk,
      playerRunning: root.playerRunning,
      ipcReady: root.ipcReady,
      ipcAttempts: ipc.attempts,
      ipcLastError: ipc.lastError,
      idle: root.idle,
      paused: root.paused,
      muted: root.muted,
      playing: root.playing,
      seekable: root.seekable,
      title: root.title,
      path: root.mediaPath,
      position: root.position,
      duration: root.duration,
      volume: root.volume,
      playlist: root.currentPlaylistId,
      playlistName: root.playlistName,
      mode: root.mode,
      index: root.currentIndex,
      count: root.playable.length,
      mpvPlaylistPos: root.mpvPlaylistPos,
      mpvPlaylistCount: root.mpvPlaylistCount,
      expandedQueue: root.expandedQueue,
      socketPath: root.socketPath,
      queueM3uPath: root.queueM3uPath,
      dataRoot: root.dataRoot,
      playlists: root.playlistSummaries(),
      queue: root.queueLabels(),
      searchTerm: root.searchTerm,
      searchBusy: root.searchBusy,
      searchResults: root.searchResults,
      queuePendingLoad: root.queuePendingLoad,
      m3uSaved: root.m3uSaved,
      pendingSeekValue: root.pendingSeekValue,
      eventLog: root.eventLog,
      lastError: root.lastError
    }, null, 2) + "\n"
  }

  function publishStatus() {
    if (!root.storageReady) return
    statusFile.setText(root.statusText())
  }

  function playlistSummaries() {
    var out = []
    for (var i = 0; i < root.playlists.length; i++) {
      var playlist = root.playlists[i]
      out.push({
        id: playlist.id,
        name: playlist.name,
        mode: Model.normalizeMode(playlist.mode),
        count: playlist.items ? playlist.items.length : 0
      })
    }
    return out
  }

  function queueLabels() {
    var out = []
    for (var i = 0; i < root.queue.length; i++) {
      out.push({
        index: i,
        kind: root.queue[i].kind,
        label: root.queue[i].label,
        url: root.queue[i].url,
        playable: root.queue[i].url !== "",
        current: i === root.currentIndex
      })
    }
    return out
  }

  // --------------------------------------------------------------- cliente mpv
  MpvIpc {
    id: ipc
    socketPath: root.socketPath
    wantConnected: root.playerRunning

    onIpcConnected: {
      root.ipcReady = true
      root.clearError()
      root.logEvent("ipc conectado em " + root.socketPath)
      root.registerObservers()
      root.refreshPlayerState()
      root.maybeLoadQueue()
      root.markStatusDirty()
    }

    onIpcDisconnected: {
      root.ipcReady = false
      root.logEvent("ipc desconectado")
      root.markStatusDirty()
      if (root.playerRunning) playerLostTimer.restart()
    }

    onPropertyChanged: function(name, value) { root.applyProperty(name, value) }
    onEventReceived: function(name, data) { root.applyEvent(name, data) }
    onCommandFailed: function(command, message) {
      if (message !== "property unavailable" && message !== "success") root.setError("mpv: " + message)
    }
  }

  readonly property var observedProperties: [
    "media-title", "pause", "time-pos", "duration", "volume", "idle-active",
    "playlist-pos", "playlist-count", "playlist-playing-pos", "seekable",
    "eof-reached", "path", "mute"
  ]

  function registerObservers() {
    for (var i = 0; i < root.observedProperties.length; i++) {
      root.observeOne(root.observedProperties[i], i + 1)
    }
  }

  function observeOne(name, id) {
    ipc.observeProperty(name, id, function(error) {
      if (error !== "") root.logEvent("observe_property " + name + " falhou: " + error)
    })
  }

  function refreshPlayerState() {
    var names = ["media-title", "pause", "idle-active", "duration", "seekable",
      "path", "volume", "playlist-pos", "playlist-count", "mute"]
    for (var i = 0; i < names.length; i++) {
      root.refreshOneProperty(names[i])
    }
  }

  function refreshOneProperty(name) {
    ipc.getProperty(name, function(value) {
      if (value === null || value === undefined) return
      root.applyProperty(name, value)
    })
  }

  function applyProperty(name, value) {
    if (root.observedProperties.indexOf(name) !== -1 && name !== "time-pos" && name !== "volume") {
      root.logEvent("prop " + name + " = " + String(value))
    }
    if (name === "media-title") root.title = value === null || value === undefined ? "" : String(value)
    else if (name === "pause") root.paused = value === true
    else if (name === "time-pos") {
      root.position = typeof value === "number" ? value : 0
      if (Math.abs(root.position - root.watchedPosition) > 0.5) {
        root.watchedPosition = root.position
        root.watchedAt = Date.now()
      }
    }
    else if (name === "duration") root.duration = typeof value === "number" ? value : -1
    else if (name === "volume") root.volume = Model.clampVolume(value, root.volumeCeiling)
    else if (name === "idle-active") {
      root.idle = value === true
      root.idleSince = root.idle ? Date.now() : 0
    }
    else if (name === "playlist-pos") root.mpvPlaylistPos = typeof value === "number" ? value : -1
    else if (name === "playlist-count") root.mpvPlaylistCount = typeof value === "number" ? value : 0
    else if (name === "seekable") root.seekable = value === true
    else if (name === "path") root.mediaPath = value === null || value === undefined ? "" : String(value)
    else if (name === "mute") root.muted = value === true

    if (name === "playlist-pos" || name === "playlist-count") root.updateCurrentIndex()
    root.markStatusDirty()
  }

  function applyEvent(name, data) {
    var detail = ""
    if (name === "end-file" && data) detail = " reason=" + String(data.reason) + " erro=" + String(data.file_error)
    if (name === "start-file" && data) detail = " playlist_entry_id=" + String(data.playlist_entry_id)
    root.logEvent("evento " + name + detail)

    if (name === "file-loaded") {
      root.idle = false
      root.idleSince = 0
      root.watchedPosition = root.position
      root.watchedAt = Date.now()
      root.updateCurrentIndex()
      root.applyResumePosition()
      return
    }
    if (name === "end-file") {
      root.savePosition()
      var reason = data && data.reason ? String(data.reason) : ""
      if (reason === "error") {
        root.setError("falha ao tocar o item; pulando")
        if (root.hasQueue) ipc.playlistNext()
      }
      return
    }
    if (name === "idle") {
      root.idle = true
      root.idleSince = Date.now()
      root.mpvPlaylistPos = -1
      root.currentIndex = -1
      root.savePosition()
      root.markStatusDirty()
    }
  }

  function updateCurrentIndex() {
    var pos = root.mpvPlaylistPos
    root.expandedQueue = root.playable.length > 0 && root.mpvPlaylistCount > root.playable.length
    if (root.expandedQueue || pos === undefined || pos === null || pos < 0 || pos >= root.playable.length) {
      root.currentIndex = -1
    } else {
      root.currentIndex = root.playable[pos].queueIndex
    }
  }

  function currentItemValue() {
    if (root.currentIndex >= 0 && root.currentIndex < root.queue.length) return root.queue[root.currentIndex].value
    return ""
  }

  function currentItemUrl() {
    if (root.currentIndex >= 0 && root.currentIndex < root.queue.length) return root.queue[root.currentIndex].url
    return ""
  }

  // ------------------------------------------------------------- ciclo do mpv
  Process {
    id: livenessProc
    property string collected: ""
    command: ["pgrep", "-f", "input-ipc-server=" + root.socketPath]
    stdout: SplitParser {
      onRead: function(line) {
        var text = String(line).trim()
        if (text !== "") livenessProc.collected += text + "\n"
      }
    }
    onRunningChanged: { if (running) collected = "" }
    onExited: function(exitCode) { root.handleLiveness(exitCode === 0, livenessProc.collected) }
  }

  function checkLiveness() {
    if (!root.storageReady) return
    if (ipc.connected) {
      root.playerRunning = true
      root.ipcReady = true
      return
    }
    if (root.ensurePending || livenessProc.running) return
    root.ensurePending = true
    livenessProc.running = true
  }

  function handleLiveness(alive) {
    root.ensurePending = false
    if (alive) {
      root.playerRunning = true
      ipc.wantConnected = true
      if (!ipc.connected) ensureTimeout.restart()
      return
    }
    if (!root.wantPlayer) {
      root.playerRunning = false
      root.ipcReady = false
      root.markStatusDirty()
      return
    }
    root.launchPlayer()
  }

  function mpvArgs() {
    var args = [
      "setsid", "--fork", "mpv",
      "--idle=yes",
      "--no-video",
      "--audio-display=no",
      "--force-window=no",
      "--terminal=no",
      "--input-default-bindings=no",
      "--input-ipc-server=" + root.socketPath,
      "--ytdl=yes",
      "--ytdl-format=" + String(root.setting("ytdlFormat", "bestaudio/best")),
      "--ytdl-raw-options=socket-timeout=15,retries=2",
      "--network-timeout=30",
      "--cache=yes",
      "--demuxer-max-bytes=32MiB",
      "--volume=" + String(root.volume),
      "--keep-open=no",
      "--save-position-on-quit=no",
      "--loop-file=no",
      "--loop-playlist=no",
      "--title=youtube-radio"
    ]
    var extra = String(root.setting("extraMpvArgs", "")).trim()
    if (extra !== "") args = args.concat(extra.split(/\s+/))
    return args
  }

  function launchPlayer() {
    if (!root.depsOk) {
      root.setError("mpv nao esta disponivel")
      return
    }
    root.playerRunning = true
    root.ipcReady = false
    Util.execArgv(root.mpvArgs())
    ipc.wantConnected = true
    ensureTimeout.restart()
    root.markStatusDirty()
  }

  Timer {
    id: ensureTimeout
    interval: 8000
    onTriggered: {
      if (ipc.connected || !root.playerRunning) return
      root.setError("mpv nao respondeu no soquete " + root.socketPath)
      root.checkLiveness()
    }
  }

  Timer {
    id: playerLostTimer
    interval: 2500
    onTriggered: {
      if (ipc.connected) return
      root.checkLiveness()
    }
  }

  function ensurePlayer() {
    root.wantPlayer = true
    if (ipc.connected) {
      root.ipcReady = true
      return
    }
    root.checkLiveness()
  }

  function quitPlayer() {
    root.savePosition()
    if (ipc.connected) ipc.quitPlayer()
    root.wantPlayer = false
    root.playerRunning = false
    root.ipcReady = false
    root.idle = true
    root.paused = false
    root.title = ""
    root.mediaPath = ""
    root.position = 0
    root.duration = -1
    root.mpvPlaylistPos = -1
    root.mpvPlaylistCount = 0
    ipc.wantConnected = false
    root.flushState()
    root.markStatusDirty()
  }

  // ------------------------------------------------------------ controles
  function togglePlayPause() {
    if (!ipc.connected) {
      if (root.hasQueue) root.reloadQueue()
      else if (root.currentPlaylistId !== "") root.playPlaylist(root.currentPlaylistId)
      else {
        root.ensurePlayer()
        root.setError("nada na fila; cole uma URL, busque ou escolha uma playlist")
      }
      return
    }
    if (!root.hasQueue) {
      root.setError("nada na fila; cole uma URL, busque ou escolha uma playlist")
      return
    }
    if (root.idle || root.mpvPlaylistCount === 0) {
      root.reloadQueue()
      return
    }
    ipc.setProperty("pause", !root.paused)
  }

  function reloadQueue() {
    if (!root.hasQueue) return
    root.ensurePlayer()
    root.m3uSaved = true
    root.queuePendingLoad = true
    root.maybeLoadQueue()
  }

  function stop() {
    root.savePosition()
    if (ipc.connected) ipc.stopPlayback()
    root.idle = true
    root.idleSince = Date.now()
    root.paused = false
    root.currentIndex = -1
    root.markStatusDirty()
  }

  function next() {
    if (ipc.connected) ipc.playlistNext()
  }

  function previous() {
    if (ipc.connected) ipc.playlistPrevious()
  }

  function seekBy(seconds) {
    if (!ipc.connected) return
    if (!root.seekable) {
      root.setError("este fluxo nao permite avancar ou voltar")
      return
    }
    ipc.seekRelative(seconds)
  }

  function setVolumeValue(value) {
    var next = Model.clampVolume(value, root.volumeCeiling)
    root.volume = next
    if (ipc.connected) ipc.setProperty("volume", next)
    root.scheduleStateSave()
    root.markStatusDirty()
  }

  function adjustVolume(delta) {
    root.setVolumeValue(root.volume + Number(delta))
  }

  function toggleMute() {
    if (!ipc.connected) return
    ipc.setProperty("mute", !root.muted)
  }

  // -------------------------------------------------------------------- fila
  function startQueue(entries, playlistId, resumeValue) {
    var list = []
    for (var i = 0; i < (entries ? entries.length : 0); i++) {
      var item = Model.normalizeItem(entries[i])
      if (!item) continue
      list.push({
        kind: item.kind,
        value: item.value,
        url: item.kind === "url" ? item.value : "",
        label: item.value
      })
    }
    if (list.length === 0) {
      root.setError("nada para tocar")
      return
    }
    root.queue = list
    root.playable = []
    root.currentIndex = -1
    root.currentPlaylistId = playlistId === undefined || playlistId === null ? "" : String(playlistId)
    root.pendingSeekValue = resumeValue === undefined || resumeValue === null ? "" : String(resumeValue)
    root.m3uSaved = false
    root.queuePendingLoad = false
    root.ensurePlayer()
    root.resolveNextSearchItem()
  }

  function resolveNextSearchItem() {
    var index = -1
    for (var i = 0; i < root.queue.length; i++) {
      if (root.queue[i].kind === "search" && root.queue[i].url === "") {
        index = i
        break
      }
    }
    if (index === -1) {
      root.finishQueueBuild()
      return
    }
    resolveProc.targetIndex = index
    resolveProc.purpose = "queue"
    resolveProc.term = root.queue[index].value
    resolveProc.collected = ""
    resolveProc.command = root.ytdlpSearchArgs(1, root.queue[index].value)
    resolveProc.running = true
  }

  function finishQueueBuild() {
    var playable = []
    for (var i = 0; i < root.queue.length; i++) {
      if (root.queue[i].url !== "") playable.push({ url: root.queue[i].url, queueIndex: i })
    }
    root.playable = playable
    if (playable.length === 0) {
      root.setError("nenhum item reproduzivel nesta lista")
      return
    }
    // A fila so pode ir para o mpv depois que o .m3u existe em disco: a
    // gravacao e assincrona e onQueueSaved/maybeLoadQueue fazem o loadlist.
    root.m3uSaved = false
    root.queuePendingLoad = true
    queueFile.setText(Model.m3uFromQueue(root.queue))
    queueJsonFile.setText(Model.queueJsonFromQueue(root.queue))
    queueSaveGuard.restart()
  }

  Timer {
    id: queueSaveGuard
    interval: 700
    onTriggered: root.onQueueSaved()
  }

  function onQueueSaved() {
    queueSaveGuard.stop()
    root.m3uSaved = true
    root.maybeLoadQueue()
  }

  function maybeLoadQueue() {
    if (!root.queuePendingLoad || !root.m3uSaved || !ipc.connected) return
    root.queuePendingLoad = false
    ipc.loadList(root.queueM3uPath, "replace")
    root.applyModeToMpv()
    ipc.setProperty("pause", false)
    root.idle = false
    if (root.pendingSeekValue !== "") {
      root.seekToValue(root.pendingSeekValue)
      root.pendingSeekValue = ""
    }
    root.markStatusDirty()
  }

  function seekToValue(value) {
    for (var i = 0; i < root.playable.length; i++) {
      if (root.queue[root.playable[i].queueIndex].value === value) {
        ipc.setProperty("playlist-pos", i)
        return
      }
    }
  }

  // Toca a partir de um indice do queue (usado pelo popup e pelo IPC).
  function playQueueIndex(index) {
    var at = Number(index)
    if (!isFinite(at) || at < 0 || at >= root.queue.length) return
    if (root.queue[at].url === "") {
      root.setError("item sem resultado de busca: " + root.queue[at].label)
      return
    }
    if (!ipc.connected) {
      root.pendingSeekValue = root.queue[at].value
      root.queuePendingLoad = true
      root.ensurePlayer()
      return
    }
    if (root.mpvPlaylistCount === 0) {
      root.pendingSeekValue = root.queue[at].value
      root.reloadQueue()
      return
    }
    root.seekToValue(root.queue[at].value)
    ipc.setProperty("pause", false)
    root.idle = false
    root.markStatusDirty()
  }

  function applyModeToMpv() {
    var props = Model.modeToMpvProps(root.mode)
    ipc.setProperty("loop-file", props.loopFile)
    ipc.setProperty("loop-playlist", props.loopPlaylist)
  }

  // ------------------------------------------------------------- tocar coisas
  function playInput(input) {
    var raw = String(input === undefined || input === null ? "" : input).trim()
    if (raw === "") return
    if (Model.looksLikeUrl(raw)) {
      root.playUrl(Model.normalizeUrl(raw))
      return
    }
    root.playTerm(raw)
  }

  function playUrl(url) {
    root.startQueue([{ kind: "url", value: Model.normalizeUrl(url) }], "", "")
  }

  function playTerm(term) {
    var query = String(term === undefined || term === null ? "" : term).trim()
    if (query === "") return
    root.ensurePlayer()
    resolveProc.targetIndex = -1
    resolveProc.purpose = "single"
    resolveProc.term = query
    resolveProc.collected = ""
    resolveProc.command = root.ytdlpSearchArgs(1, query)
    resolveProc.running = true
  }

  function playPlaylist(id) {
    var playlist = root.playlistById(id)
    if (!playlist) {
      root.setError("playlist nao encontrada: " + String(id))
      return
    }
    if (!playlist.items || playlist.items.length === 0) {
      root.setError("playlist vazia: " + playlist.name)
      return
    }
    root.mode = Model.normalizeMode(playlist.mode)
    root.startQueue(playlist.items, playlist.id, "")
  }

  function playCurrent() {
    if (root.currentPlaylistId !== "") {
      root.playPlaylist(root.currentPlaylistId)
      return
    }
    if (root.hasQueue) {
      root.reloadQueue()
      return
    }
    root.setError("nenhuma playlist atual")
  }

  function cycleMode() {
    root.setMode(Model.nextMode(root.mode))
  }

  function setMode(value) {
    var next = Model.normalizeMode(value)
    var previous = root.mode
    root.mode = next
    var playlist = root.playlistById(root.currentPlaylistId)
    if (playlist) {
      var updated = Model.setMode(playlist, next)
      updated.updated = root.isoNow()
      root.replacePlaylist(updated)
    }
    if (ipc.connected) root.applyModeToMpv()
    root.scheduleStateSave()
    if (next === "shuffle" && previous !== "shuffle" && playlist) root.scheduleQueueRebuild()
    root.markStatusDirty()
  }

  function scheduleQueueRebuild() {
    if (root.currentPlaylistId === "") return
    queueRebuildTimer.restart()
  }

  Timer {
    id: queueRebuildTimer
    interval: 600
    onTriggered: root.rebuildCurrentQueue()
  }

  function rebuildCurrentQueue() {
    var playlist = root.playlistById(root.currentPlaylistId)
    if (!playlist || !playlist.items || playlist.items.length === 0) return
    var currentValue = root.currentItemValue()
    if (currentValue === "") currentValue = root.mediaPath
    root.mode = Model.normalizeMode(playlist.mode)
    root.startQueue(playlist.items, playlist.id, currentValue)
  }

  // ---------------------------------------------------------------- playlists
  function playlistById(id) {
    var key = String(id === undefined || id === null ? "" : id)
    for (var i = 0; i < root.playlists.length; i++) {
      if (root.playlists[i].id === key) return root.playlists[i]
    }
    return null
  }

  function replacePlaylist(playlist) {
    var next = []
    for (var i = 0; i < root.playlists.length; i++) {
      next.push(root.playlists[i].id === playlist.id ? playlist : root.playlists[i])
    }
    root.playlists = next
    root.savePlaylists()
    root.markStatusDirty()
  }

  function createPlaylist(name) {
    var title = String(name === undefined || name === null ? "" : name).trim()
    if (title === "") {
      root.setError("nome da playlist nao pode ser vazio")
      return ""
    }
    var ids = []
    for (var i = 0; i < root.playlists.length; i++) ids.push(root.playlists[i].id)
    var id = Model.uniquePlaylistId(title, ids)
    var entry = Model.emptyPlaylist(title, id)
    entry.updated = root.isoNow()
    root.playlists = root.playlists.concat([entry])
    root.savePlaylists()
    root.markStatusDirty()
    return id
  }

  function renamePlaylist(id, name) {
    var playlist = root.playlistById(id)
    if (!playlist) return false
    var renamed = Model.renamePlaylist(playlist, name)
    if (!renamed.ok) {
      root.setError(renamed.error)
      return false
    }
    renamed.playlist.updated = root.isoNow()
    root.replacePlaylist(renamed.playlist)
    return true
  }

  function deletePlaylist(id) {
    var next = []
    for (var i = 0; i < root.playlists.length; i++) {
      if (root.playlists[i].id !== String(id)) next.push(root.playlists[i])
    }
    root.playlists = next
    if (root.currentPlaylistId === String(id)) {
      root.currentPlaylistId = ""
      root.mode = "sequential"
    }
    root.savePlaylists()
    root.markStatusDirty()
  }

  function addItemToPlaylist(id, value) {
    var playlist = root.playlistById(id)
    if (!playlist) {
      root.setError("playlist nao encontrada")
      return false
    }
    var added = Model.addItem(playlist, value)
    if (!added.ok) {
      root.setError(added.error)
      return false
    }
    added.playlist.updated = root.isoNow()
    root.replacePlaylist(added.playlist)
    if (root.currentPlaylistId === added.playlist.id) root.scheduleQueueRebuild()
    return true
  }

  function addCurrentToPlaylist(id) {
    var value = root.currentItemValue()
    if (value === "") value = root.mediaPath
    if (value === "") {
      root.setError("nada tocando para salvar")
      return false
    }
    return root.addItemToPlaylist(id, value)
  }

  function createPlaylistWithCurrent(name) {
    var id = root.createPlaylist(name)
    if (id === "") return ""
    root.addCurrentToPlaylist(id)
    return id
  }

  function removePlaylistItem(id, index) {
    var playlist = root.playlistById(id)
    if (!playlist) return false
    var removed = Model.removeItemAt(playlist, index)
    if (!removed.ok) {
      root.setError(removed.error)
      return false
    }
    removed.playlist.updated = root.isoNow()
    root.replacePlaylist(removed.playlist)
    if (root.currentPlaylistId === removed.playlist.id) root.scheduleQueueRebuild()
    return true
  }

  function movePlaylistItem(id, index, delta) {
    var playlist = root.playlistById(id)
    if (!playlist) return false
    var moved = Model.moveItem(playlist, index, delta)
    if (!moved.ok) return false
    moved.playlist.updated = root.isoNow()
    root.replacePlaylist(moved.playlist)
    if (root.currentPlaylistId === moved.playlist.id) root.scheduleQueueRebuild()
    return true
  }

  // -------------------------------------------------------------------- busca
  function ytdlpSearchArgs(count, term) {
    return [
      "yt-dlp",
      "--flat-playlist",
      "--no-warnings",
      "--socket-timeout", "15",
      "--retries", "1",
      "--print", "%(id)s\t%(title)s\t%(duration_string)s",
      Model.searchExpression(term, count)
    ]
  }

  function search(term) {
    var query = String(term === undefined || term === null ? "" : term).trim()
    if (query === "") return
    if (!root.depsOk) {
      root.setError("yt-dlp nao esta disponivel")
      return
    }
    root.searchTerm = query
    root.searchResults = []
    root.searchError = ""
    root.searchBusy = true
    searchProc.collected = ""
    searchProc.command = root.ytdlpSearchArgs(root.maxResults, query)
    searchProc.running = true
    searchTimeout.restart()
    root.markStatusDirty()
  }

  function playSearchResult(index) {
    var at = Number(index)
    if (!isFinite(at) || at < 0 || at >= root.searchResults.length) return
    root.playUrl(root.searchResults[at].url)
  }

  Process {
    id: searchProc
    property string collected: ""
    command: []
    stdout: SplitParser {
      onRead: function(line) { searchProc.collected += String(line) + "\n" }
    }
    onExited: function(exitCode) {
      searchTimeout.stop()
      root.searchBusy = false
      var results = Model.parseSearchLines(searchProc.collected, root.maxResults)
      if (results.length === 0) {
        root.searchError = exitCode === 0
          ? "nenhum resultado para \"" + root.searchTerm + "\""
          : "busca falhou (yt-dlp saiu com " + exitCode + ")"
        root.setError(root.searchError)
      } else {
        root.searchResults = results
        root.clearError()
      }
      root.markStatusDirty()
    }
  }

  Timer {
    id: searchTimeout
    interval: 30000
    onTriggered: {
      if (!root.searchBusy) return
      root.searchBusy = false
      root.searchError = "busca demorou demais"
      root.setError(root.searchError)
      root.markStatusDirty()
    }
  }

  Process {
    id: resolveProc
    property int targetIndex: -1
    property string purpose: "queue"
    property string term: ""
    property string collected: ""
    command: []
    stdout: SplitParser {
      onRead: function(line) { resolveProc.collected += String(line) + "\n" }
    }
    onExited: function(exitCode) { root.handleResolveExit(exitCode) }
  }

  function handleResolveExit(exitCode) {
    var id = Model.parseResolveFirstId(resolveProc.collected)
    if (resolveProc.purpose === "single") {
      var term = resolveProc.term
      if (id === "") {
        root.setError(exitCode === 0
          ? "nenhum resultado para \"" + term + "\""
          : "falha ao resolver a busca por \"" + term + "\"")
        return
      }
      root.playUrl(Model.urlFromVideoId(id))
      return
    }

    var index = resolveProc.targetIndex
    if (index >= 0 && index < root.queue.length) {
      var next = root.queue.slice()
      next[index] = {
        kind: next[index].kind,
        value: next[index].value,
        url: id === "" ? "" : Model.urlFromVideoId(id),
        label: next[index].label
      }
      root.queue = next
      if (id === "") root.setError("item ignorado (sem resultado): " + next[index].label)
    }
    resolveNextTimer.restart()
  }

  Timer {
    id: resolveNextTimer
    interval: 0
    onTriggered: root.resolveNextSearchItem()
  }

  // ------------------------------------------------------- posicao de retomada
  function resumeKey() {
    if (root.mediaPath !== "") return root.mediaPath
    return root.currentItemUrl()
  }

  function applyResumePosition() {
    var key = root.resumeKey()
    if (key === "" || !root.resumePositions) return
    var saved = root.resumePositions[key]
    if (!saved || !isFinite(Number(saved.pos))) return
    ipc.getProperty("duration", function(rawDuration) {
      ipc.getProperty("seekable", function(rawSeekable) {
        var decision = Model.resumeDecision({
          seekable: rawSeekable === true,
          duration: Number(rawDuration),
          position: Number(saved.pos),
          minSeconds: root.resumeMinSeconds,
          tailSeconds: 15
        })
        if (decision.resume) ipc.setProperty("time-pos", decision.position)
      })
    })
  }

  function savePosition() {
    if (!root.stateLoaded) return
    var key = root.resumeKey()
    if (key === "") return
    if (!root.seekable || !isFinite(root.duration) || root.duration <= 0) return
    if (!isFinite(root.position) || root.position <= 0) return
    var next = ({})
    for (var existing in root.resumePositions) next[existing] = root.resumePositions[existing]
    next[key] = { pos: root.position, updated: root.isoNow() }
    root.resumePositions = Model.prunePositions(next, 200)
    root.scheduleStateSave()
  }

  Timer {
    id: positionSaveTimer
    interval: 15000
    repeat: true
    running: root.playing
    onTriggered: root.savePosition()
  }

  // Live travada: sem avanco de time-pos por stallTimeoutSeconds em fluxo
  // nao-buscavel (ao vivo), pula para o proximo item.
  Timer {
    id: stallTimer
    interval: 15000
    repeat: true
    running: root.playing
    onTriggered: {
      if (root.stallTimeoutSeconds <= 0) return
      if (root.seekable && root.duration > 0) return
      if (!root.playing || root.watchedAt <= 0) return
      if (Date.now() - root.watchedAt <= root.stallTimeoutSeconds * 1000) return
      root.watchedAt = Date.now()
      root.setError("transmissao travada; pulando para o proximo item")
      root.savePosition()
      if (root.hasQueue) ipc.playlistNext()
    }
  }

  Timer {
    id: idleQuitTimer
    interval: 60000
    repeat: true
    running: root.playerRunning
    onTriggered: {
      if (root.idleQuitMinutes <= 0) return
      if (!root.idle || root.idleSince <= 0) return
      if (Date.now() - root.idleSince < root.idleQuitMinutes * 60000) return
      root.quitPlayer()
    }
  }

  // -------------------------------------------------------------------- popup
  // O popup pertence a instancias do widget (uma por monitor); o pedido nasce
  // aqui para que exista um unico alvo IPC e o popup abra no monitor focado.
  function focusedMonitorName() {
    var monitor = Hyprland.focusedMonitor
    if (!monitor) return ""
    return monitor.name ? String(monitor.name) : ""
  }

  function requestPopup(action) {
    root.popupAction = String(action)
    root.popupMonitor = root.focusedMonitorName()
    root.popupTick = root.popupTick + 1
  }

  function togglePopup() {
    if (root.popupOpen) root.requestPopup("close")
    else root.requestPopup("open")
  }

  function reportPopup(isOpen, monitor) {
    root.popupOpen = isOpen === true
    root.popupOpenMonitor = isOpen === true
      ? String(monitor === undefined || monitor === null ? "" : monitor) : ""
    root.markStatusDirty()
  }

  IpcHandler {
    target: "youtube-radio"

    function open(): void { root.requestPopup("open") }
    function close(): void { root.requestPopup("close") }
    function show(): void { root.requestPopup("open") }
    function hide(): void { root.requestPopup("close") }
    function toggle(): void { root.togglePopup() }
    function isOpen(): string { return root.popupOpen ? "yes" : "no" }
    function focusNow(): void { root.requestPopup("open") }
    function playPause(): void { root.togglePlayPause() }
    function play(): void {
      if (ipc.connected && root.paused) ipc.setProperty("pause", false)
      else root.togglePlayPause()
    }
    function stop(): void { root.stop() }
    function next(): void { root.next() }
    function previous(): void { root.previous() }
    function seekForward(): void { root.seekBy(15) }
    function seekBackward(): void { root.seekBy(-15) }
    function volume(delta: string): void { root.adjustVolume(Number(delta)) }
    function playUrl(url: string): void { root.playUrl(url) }
    function playSearch(query: string): void { root.playTerm(query) }
    function search(query: string): string {
      root.search(query)
      return "ok"
    }
    function playResult(index: string): void { root.playSearchResult(Number(index)) }
    function playPlaylist(id: string): void { root.playPlaylist(id) }
    function playCurrent(): void { root.playCurrent() }
    function playQueueIndex(index: string): void { root.playQueueIndex(Number(index)) }
    function promptPlaylists(): void { root.popupTab = "playlists"; root.requestPopup("open") }
    function promptSearch(): void { root.popupTab = "search"; root.requestPopup("open") }
    function setMode(mode: string): void { root.setMode(mode) }
    function cycleMode(): void { root.cycleMode() }
    function quitPlayer(): void { root.quitPlayer() }
    function reloadQueue(): void { root.reloadQueue() }
    function status(): string { return root.statusText() }
    function selfTest(): string { return root.selfTest() }
    function ipcDebug(): string { return ipc.diagnostics() }
    function events(): string { return JSON.stringify(root.eventLog) }
    function reconnectPlayer(): string {
      root.wantPlayer = true
      root.checkLiveness()
      return "ok"
    }
    function createPlaylist(name: string): string { return root.createPlaylist(name) }
    function renamePlaylist(id: string, name: string): string {
      return root.renamePlaylist(id, name) ? "ok" : "erro"
    }
    function deletePlaylist(id: string): string {
      root.deletePlaylist(id)
      return "ok"
    }
    function addPlaylistItem(id: string, value: string): string {
      return root.addItemToPlaylist(id, value) ? "ok" : "erro"
    }
    function addCurrentToPlaylist(id: string): string {
      return root.addCurrentToPlaylist(id) ? "ok" : "erro"
    }
    function removePlaylistItem(id: string, index: string): string {
      return root.removePlaylistItem(id, Number(index)) ? "ok" : "erro"
    }
    function movePlaylistItem(id: string, index: string, delta: string): string {
      return root.movePlaylistItem(id, Number(index), Number(delta)) ? "ok" : "erro"
    }
    function playInput(value: string): void { root.playInput(value) }
    function playlistsJson(): string { return JSON.stringify(root.playlistSummaries()) }
    function queueJson(): string { return JSON.stringify(root.queueLabels()) }
    function searchJson(): string { return JSON.stringify(root.searchResults) }
    function playlistsFile(): string { return root.playlistsPath }
    function queueFile(): string { return root.queueM3uPath }
    function savePositionNow(): string {
      root.savePosition()
      root.flushState()
      return "ok"
    }
  }

  // ------------------------------------------------------------------ selfTest
  // Devolve "ok" quando tudo passa; caso contrario a primeira falha encontrada.
  function selfTest() {
    var modelResult = Model.selfTest()
    if (modelResult !== "") return modelResult
    if (!root.storageReady) return "FAIL: storage nao pronto"
    if (root.dataRoot === "" || root.runtimeRoot === "") return "FAIL: caminhos vazios"
    if (root.socketPath === "") return "FAIL: socketPath vazio"
    if (root.playlistsLoaded !== true) return "FAIL: playlists nao carregadas"
    if (root.stateLoaded !== true) return "FAIL: estado nao carregado"
    if (root.mode !== Model.normalizeMode(root.mode)) return "FAIL: modo invalido"
    return "ok"
  }
}
