import QtQuick
import Quickshell.Io

// Cliente IPC JSON do mpv sobre soquete Unix.
//
// Duas armadilhas do Quickshell 0.3.1 moldam este arquivo:
//
// 1. `Socket::setConnected(true)` so tenta conectar quando o QLocalSocket
//    interno e nulo, e uma tentativa falha nao zera esse ponteiro
//    (src/io/socket.cpp). Um connect que falha e definitivo para aquele
//    objeto, entao aqui o Socket e destruido e recriado com backoff.
// 2. A conexao Unix completa *antes* de o objeto estar registrado em qualquer
//    container (Loader/Repeater), entao o alvo do `write` e a referencia
//    explicita `activeSocket`, nunca `loader.item`. O objeto e criado sem
//    conectar, registrado, e so entao `connected = true` e ligado.
Item {
  id: root
  visible: false
  width: 0
  height: 0

  property string socketPath: ""
  property bool wantConnected: false
  property bool connected: false
  property string lastError: ""
  property int attempts: 0
  property int maxPendingReplies: 32
  property var activeSocket: null
  property var pendingReplies: ({})
  property int nextRequestId: 1

  readonly property bool wantConnection: wantConnected && socketPath !== ""

  signal ipcConnected()
  signal ipcDisconnected()
  signal propertyChanged(string name, var value)
  signal eventReceived(string name, var data)
  signal commandFailed(string command, string message)

  function diagnostics() {
    return JSON.stringify({
      socketPath: socketPath,
      wantConnected: wantConnected,
      connected: connected,
      attempts: attempts,
      lastError: lastError,
      hasSocket: activeSocket !== null,
      pendingReplies: Object.keys(pendingReplies).length
    })
  }

  function backoffInterval() {
    return Math.min(300 * Math.max(1, attempts), 3000)
  }

  function scheduleRecreate() {
    if (!root.wantConnection) return
    if (recreateTimer.running) return
    recreateTimer.interval = root.backoffInterval()
    recreateTimer.restart()
  }

  function createSocket() {
    root.destroySocket()
    if (!root.wantConnection) return
    var instance = socketComponent.createObject(root, { "path": root.socketPath })
    if (instance === null) {
      root.lastError = "nao foi possivel criar o soquete"
      root.scheduleRecreate()
      return
    }
    root.activeSocket = instance
    root.attempts = root.attempts + 1
    // A partir daqui o objeto esta registrado: uma conexao sincrona ja
    // encontra activeSocket preenchido e o write funciona.
    instance.connected = true
  }

  function destroySocket() {
    var instance = root.activeSocket
    root.activeSocket = null
    if (instance !== null && instance !== undefined) instance.destroy()
  }

  function setConnected(value) {
    var next = value === true
    if (next === root.connected) return
    root.connected = next
    if (next) {
      root.attempts = 0
      root.lastError = ""
      root.ipcConnected()
    } else {
      root.failPendingReplies()
      root.ipcDisconnected()
    }
  }

  function disconnect() {
    recreateTimer.stop()
    root.destroySocket()
    root.setConnected(false)
  }

  onWantConnectionChanged: {
    if (!root.wantConnection) {
      root.disconnect()
    } else if (root.activeSocket === null) {
      root.attempts = 0
      root.createSocket()
    }
  }

  onSocketPathChanged: {
    if (!root.wantConnection) return
    root.createSocket()
  }

  Component.onCompleted: {
    if (root.wantConnection) root.createSocket()
  }

  Component.onDestruction: root.destroySocket()

  Timer {
    id: recreateTimer
    interval: 300
    onTriggered: {
      if (!root.wantConnection || root.connected) return
      root.createSocket()
    }
  }

  Component {
    id: socketComponent

    Socket {
      id: inner

      parser: SplitParser {
        onRead: function(line) { root.handleLine(line) }
      }

      onConnectionStateChanged: {
        if (root.activeSocket !== inner) return
        if (inner.connected) {
          root.setConnected(true)
          return
        }
        root.setConnected(false)
        if (root.wantConnection) root.scheduleRecreate()
      }

      onError: function(error) {
        if (root.activeSocket !== inner) return
        root.lastError = "soquete: " + String(error)
        console.warn("[youtube-radio] falha no soquete do mpv: " + String(error)
          + " (tentativa " + root.attempts + ")")
        root.scheduleRecreate()
      }
    }
  }

  // ------------------------------------------------------------- protocolo

  function sendRaw(payload) {
    var socket = root.activeSocket
    if (socket === null || socket === undefined) return false
    if (socket.connected !== true) return false
    socket.write(payload + "\n")
    socket.flush()
    return true
  }

  function sendCommand(command) {
    if (!command || command.length === 0) return 0
    var id = root.nextRequestId++
    if (!root.sendRaw(JSON.stringify({ command: command, request_id: id }))) return 0
    return id
  }

  function sendCommandWithReply(command, callback) {
    var id = root.nextRequestId++
    root.pendingReplies[id] = callback
    root.prunePendingReplies()
    if (!root.sendRaw(JSON.stringify({ command: command, request_id: id }))) {
      delete root.pendingReplies[id]
      if (callback) callback(null)
      return 0
    }
    return id
  }

  function prunePendingReplies() {
    var ids = Object.keys(root.pendingReplies)
    if (ids.length <= root.maxPendingReplies) return
    var excess = ids.length - root.maxPendingReplies
    for (var i = 0; i < excess; i++) delete root.pendingReplies[ids[i]]
  }

  function failPendingReplies() {
    var ids = Object.keys(root.pendingReplies)
    for (var i = 0; i < ids.length; i++) {
      var callback = root.pendingReplies[ids[i]]
      delete root.pendingReplies[ids[i]]
      if (callback) callback(null)
    }
  }

  function setProperty(name, value) {
    return root.sendCommand(["set_property", String(name), value])
  }

  function getProperty(name, callback) {
    return root.sendCommandWithReply(["get_property", String(name)], function(reply) {
      if (!callback) return
      if (!reply) {
        callback(null, "sem-conexao")
        return
      }
      var failed = reply.error !== undefined && reply.error !== null && reply.error !== "success"
      if (failed) {
        callback(null, String(reply.error))
        return
      }
      callback(reply.data, "")
    })
  }

  function observeProperty(name, id, callback) {
    return root.sendCommandWithReply(["observe_property", Number(id), String(name)], function(reply) {
      if (!callback) return
      if (!reply) {
        callback("sem-conexao")
        return
      }
      var failed = reply.error !== undefined && reply.error !== null && reply.error !== "success"
      callback(failed ? String(reply.error) : "")
    })
  }

  function unobserveProperty(id) {
    return root.sendCommand(["unobserve_property", Number(id)])
  }

  function seekRelative(seconds) {
    return root.sendCommand(["seek", Number(seconds), "relative"])
  }

  function addVolume(delta) {
    return root.sendCommand(["add", "volume", Number(delta)])
  }

  function loadFile(url, mode) {
    return root.sendCommand(["loadfile", String(url), mode === undefined ? "replace" : String(mode)])
  }

  function loadList(path, mode) {
    return root.sendCommand(["loadlist", String(path), mode === undefined ? "replace" : String(mode)])
  }

  function playlistNext() { return root.sendCommand(["playlist-next", "force"]) }
  function playlistPrevious() { return root.sendCommand(["playlist-prev", "force"]) }
  function stopPlayback() { return root.sendCommand(["stop"]) }
  function quitPlayer() { return root.sendCommand(["quit"]) }

  function handleLine(line) {
    if (line === undefined || line === null) return
    var text = String(line).trim()
    if (text === "") return
    var message
    try {
      message = JSON.parse(text)
    } catch (error) {
      root.lastError = "IPC invalido: " + text.slice(0, 120)
      return
    }
    if (!message || typeof message !== "object") return

    if (message.event !== undefined) {
      if (message.event === "property-change") {
        root.propertyChanged(String(message.name === undefined ? "" : message.name), message.data)
        return
      }
      root.eventReceived(String(message.event), message)
      return
    }

    if (message.request_id !== undefined) {
      var callback = root.pendingReplies[message.request_id]
      if (callback) {
        delete root.pendingReplies[message.request_id]
        callback(message)
        return
      }
      var failed = message.error !== undefined && message.error !== null && message.error !== "success"
      if (failed) root.commandFailed("", String(message.error))
    }
  }
}
