#!/usr/bin/env bash
# Aceitacao ao vivo do youtube-radio: exercita o plugin instalado no shell
# Omarchy por IPC e confere o estado real do mpv pelo soquete Unix.
#
#   tests/live-check.sh [url-do-youtube]
#
# Requer: omarchy-shell (shell rodando), mpv, yt-dlp, socat, jq e rede.
# AVISO: reproduz audio de verdade (no volume atual do player).
set -uo pipefail

VIDEO_URL="${1:-https://www.youtube.com/watch?v=aqz-KE-bpKQ}"
SHORT_TERM="${SHORT_TERM:-me at the zoo}"
SHORT_VIDEO="${SHORT_VIDEO:-https://www.youtube.com/watch?v=jNQXAC9IVRw}"
RUNTIME="${XDG_RUNTIME_DIR:-/tmp}/youtube-radio"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}/youtube-radio"
SOCK="$RUNTIME/mpv.sock"
PLAYLISTS="$DATA/playlists.json"
STATE="$DATA/state.json"
FAILURES=0
TEST_PLAYLIST_ID=""

cleanup() {
  [[ -n $TEST_PLAYLIST_ID ]] && omarchy-shell -q youtube-radio deletePlaylist "$TEST_PLAYLIST_ID" >/dev/null 2>&1
  omarchy-shell -q youtube-radio quitPlayer >/dev/null 2>&1
}
trap cleanup EXIT

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
check() {
  local label="$1" expected="$2" actual="$3"
  if [[ $actual == "$expected" ]]; then pass "$label ($actual)"; else fail "$label: esperado '$expected', obtido '$actual'"; fi
}

rc() { timeout 25 omarchy-shell youtube-radio "$@" 2>&1; }
st() { rc status; }
jqv() { st | jq -r "$1" 2>/dev/null; }
mpvq() {
  printf '{"command":["get_property","%s"],"request_id":1}\n' "$1" \
    | timeout 5 socat - UNIX-CONNECT:"$SOCK" 2>/dev/null \
    | jq -r '.data' 2>/dev/null
}

wait_for() { # wait_for <expressao-jq> <valor> <timeout-s> [rotulo]
  local expr="$1" want="$2" limit="$3" label="${4:-condicao}"
  local i value
  for ((i = 0; i < limit * 2; i++)); do
    value=$(jqv "$expr")
    [[ $value == "$want" ]] && return 0
    sleep 0.5
  done
  fail "timeout esperando $label ($expr == $want; ultimo '$value')"
  return 1
}

