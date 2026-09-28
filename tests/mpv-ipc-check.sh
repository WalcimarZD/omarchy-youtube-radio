#!/usr/bin/env bash
# Diagnostico: valida no mpv real os comandos, propriedades e eventos que o
# plugin usa (fila nativa, observe_property, retomada por time-pos, loop).
#
# Nao abre janela e nao reproduz audio (--ao=null), apenas resolve o stream.
# Requer: mpv, yt-dlp, socat e rede.
#
#   tests/mpv-ipc-check.sh [url-de-teste]
set -uo pipefail

VIDEO_URL="${1:-https://www.youtube.com/watch?v=jNQXAC9IVRw}"
WORKDIR=$(mktemp -d)
SOCK="$WORKDIR/mpv.sock"
EVENTS="$WORKDIR/events.log"
FIFO="$WORKDIR/in.fifo"
MPV_PID=""
FAILURES=0

cleanup() {
  exec 3>&- 2>/dev/null || true
  [[ -n $MPV_PID ]] && kill "$MPV_PID" 2>/dev/null
  pkill -f "input-ipc-server=$SOCK" 2>/dev/null
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

command -v mpv >/dev/null || { echo "FAIL: mpv nao encontrado"; exit 1; }
command -v yt-dlp >/dev/null || { echo "FAIL: yt-dlp nao encontrado"; exit 1; }
command -v socat >/dev/null || { echo "FAIL: socat nao encontrado"; exit 1; }

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

check() {
  local label="$1" expected="$2" actual="$3"
  if [[ $actual == "$expected" ]]; then pass "$label ($actual)"; else fail "$label: esperado '$expected', obtido '$actual'"; fi
}

# ---------------------------------------------------------------- sobe o mpv
setsid --fork mpv \
  --no-config --idle=yes --no-video --audio-display=no --force-window=no --terminal=no --ao=null \
  --input-ipc-server="$SOCK" --volume=50 \
  --ytdl=yes --ytdl-format=bestaudio/best \
  --ytdl-raw-options=socket-timeout=15,retries=1 \
  --network-timeout=30 --keep-open=no --save-position-on-quit=no \
  >"$WORKDIR/mpv.log" 2>&1

for _ in $(seq 1 60); do [[ -S $SOCK ]] && break; sleep 0.25; done
[[ -S $SOCK ]] || { echo "FAIL: soquete do mpv nao apareceu"; cat "$WORKDIR/mpv.log"; exit 1; }
MPV_PID=$(pgrep -f "input-ipc-server=$SOCK" | head -1)
pass "mpv vivo no soquete (pid ${MPV_PID:-?})"

# Conexao persistente: escreve comandos no fifo, le eventos/linhas de resposta.
mkfifo "$FIFO"
socat - UNIX-CONNECT:"$SOCK" <"$FIFO" >"$EVENTS" 2>&1 &
exec 3>"$FIFO"
send() { printf '%s\n' "$1" >&3; }
reply() { printf '%s\n' "$1" >&3; }

wait_for() { # wait_for <regex> <timeout-segundos>
  local pattern="$1" limit="${2:-60}" i
  for ((i = 0; i < limit * 4; i++)); do
    grep -q -- "$pattern" "$EVENTS" 2>/dev/null && return 0
    sleep 0.25
  done
  return 1
}

last_data() { # ultima resposta com "request_id":N -> campo data
  local id="$1"
  grep -o "{\"data\":[^,]*,\"request_id\":$id,\"error\":\"[a-z ]*\"}" "$EVENTS" | tail -1 | sed -E 's/^\{"data":(.*),"request_id".*/\1/'
}

# ------------------------------------------------------- observa propriedades
NAMES=(media-title pause time-pos duration volume idle-active playlist-pos playlist-count seekable path mute)
for i in "${!NAMES[@]}"; do
  send "{\"command\":[\"observe_property\",$((i + 1)),\"${NAMES[$i]}\"]}"
done
sleep 1

reply '{"command":["get_property","video"],"request_id":101}'
wait_for '"request_id":101' 10
check "audio-only (video=false)" "false" "$(last_data 101)"

# ------------------------------------------------------------------- play
send "{\"command\":[\"loadfile\",\"$VIDEO_URL\",\"replace\"]}"
if wait_for '"event":"file-loaded"' 90; then
  pass "file-loaded para $VIDEO_URL"
else
  fail "file-loaded nao chegou em 90s"
  sed -n '1,30p' "$WORKDIR/mpv.log"
fi
sleep 2

reply '{"command":["get_property","video"],"request_id":102}'
reply '{"command":["get_property","media-title"],"request_id":103}'
reply '{"command":["get_property","path"],"request_id":104}'
reply '{"command":["get_property","duration"],"request_id":105}'
reply '{"command":["get_property","seekable"],"request_id":106}'
reply '{"command":["get_property","playlist-count"],"request_id":107}'
wait_for '"request_id":107' 30

check "video continua false" "false" "$(last_data 102)"
TITLE="$(last_data 103)"
[[ -n $TITLE && $TITLE != "null" ]] && pass "media-title: $TITLE" || fail "media-title vazio"
MPV_PATH="$(last_data 104)"
[[ -n $MPV_PATH && $MPV_PATH != "null" ]] && pass "path: $MPV_PATH" || fail "path vazio"
DURATION="$(last_data 105)"
[[ $DURATION != "null" ]] && pass "duration: $DURATION" || fail "duration indisponivel (live?)"
check "seekable" "true" "$(last_data 106)"
check "playlist-count com 1 item" "1" "$(last_data 107)"

# ------------------------------------------------- confere eventos observados
for name in media-title time-pos duration; do
  if grep -q "\"event\":\"property-change\",\"id\":[0-9]*,\"name\":\"$name\"" "$EVENTS"; then
    pass "evento property-change de $name"
  else
    fail "sem property-change de $name"
  fi
done

# ---------------------------------------------------------------- retomada
send '{"command":["set_property","time-pos",5]}'
sleep 2
reply '{"command":["get_property","time-pos"],"request_id":108}'
wait_for '"request_id":108' 10
POS="$(last_data 108)"
if [[ $POS =~ ^[0-9] ]] && awk -v p="$POS" 'BEGIN { exit !(p >= 4.0) }'; then
  pass "retomada: set_property time-pos aceito (pos=$POS)"
else
  fail "retomada: time-pos nao chegou perto de 5 (pos=$POS)"
fi

# ------------------------------------------------------------------ fila
M3U="$WORKDIR/queue.m3u"
{
  printf '#EXTM3U\n'
  printf '%s\n' "$VIDEO_URL"
  printf '%s\n' "$VIDEO_URL"
} >"$M3U"
send "{\"command\":[\"loadlist\",\"$M3U\",\"replace\"]}"
sleep 4
reply '{"command":["get_property","playlist-count"],"request_id":109}'
reply '{"command":["get_property","playlist-pos"],"request_id":110}'
wait_for '"request_id":110' 30
check "loadlist m3u -> playlist-count" "2" "$(last_data 109)"
check "loadlist m3u -> playlist-pos inicial" "0" "$(last_data 110)"

send '{"command":["set_property","playlist-pos",1]}'
sleep 4
reply '{"command":["get_property","playlist-pos"],"request_id":111}'
wait_for '"request_id":111' 20
check "playlist-pos e gravavel" "1" "$(last_data 111)"

# ------------------------------------------------------------------- loop
send '{"command":["set_property","loop-file","inf"]}'
send '{"command":["set_property","loop-playlist","inf"]}'
sleep 1
reply '{"command":["get_property","loop-file"],"request_id":112}'
reply '{"command":["get_property","loop-playlist"],"request_id":113}'
wait_for '"request_id":113' 10
check "loop-file=inf" '"inf"' "$(last_data 112)"
check "loop-playlist=inf" '"inf"' "$(last_data 113)"
send '{"command":["set_property","loop-file","no"]}'
send '{"command":["set_property","loop-playlist","no"]}'

# --------------------------------------------------------- avanco e parada
send '{"command":["playlist-next","force"]}'
sleep 3
reply '{"command":["get_property","playlist-pos"],"request_id":114}'
wait_for '"request_id":114' 20
NEXT_POS="$(last_data 114)"
[[ $NEXT_POS != "null" ]] && pass "playlist-next aceito (pos=$NEXT_POS)" || fail "playlist-next nao mudou playlist-pos"

send '{"command":["stop"]}'
sleep 2
reply '{"command":["get_property","idle-active"],"request_id":115}'
wait_for '"request_id":115' 10
check "stop -> idle-active" "true" "$(last_data 115)"

# ------------------------------------------------------------------- veredito
echo
if ((FAILURES == 0)); then
  echo "MPV_IPC_CHECK_OK"
  exit 0
fi
echo "MPV_IPC_CHECK_FAIL: $FAILURES"
echo "--- eventos (ultimas 20 linhas) ---"
tail -20 "$EVENTS"
exit 1
