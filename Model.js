// Logica pura do youtube-radio: playlists, fila, modos, retomada e parsing.
// Sem I/O e sem dependencia do QML context: tudo aqui e testavel por selfTest().
.pragma library

var MODES = ["sequential", "repeat-one", "repeat-all", "shuffle"]

var MODE_LABELS = {
  "sequential": "Sequencial",
  "repeat-one": "Repetir faixa",
  "repeat-all": "Repetir playlist",
  "shuffle": "Aleatorio"
}

var WATCH_URL_PREFIX = "https://www.youtube.com/watch?v="
var SEARCH_PREFIX = "ytsearch"

function modeLabel(mode) {
  var key = normalizeMode(mode)
  return MODE_LABELS[key] || MODE_LABELS["sequential"]
}

function normalizeMode(mode, fallback) {
  var value = mode === undefined || mode === null ? "" : String(mode)
  for (var i = 0; i < MODES.length; i++) {
    if (MODES[i] === value) return value
  }
  return fallback === undefined || fallback === null ? "sequential" : String(fallback)
}

function nextMode(mode) {
  var index = MODES.indexOf(normalizeMode(mode))
  if (index < 0) index = 0
  return MODES[(index + 1) % MODES.length]
}

function modeToMpvProps(mode) {
  var key = normalizeMode(mode)
  if (key === "repeat-one") return { loopFile: "inf", loopPlaylist: "no" }
  if (key === "repeat-all") return { loopFile: "no", loopPlaylist: "inf" }
  if (key === "shuffle") return { loopFile: "no", loopPlaylist: "inf" }
  return { loopFile: "no", loopPlaylist: "no" }
}

// ------------------------------------------------------------------ playlists

function slugify(name) {
  var text = String(name === undefined || name === null ? "" : name).toLowerCase()
  text = text.replace(/[^a-z0-9]+/g, "-").replace(/^-+/, "").replace(/-+$/, "")
  if (text.length > 60) text = text.slice(0, 60).replace(/-+$/, "")
  return text
}

function uniquePlaylistId(name, existingIds) {
  var base = slugify(name)
  if (base === "") base = "playlist"
  var ids = existingIds || []
  if (ids.indexOf(base) === -1) return base
  var n = 2
  while (ids.indexOf(base + "-" + n) !== -1) n++
  return base + "-" + n
}

function emptyPlaylist(name, id) {
  var title = String(name === undefined || name === null ? "" : name).trim()
  return {
    version: 1,
    id: String(id === undefined || id === null ? "" : id),
    name: title === "" ? "Playlist" : title,
    mode: "sequential",
    updated: "",
    items: []
  }
}