command -v omarchy-shell >/dev/null || { echo "FAIL: omarchy-shell nao encontrado"; exit 1; }
command -v socat >/dev/null || { echo "FAIL: socat nao encontrado"; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq nao encontrado"; exit 1; }

echo "== base =="
check "selfTest" "ok" "$(rc selfTest)"
check "status responde" "true" "$(st | jq -r '.storageReady')"

echo
echo "== tocar uma URL (audio apenas) =="
rc playUrl "$VIDEO_URL" >/dev/null
if wait_for '.title | length > 0' true 90 "titulo da faixa"; then
  pass "titulo: $(jqv .title)"
fi
check "playerRunning" "true" "$(jqv .playerRunning)"
check "ipcReady" "true" "$(jqv .ipcReady)"
check "queue com 1 item" "1" "$(jqv .count)"
check "mpv sem video" "false" "$(mpvq video)"
check "mpv playlist-count" "1" "$(mpvq playlist-count)"
check "mpv media-title == status.title" "$(jqv .title)" "$(mpvq media-title)"

POS1=$(jqv .position)
sleep 4
POS2=$(jqv .position)
if awk -v a="$POS1" -v b="$POS2" 'BEGIN { exit !(b > a) }'; then
  pass "time-pos avancou ($POS1 -> $POS2)"
else
  fail "time-pos nao avancou ($POS1 -> $POS2)"
fi

echo
echo "== play/pause, buscar, volume =="
rc playPause >/dev/null
wait_for '.paused' true 10 "pause"
pass "pause pelo IPC"
rc playPause >/dev/null
wait_for '.paused' false 10 "resume"
pass "retomada pelo IPC"

sleep 6
BEFORE_SEEK=$(jqv .position)
rc seekBackward >/dev/null
sleep 2
AFTER_SEEK=$(jqv .position)
if awk -v a="$BEFORE_SEEK" -v b="$AFTER_SEEK" 'BEGIN { exit !(b < a) }'; then
  pass "seek -15s ($BEFORE_SEEK -> $AFTER_SEEK)"
else
  fail "seek -15s nao recuou ($BEFORE_SEEK -> $AFTER_SEEK)"
fi

VOL0=$(jqv .volume)
rc volume 5 >/dev/null
check "volume +5" "$((VOL0 + 5))" "$(jqv .volume)"
rc volume -5 >/dev/null

rc search "$SHORT_TERM" >/dev/null
if wait_for '.searchResults | length > 0' true 60 "resultados da busca"; then
  pass "busca retornou $(st | jq -r '.searchResults | length') resultados"
  check "primeiro resultado e uma URL" "true" "$(st | jq -r '.searchResults[0].url | test("watch\\?v=")')"
fi

echo
echo "== playlists locais (CRUD) =="
TEST_PLAYLIST_ID=$(rc createPlaylist "Teste Automatizado" | tr -d '\n')
[[ -n $TEST_PLAYLIST_ID ]] && pass "playlist criada: $TEST_PLAYLIST_ID" || fail "createPlaylist nao devolveu id"
check "persistida em disco" "1" "$(jq --arg id "$TEST_PLAYLIST_ID" '[.playlists[] | select(.id == $id)] | length' "$PLAYLISTS")"

check "add URL" "ok" "$(rc addPlaylistItem "$TEST_PLAYLIST_ID" "$VIDEO_URL")"
check "add termo de busca" "ok" "$(rc addPlaylistItem "$TEST_PLAYLIST_ID" "$SHORT_TERM")"
check "2 itens salvos" "2" "$(jq --arg id "$TEST_PLAYLIST_ID" '.playlists[] | select(.id == $id) | .items | length' "$PLAYLISTS")"

check "renomear" "ok" "$(rc renamePlaylist "$TEST_PLAYLIST_ID" "Teste Renomeado")"
check "nome novo no arquivo" "1" "$(jq --arg id "$TEST_PLAYLIST_ID" '[.playlists[] | select(.id == $id and .name == "Teste Renomeado")] | length' "$PLAYLISTS")"
check "id estavel apos renomear" "1" "$(jq --arg id "$TEST_PLAYLIST_ID" '[.playlists[] | select(.id == $id)] | length' "$PLAYLISTS")"

check "reordenar" "ok" "$(rc movePlaylistItem "$TEST_PLAYLIST_ID" 1 -1)"
check "termo ficou primeiro" "$SHORT_TERM" "$(jq -r --arg id "$TEST_PLAYLIST_ID" '.playlists[] | select(.id == $id) | .items[0].value' "$PLAYLISTS")"

check "remover item" "ok" "$(rc removePlaylistItem "$TEST_PLAYLIST_ID" 0)"
check "1 item restante" "1" "$(jq --arg id "$TEST_PLAYLIST_ID" '.playlists[] | select(.id == $id) | .items | length' "$PLAYLISTS")"

echo
echo "== tocar a playlist (fila do mpv) =="
rc playPlaylist "$TEST_PLAYLIST_ID" >/dev/null
if wait_for '.count' 1 60 "fila carregada"; then
  pass "fila do plugin com 1 item"
fi
check "mpv playlist-count == fila" "1" "$(mpvq playlist-count)"
check "playlist atual registrada" "$TEST_PLAYLIST_ID" "$(jqv .playlist)"

echo
echo "== avanco automatico entre itens =="
ADV_ID=$(rc createPlaylist "Avanco Automatico" | tr -d '\n')
if [[ -z $ADV_ID ]]; then
  fail "nao foi possivel criar a playlist de avanco"
else
  rc addPlaylistItem "$ADV_ID" "$SHORT_VIDEO" >/dev/null
  rc addPlaylistItem "$ADV_ID" "$SHORT_VIDEO" >/dev/null
  rc setMode sequential >/dev/null
  rc playPlaylist "$ADV_ID" >/dev/null
  wait_for '.count' 2 60 "fila com 2 itens"
  ADVANCED=""
  for ((i = 0; i < 70; i++)); do
    P=$(mpvq playlist-pos)
    if [[ $P == "1" ]]; then ADVANCED="1"; break; fi
    [[ $(mpvq idle-active) == "true" ]] && break
    sleep 1
  done
  if [[ $ADVANCED == "1" ]]; then
    pass "avancou sozinho para o item 2 ao terminar o item 1"
  else
    fail "nao avancou de faixa em 70s (playlist-pos=$(mpvq playlist-pos))"
  fi
  rc deletePlaylist "$ADV_ID" >/dev/null
fi

echo
echo "== modos de reproducao =="
# mpv reporta opcoes de escolha "no" como booleano false e "inf" como string.
modeval() {
  case "$(mpvq "$1")" in
    false | "no") echo no ;;
    true | "yes") echo yes ;;
    *) mpvq "$1" ;;
  esac
}
rc setMode sequential >/dev/null; sleep 1
check "sequencial loop-file" "no" "$(modeval loop-file)"
check "sequencial loop-playlist" "no" "$(modeval loop-playlist)"
rc setMode repeat-one >/dev/null; sleep 1
check "repetir faixa loop-file" "inf" "$(modeval loop-file)"
rc setMode repeat-all >/dev/null; sleep 1
check "repetir playlist loop-playlist" "inf" "$(modeval loop-playlist)"
check "repetir playlist loop-file" "no" "$(modeval loop-file)"
rc setMode shuffle >/dev/null; sleep 1
check "aleatorio loop-playlist" "inf" "$(modeval loop-playlist)"
check "modo no status" "shuffle" "$(jqv .mode)"
rc setMode sequential >/dev/null; sleep 1