function looksLikeUrl(input) {
  var text = String(input === undefined || input === null ? "" : input).trim()
  if (text === "") return false
  if (/^https?:\/\//i.test(text)) return true
  if (/^(www\.)?(youtube\.com|youtu\.be)\//i.test(text)) return true
  if (/^(www\.)?youtube\.com$/i.test(text)) return false
  if (/^[A-Za-z0-9_-]{11}$/.test(text)) return true
  return false
}

function normalizeUrl(input) {
  var text = String(input === undefined || input === null ? "" : input).trim()
  if (/^[A-Za-z0-9_-]{11}$/.test(text)) return WATCH_URL_PREFIX + text
  // Encurtadores simples viram a forma canonica, para a chave de retomada
  // (por URL) ser estavel. URLs com parametros extras ficam intactas.
  var short = text.match(/^https?:\/\/youtu\.be\/([A-Za-z0-9_-]{11})$/i)
  if (short) return WATCH_URL_PREFIX + short[1]
  var live = text.match(/^https?:\/\/(?:www\.)?youtube\.com\/live\/([A-Za-z0-9_-]{11})$/i)
  if (live) return WATCH_URL_PREFIX + live[1]
  if (/^(www\.)?(youtube\.com|youtu\.be)\//i.test(text)) return "https://" + text
  return text
}

function videoIdFromUrl(input) {
  var text = String(input === undefined || input === null ? "" : input)
  var match = text.match(/[?&]v=([A-Za-z0-9_-]{11})/)
  if (match) return match[1]
  match = text.match(/youtu\.be\/([A-Za-z0-9_-]{11})/)
  if (match) return match[1]
  match = text.match(/\/live\/([A-Za-z0-9_-]{11})/)
  if (match) return match[1]
  if (/^[A-Za-z0-9_-]{11}$/.test(text.trim())) return text.trim()
  return ""
}

function urlFromVideoId(id) {
  return WATCH_URL_PREFIX + String(id === undefined || id === null ? "" : id)
}

// Aceita string (URL ou termo) ou objeto {kind,value}; devolve null se vazio.
function normalizeItem(raw) {
  var kind = ""
  var value = ""
  if (raw === undefined || raw === null) return null
  if (typeof raw === "string") {
    value = raw.trim()
    if (value === "") return null
    kind = looksLikeUrl(value) ? "url" : "search"
  } else if (typeof raw === "object") {
    value = String(raw.value === undefined || raw.value === null ? "" : raw.value).trim()
    if (value === "") return null
    kind = String(raw.kind === undefined || raw.kind === null ? "" : raw.kind)
    if (kind !== "url" && kind !== "search") kind = looksLikeUrl(value) ? "url" : "search"
  } else {
    return null
  }
  if (kind === "url") value = normalizeUrl(value)
  return { kind: kind, value: value }
}

function itemLabel(item) {
  var normalized = normalizeItem(item)
  if (!normalized) return ""
  return normalized.value
}

function cloneItems(items) {
  var out = []
  if (!items || !items.length) return out
  for (var i = 0; i < items.length; i++) {
    var item = normalizeItem(items[i])
    if (item) out.push(item)
  }
  return out
}

function parsePlaylist(text) {
  if (typeof text !== "string" || text.trim() === "") return { ok: false, error: "arquivo vazio" }
  var raw
  try {
    raw = JSON.parse(text)
  } catch (error) {
    return { ok: false, error: "JSON invalido" }
  }
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return { ok: false, error: "nao e um objeto" }
  if (raw.version !== undefined && Number(raw.version) !== 1) return { ok: false, error: "version nao suportada" }
  if (typeof raw.id !== "string" || raw.id.trim() === "") return { ok: false, error: "id ausente" }
  if (typeof raw.name !== "string") return { ok: false, error: "name ausente" }
  if (!Array.isArray(raw.items)) return { ok: false, error: "items ausente" }
  return {
    ok: true,
    playlist: {
      version: 1,
      id: raw.id.trim(),
      name: raw.name,
      mode: normalizeMode(raw.mode),
      updated: typeof raw.updated === "string" ? raw.updated : "",
      items: cloneItems(raw.items)
    }
  }
}

function serializePlaylist(playlist) {
  var items = []
  if (playlist && playlist.items) {
    for (var i = 0; i < playlist.items.length; i++) {
      var item = normalizeItem(playlist.items[i])
      if (item) items.push(item)
    }
  }
  var payload = {
    version: 1,
    id: String(playlist && playlist.id ? playlist.id : ""),
    name: String(playlist && playlist.name ? playlist.name : "Playlist"),
    mode: normalizeMode(playlist ? playlist.mode : "sequential"),
    updated: String(playlist && playlist.updated ? playlist.updated : ""),
    items: items
  }
  return JSON.stringify(payload, null, 2) + "\n"
}

function addItem(playlist, raw) {
  var item = normalizeItem(raw)
  if (!item) return { ok: false, error: "item vazio" }
  var next = {
    version: 1,
    id: playlist.id,
    name: playlist.name,
    mode: normalizeMode(playlist.mode),
    updated: playlist.updated,
    items: cloneItems(playlist.items)
  }
  next.items.push(item)
  return { ok: true, playlist: next }
}

function removeItemAt(playlist, index) {
  var items = cloneItems(playlist.items)
  var at = Number(index)
  if (!isFinite(at) || at < 0 || at >= items.length) return { ok: false, error: "indice fora da lista" }
  items.splice(at, 1)
  return { ok: true, playlist: withItems(playlist, items) }
}

function moveItem(playlist, index, delta) {
  var items = cloneItems(playlist.items)
  var at = Number(index)
  var step = Number(delta)
  if (!isFinite(at) || at < 0 || at >= items.length) return { ok: false, error: "indice fora da lista" }
  var target = at + (isFinite(step) ? step : 0)
  if (target < 0 || target >= items.length || target === at) return { ok: false, error: "movimento invalido" }
  var moved = items.splice(at, 1)[0]
  items.splice(target, 0, moved)
  return { ok: true, playlist: withItems(playlist, items) }
}

function setMode(playlist, mode) {
  return {
    version: 1,
    id: playlist.id,
    name: playlist.name,
    mode: normalizeMode(mode),
    updated: playlist.updated,
    items: cloneItems(playlist.items)
  }
}

function renamePlaylist(playlist, name) {
  var title = String(name === undefined || name === null ? "" : name).trim()
  if (title === "") return { ok: false, error: "nome vazio" }
  return {
    ok: true,
    playlist: {
      version: 1,
      id: playlist.id,
      name: title,
      mode: normalizeMode(playlist.mode),
      updated: playlist.updated,
      items: cloneItems(playlist.items)
    }
  }
}

function withItems(playlist, items) {
  return {
    version: 1,
    id: playlist.id,
    name: playlist.name,
    mode: normalizeMode(playlist.mode),
    updated: playlist.updated,
    items: items
  }
}

// ----------------------------------------------------------------------- fila

function mulberry32(seed) {
  var state = (Number(seed) >>> 0) || 1
  return function() {
    state = (state + 0x6D2B79F5) >>> 0
    var t = state
    t = Math.imul(t ^ (t >>> 15), t | 1) >>> 0
    t = (t ^ (t + Math.imul(t ^ (t >>> 7), t | 61))) >>> 0
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

function shuffleWithSeed(array, seed) {
  var random = mulberry32(seed)
  var out = (array || []).slice()
  for (var i = out.length - 1; i > 0; i--) {
    var j = Math.floor(random() * (i + 1))
    var swap = out[i]
    out[i] = out[j]
    out[j] = swap
  }
  return out
}

// Fila = itens da playlist (kind/value) + url resolvida (vazia para termos,
// preenchida quando a resolucao acontece) + rotulo mostrado na UI.
function queueFromPlaylist(playlist, seed) {
  var items = playlist && playlist.items ? playlist.items : []
  var queue = []
  for (var i = 0; i < items.length; i++) {
    var item = normalizeItem(items[i])
    if (!item) continue
    queue.push({
      kind: item.kind,
      value: item.value,
      url: item.kind === "url" ? item.value : "",
      label: item.value
    })
  }
  if (normalizeMode(playlist ? playlist.mode : "") === "shuffle" && queue.length > 1) {
    queue = shuffleWithSeed(queue, seed === undefined ? 1 : seed)
  }
  return queue
}

function m3uFromQueue(queue) {
  var lines = ["#EXTM3U"]
  for (var i = 0; i < queue.length; i++) {
    var url = String(queue[i] && queue[i].url ? queue[i].url : "")
    url = url.replace(/[\r\n\t]/g, "").trim()
    if (url !== "") lines.push(url)
  }
  return lines.join("\n") + "\n"
}

function queueJsonFromQueue(queue) {
  var items = []
  for (var i = 0; i < queue.length; i++) {
    var entry = queue[i] || {}
    items.push({
      index: i,
      kind: String(entry.kind || "url"),
      value: String(entry.value || ""),
      url: String(entry.url || ""),
      label: String(entry.label || entry.value || "")
    })
  }
  return JSON.stringify({ version: 1, items: items }, null, 2) + "\n"
}

// ------------------------------------------------------------------- yt-dlp

function parseDuration(text) {
  var raw = String(text === undefined || text === null ? "" : text).trim()
  if (raw === "" || raw === "NA" || raw === "None") return -1
  var parts = raw.split(":")
  if (parts.length < 2 || parts.length > 3) {
    var numeric = Number(raw)
    return isFinite(numeric) && numeric >= 0 ? Math.floor(numeric) : -1
  }
  var seconds = 0
  for (var i = 0; i < parts.length; i++) {
    var piece = Number(parts[i])
    if (!isFinite(piece)) return -1
    seconds = seconds * 60 + piece
  }
  return seconds >= 0 ? Math.floor(seconds) : -1
}

function isVideoId(text) {
  return /^[A-Za-z0-9_-]{6,32}$/.test(String(text === undefined || text === null ? "" : text).trim())
}

function parseSearchLines(stdout, limit) {
  var out = []
  if (typeof stdout !== "string" || stdout === "") return out
  var lines = stdout.split("\n")
  var cap = Number(limit)
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line === undefined || line.trim() === "") continue
    var parts = line.split("\t")
    var id = String(parts[0] === undefined ? "" : parts[0]).trim()
    if (!isVideoId(id)) continue
    var title = String(parts[1] === undefined ? "" : parts[1]).trim()
    var duration = parseDuration(parts[2])
    out.push({
      id: id,
      title: title === "" ? id : title,
      duration: duration,
      url: urlFromVideoId(id)
    })
    if (isFinite(cap) && cap > 0 && out.length >= cap) break
  }
  return out
}

function parseResolveFirstId(stdout) {
  var items = parseSearchLines(stdout, 1)
  return items.length > 0 ? items[0].id : ""
}

// Termo digitado -> comando ytsearch do yt-dlp.
function searchExpression(term, count) {
  var n = Number(count)
  if (!isFinite(n) || n < 1) n = 1
  var cleaned = String(term === undefined || term === null ? "" : term).replace(/[\r\n\t]+/g, " ").trim()
  return SEARCH_PREFIX + Math.floor(n) + ":" + cleaned
}

// ---------------------------------------------------------------- retomada

// Decisao de retomar uma posicao salva. Live/nao-buscavel nunca retoma.
function resumeDecision(options) {
  var opts = options || {}
  var position = Number(opts.position)
  var duration = Number(opts.duration)
  var minSeconds = Number(opts.minSeconds)
  var tail = Number(opts.tailSeconds)
  if (!isFinite(minSeconds)) minSeconds = 30
  if (!isFinite(tail)) tail = 15
  if (opts.seekable !== true) return { resume: false, position: 0, reason: "nao-buscavel" }
  if (!isFinite(duration) || duration <= 0) return { resume: false, position: 0, reason: "live-ou-desconhecida" }
  if (!isFinite(position) || position <= 0) return { resume: false, position: 0, reason: "sem-posicao" }
  if (position < minSeconds) return { resume: false, position: 0, reason: "muito-inicio" }
  if (position > duration - tail) return { resume: false, position: 0, reason: "fim-do-video" }
  return { resume: true, position: position, reason: "ok" }
}

// ------------------------------------------------------------------ formatacao

function visibleTitle(text, max) {
  var clean = String(text === undefined || text === null ? "" : text).replace(/\s+/g, " ").trim()
  var limit = Number(max)
  if (!isFinite(limit) || limit < 4) limit = 42
  limit = Math.floor(limit)
  if (clean.length <= limit) return clean
  return clean.slice(0, limit - 1).replace(/\s+$/, "") + "\u2026"
}

function formatTime(seconds) {
  var value = Number(seconds)
  if (!isFinite(value) || value < 0) return "--:--"
  var total = Math.floor(value)
  var hours = Math.floor(total / 3600)
  var minutes = Math.floor((total % 3600) / 60)
  var secs = total % 60
  var pad = function(n) { return (n < 10 ? "0" : "") + n }
  if (hours > 0) return hours + ":" + pad(minutes) + ":" + pad(secs)
  return minutes + ":" + pad(secs)
}

function clampVolume(value, max) {
  var volume = Number(value)
  var ceiling = Number(max)
  if (!isFinite(ceiling) || ceiling <= 0) ceiling = 130
  if (!isFinite(volume)) return 0
  return Math.max(0, Math.min(ceiling, Math.round(volume)))
}

function parseStatusJson(text) {
  if (typeof text !== "string" || text.trim() === "") return null
  try {
    var raw = JSON.parse(text)
    if (!raw || typeof raw !== "object") return null
    return raw
  } catch (error) {
    return null
  }
}

// ------------------------------------------------------- arquivo de playlists

// Arquivo unico com todas as playlists: {version, playlists:[...]}.
// Texto vazio e o primeiro uso, nao um erro.
function parsePlaylistFile(text) {
  if (typeof text !== "string" || text.trim() === "") return { ok: true, playlists: [] }
  var raw
  try {
    raw = JSON.parse(text)
  } catch (error) {
    return { ok: false, error: "JSON invalido" }
  }
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return { ok: false, error: "nao e um objeto" }
  if (raw.version !== undefined && Number(raw.version) !== 1) return { ok: false, error: "version nao suportada" }
  if (!Array.isArray(raw.playlists)) return { ok: false, error: "playlists ausente" }
  var out = []
  for (var i = 0; i < raw.playlists.length; i++) {
    var entry = raw.playlists[i]
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) continue
    if (typeof entry.id !== "string" || entry.id.trim() === "") continue
    if (typeof entry.name !== "string") continue
    out.push({
      version: 1,
      id: entry.id.trim(),
      name: entry.name,
      mode: normalizeMode(entry.mode),
      updated: typeof entry.updated === "string" ? entry.updated : "",
      items: cloneItems(entry.items)
    })
  }
  return { ok: true, playlists: out }
}

function serializePlaylistFile(playlists) {
  var list = playlists || []
  var out = []
  for (var i = 0; i < list.length; i++) {
    var entry = list[i] || {}
    out.push({
      id: String(entry.id === undefined || entry.id === null ? "" : entry.id),
      name: String(entry.name === undefined || entry.name === null ? "Playlist" : entry.name),
      mode: normalizeMode(entry.mode),
      updated: String(entry.updated === undefined || entry.updated === null ? "" : entry.updated),
      items: cloneItems(entry.items)
    })
  }
  return JSON.stringify({ version: 1, playlists: out }, null, 2) + "\n"
}

// Mantem as `limit` posicoes mais recentes (por `updated`).
function prunePositions(positions, limit) {
  var source = positions || {}
  var max = Number(limit)
  if (!isFinite(max) || max < 1) max = 200
  var keys = Object.keys(source)
  if (keys.length <= max) return source
  keys.sort(function(a, b) {
    var ua = source[a] && source[a].updated ? String(source[a].updated) : ""
    var ub = source[b] && source[b].updated ? String(source[b].updated) : ""
    if (ua === ub) return 0
    return ua < ub ? -1 : 1
  })
  var next = {}
  for (var i = keys.length - max; i < keys.length; i++) next[keys[i]] = source[keys[i]]
  return next
}

// ------------------------------------------------------------------ selfTest

// Devolve "" quando tudo passa, ou "FAIL: <checks>" para o IPC selfTest.
function selfTest() {
  var failures = []
  function check(name, condition) {
    if (!condition) failures.push(name)
  }

  check("slugify", slugify("Minhas Lives! 2026") === "minhas-lives-2026")
  check("slugify-vazio", slugify("!!!") === "")
  check("unique-id", uniquePlaylistId("Lives", ["lives"]) === "lives-2")
  check("unique-id-vazio", uniquePlaylistId("!!!", []) === "playlist")

  check("mode-normalize", normalizeMode("shuffle") === "shuffle" && normalizeMode("bogus") === "sequential")
  check("mode-next", nextMode("shuffle") === "sequential" && nextMode("sequential") === "repeat-one")
  check("mode-label", modeLabel("repeat-all") === "Repetir playlist")

  check("url-detect-http", looksLikeUrl("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
  check("url-detect-id", looksLikeUrl("dQw4w9WgXcQ"))
  check("url-detect-termo", !looksLikeUrl("dw news live"))
  check("url-detect-bare-domain", !looksLikeUrl("youtube.com"))
  check("url-normalize-id", normalizeUrl("dQw4w9WgXcQ") === WATCH_URL_PREFIX + "dQw4w9WgXcQ")
  check("video-id", videoIdFromUrl("https://youtu.be/dQw4w9WgXcQ?t=10") === "dQw4w9WgXcQ")
  check("video-id-live", videoIdFromUrl("https://www.youtube.com/live/dQw4w9WgXcQ") === "dQw4w9WgXcQ")

  check("item-termo", normalizeItem("dw news live").kind === "search")
  check("item-url", normalizeItem("https://youtu.be/dQw4w9WgXcQ").kind === "url")
  check("item-vazio", normalizeItem("   ") === null)

  var sampleUrl = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
  var base = emptyPlaylist("Lives", "lives")
  base.items = [normalizeItem("https://youtu.be/dQw4w9WgXcQ"), normalizeItem("dw news live")]
  var roundTrip = parsePlaylist(serializePlaylist(base))
  check("playlist-roundtrip", roundTrip.ok && roundTrip.playlist.name === "Lives"
    && roundTrip.playlist.id === "lives" && roundTrip.playlist.items.length === 2)
  check("playlist-json-invalido", parsePlaylist("nao e json").ok === false)
  check("playlist-versao", parsePlaylist('{"version":2,"id":"a","name":"A","items":[]}').ok === false)
  check("playlist-sem-id", parsePlaylist('{"version":1,"name":"A","items":[]}').ok === false)
  check("playlist-vazia", parsePlaylist("").ok === false)

  var added = addItem(base, sampleUrl)
  check("add-item", added.ok && added.playlist.items.length === 3 && added.playlist.items[2].kind === "url")
  check("add-item-vazio", addItem(base, "  ").ok === false)
  var removed = removeItemAt(base, 0)
  check("remove-item", removed.ok && removed.playlist.items.length === 1
    && removed.playlist.items[0].value === "dw news live")
  check("remove-item-fora", removeItemAt(base, 9).ok === false)
  var moved = moveItem(base, 0, 1)
  check("move-item", moved.ok && moved.playlist.items[0].value === "dw news live"
    && moved.playlist.items[1].value === sampleUrl)
  check("move-item-fora", moveItem(base, 1, 1).ok === false)
  check("rename", renamePlaylist(base, "  Nova  ").playlist.name === "Nova")
  check("rename-vazio", renamePlaylist(base, " ").ok === false)
  check("set-mode", setMode(base, "repeat-one").mode === "repeat-one")

  var queue = queueFromPlaylist(base, 7)
  check("queue-tamanho", queue.length === 2)
  check("queue-url", queue[0].kind === "url" && queue[0].url === sampleUrl)
  check("queue-search-sem-url", queue[1].kind === "search" && queue[1].url === "")
  check("m3u", m3uFromQueue(queue) === "#EXTM3U\n" + sampleUrl + "\n")
  check("queue-json", parseStatusJson(queueJsonFromQueue(queue)).items.length === 2)

  var shuffledPlaylist = setMode(base, "shuffle")
  var shuffled = queueFromPlaylist(shuffledPlaylist, 42)
  check("shuffle-permuta", shuffled.length === 2
    && shuffled.map(function(entry) { return entry.value }).sort().join("|")
      === base.items.map(function(entry) { return entry.value }).sort().join("|"))
  check("shuffle-deterministico",
    queueFromPlaylist(shuffledPlaylist, 42).map(function(e) { return e.value }).join("|")
      === shuffled.map(function(e) { return e.value }).join("|"))
  check("shuffle-nao-afeta-original", base.items[0].value === sampleUrl)

  check("mpv-props-sequencial", modeToMpvProps("sequential").loopFile === "no"
    && modeToMpvProps("sequential").loopPlaylist === "no")
  check("mpv-props-faixa", modeToMpvProps("repeat-one").loopFile === "inf")
  check("mpv-props-playlist", modeToMpvProps("repeat-all").loopPlaylist === "inf")
  check("mpv-props-aleatorio", modeToMpvProps("shuffle").loopPlaylist === "inf")

  var live = resumeDecision({ seekable: true, duration: 0, position: 500, minSeconds: 30, tailSeconds: 15 })
  check("resume-live", live.resume === false && live.reason === "live-ou-desconhecida")
  check("resume-nao-buscavel", resumeDecision({ seekable: false, duration: 600, position: 300 }).resume === false)
  check("resume-inicio", resumeDecision({ seekable: true, duration: 600, position: 10, minSeconds: 30 }).resume === false)
  check("resume-fim", resumeDecision({ seekable: true, duration: 600, position: 595, minSeconds: 30 }).resume === false)
  var ok = resumeDecision({ seekable: true, duration: 600, position: 300, minSeconds: 30, tailSeconds: 15 })
  check("resume-ok", ok.resume === true && ok.position === 300)
  check("resume-sem-duration", resumeDecision({ seekable: true, duration: -1, position: 300 }).resume === false)

  var parsed = parseSearchLines("dQw4w9WgXcQ\tTitulo 1\t12:34\n"
    + "abc12345678\tTitulo 2\tNA\nlinha invalida\n", 10)
  check("search-parse", parsed.length === 2 && parsed[0].duration === 754 && parsed[1].duration === -1)
  check("search-url", parsed[0].url === WATCH_URL_PREFIX + "dQw4w9WgXcQ")
  check("search-limit", parseSearchLines("dQw4w9WgXcQ\tA\t1:00\nabc12345678\tB\t2:00\n", 1).length === 1)
  check("search-resolve", parseResolveFirstId("dQw4w9WgXcQ\tTitulo\t1:00\n") === "dQw4w9WgXcQ")
  check("search-expression", searchExpression("dw news live", 10) === "ytsearch10:dw news live")
  check("search-expression-limpa", searchExpression("a\tb\nc", 1) === "ytsearch1:a b c")
  check("duration-hh", parseDuration("1:02:03") === 3723)
  check("duration-mm", parseDuration("12:34") === 754)
  check("duration-segundos", parseDuration("90") === 90)
  check("duration-na", parseDuration("NA") === -1)

  check("titulo-curto", visibleTitle("abc", 10) === "abc")
  check("titulo-truncado", visibleTitle("abcdef", 4) === "abc\u2026")
  check("titulo-espacos", visibleTitle("  a   b  ", 10) === "a b")
  check("tempo-mm", formatTime(754) === "12:34")
  check("tempo-hh", formatTime(3723) === "1:02:03")
  check("tempo-invalido", formatTime(-1) === "--:--")
  check("volume-clamp", clampVolume(200) === 130 && clampVolume(-5) === 0 && clampVolume("40") === 40)
  check("status-json", parseStatusJson('{"a":1}').a === 1 && parseStatusJson("xx") === null)

  var fileEmpty = parsePlaylistFile("")
  check("playlist-file-vazio", fileEmpty.ok === true && fileEmpty.playlists.length === 0)
  var fileRound = parsePlaylistFile(serializePlaylistFile([base, shuffledPlaylist]))
  check("playlist-file-roundtrip", fileRound.ok === true && fileRound.playlists.length === 2
    && fileRound.playlists[1].mode === "shuffle" && fileRound.playlists[0].items.length === 2)
  check("playlist-file-invalido", parsePlaylistFile("{oops").ok === false)
  check("playlist-file-sem-lista", parsePlaylistFile('{"version":1}').ok === false)
  var fileSujeira = parsePlaylistFile('{"version":1,"playlists":[{"id":"a","name":"A"},5,{"nome":"x"}]}')
  check("playlist-file-sujeira", fileSujeira.ok === true && fileSujeira.playlists.length === 1)

  var posicoes = {}
  for (var p = 0; p < 5; p++) posicoes["u" + p] = { pos: p, updated: "2026-01-0" + (p + 1) + "T00:00:00Z" }
  var podado = prunePositions(posicoes, 2)
  check("prune-posicoes", Object.keys(podado).length === 2
    && podado["u4"] !== undefined && podado["u3"] !== undefined && podado["u0"] === undefined)
  check("prune-posicoes-sem-excesso", prunePositions({ a: 1 }, 10).a === 1)

  if (failures.length > 0) return "FAIL: " + failures.join(", ")
  return ""
}