echo
echo "== retomada por URL =="
# O limiar padrao de retomada e resumeMinSeconds=30: ouve o suficiente para
# que a posicao salva seja considerada retomavel.
rc playUrl "$VIDEO_URL" >/dev/null
wait_for '.title | length > 0' true 90 "faixa para retomada"
sleep 35
rc savePositionNow >/dev/null
SAVED=$(jq -r --arg u "$VIDEO_URL" '.positions[$u].pos // 0' "$STATE" 2>/dev/null)
if awk -v p="$SAVED" 'BEGIN { exit !(p > 30) }'; then
  pass "posicao salva em state.json ($SAVED)"
else
  fail "posicao nao foi salva acima do limiar em state.json (valor '$SAVED')"
fi

rc quitPlayer >/dev/null
sleep 2
# O mpv pode deixar o arquivo do soquete para tras mesmo saindo limpo; o que
# importa e nao haver mais ninguem escutando.
if timeout 3 socat - UNIX-CONNECT:"$SOCK" </dev/null >/dev/null 2>&1; then
  fail "mpv ainda responde no soquete apos quitPlayer"
else
  pass "mpv encerrado (soquete sem listener)"
fi
check "playerRunning false apos quit" "false" "$(jqv .playerRunning)"

rc playUrl "$VIDEO_URL" >/dev/null
wait_for '.title | length > 0' true 90 "retomada"
sleep 6
RESUMED=$(mpvq time-pos)
if [[ $RESUMED =~ ^[0-9] ]] && awk -v r="$RESUMED" -v s="$SAVED" 'BEGIN { exit !(r >= s - 12) }'; then
  pass "retomou perto da posicao salva ($RESUMED >= $SAVED - 12)"
else
  fail "nao retomou ($RESUMED vs salvo $SAVED)"
fi

echo
echo "== estado sobrevive a reload do shell =="
PID_BEFORE=$(mpvq pid)
TITLE_BEFORE=$(jqv .title)
timeout 30 omarchy-shell shell rescanPlugins >/dev/null 2>&1
sleep 4
check "mpv continua vivo" "true" "$(jqv .playerRunning)"
check "IPC reconectado" "true" "$(jqv .ipcReady)"
check "titulo preservado" "$TITLE_BEFORE" "$(jqv .title)"
PID_AFTER=$(mpvq pid)
check "mesmo processo mpv" "$PID_BEFORE" "$PID_AFTER"

echo
echo "== limpeza =="
check "apagar playlist de teste" "ok" "$(rc deletePlaylist "$TEST_PLAYLIST_ID")"
check "playlist removida do arquivo" "0" "$(jq --arg id "$TEST_PLAYLIST_ID" '[.playlists[] | select(.id == $id)] | length' "$PLAYLISTS")"
TEST_PLAYLIST_ID=""
rc quitPlayer >/dev/null

echo
if ((FAILURES == 0)); then
  echo "LIVE_CHECK_OK"
  exit 0
fi
echo "LIVE_CHECK_FAIL: $FAILURES"
exit 1
