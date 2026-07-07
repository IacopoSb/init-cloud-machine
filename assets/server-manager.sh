#!/usr/bin/env bash
# =============================================================================
#  server-manager.sh — TUI per gestire i tuoi stack docker compose
# -----------------------------------------------------------------------------
#  Struttura attesa:  <APPS_DIR>/<progetto>/docker-compose.yml
#  Dati/quote attese: <DATA_DIR>/<stack>/         (default /data)
#
#  Config persistente:  ~/.config/server-manager.conf  (sezione IMPOSTAZIONI)
#  Env (override):      DM_APPS_DIR DM_DATA_DIR DM_FETCH_INTERVAL DM_RENDER_TICK NO_COLOR DOCKER_CONFIG
#
#  Navigazione: Tab = menu/contenuto · 1-6 = sezione · ← torna al menu
#               Esc = indietro · q = esce · ? = aiuto
#
#  Dipende da: bash>=4.2, docker, awk, coreutils. curl solo per sfogliare i registry. (jq opzionale)
# =============================================================================

set -o pipefail

if [ -z "${BASH_VERSION:-}" ]; then echo "Questo script richiede bash." >&2; exit 1; fi
if ((BASH_VERSINFO[0] < 4)); then echo "Serve bash >= 4 (hai $BASH_VERSION)." >&2; exit 1; fi
if [[ ${DM_NO_MAIN:-0} != 1 ]]; then
  command -v docker >/dev/null 2>&1 || { echo "docker non trovato nel PATH." >&2; exit 1; }

  if docker compose version >/dev/null 2>&1; then DC=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then DC=(docker-compose)
  else echo "Ne' 'docker compose' ne' 'docker-compose' sono disponibili." >&2; exit 1; fi
else
  DC=(docker compose)
fi

# ---- config (default < file < env) -----------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CONF_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/server-manager.conf"

BRAND="MEXAGE"
APPS_DIR="$SCRIPT_DIR/apps"
DATA_DIR="/home/mexage/data"
QUOTA_CONF="/etc/init-cloud-machine/quota.conf"
QUOTA_MNT="/"
FETCH_INTERVAL=2
RENDER_TICK=1
SIZE_EVERY=5
COMPOSE_CANDIDATES=(docker-compose.yml docker-compose.yaml compose.yml compose.yaml)
REG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/server-manager.registries"

load_config(){
  [[ -f $CONF_FILE ]] || return 0
  local k v
  while IFS='=' read -r k v; do
    v="${v%\"}"; v="${v#\"}"
    case "$k" in
      BRAND)          BRAND="$v";;
      APPS_DIR)       APPS_DIR="$v";;
      DATA_DIR)       DATA_DIR="$v";;
      QUOTA_CONF)     QUOTA_CONF="$v";;
      QUOTA_MNT)      QUOTA_MNT="$v";;
      FETCH_INTERVAL) [[ $v =~ ^[0-9]+([.][0-9]+)?$ ]] && FETCH_INTERVAL="$v";;
      RENDER_TICK)    [[ $v =~ ^[0-9]+([.][0-9]+)?$ ]] && RENDER_TICK="$v";;
    esac
  done < "$CONF_FILE"
}
save_config(){
  mkdir -p "$(dirname "$CONF_FILE")" 2>/dev/null
  {
    echo "# server-manager — generato automaticamente (sezione IMPOSTAZIONI)"
    echo "BRAND=\"$BRAND\""
    echo "APPS_DIR=\"$APPS_DIR\""
    echo "DATA_DIR=\"$DATA_DIR\""
    echo "QUOTA_CONF=\"$QUOTA_CONF\""
    echo "QUOTA_MNT=\"$QUOTA_MNT\""
    echo "FETCH_INTERVAL=$FETCH_INTERVAL"
    echo "RENDER_TICK=$RENDER_TICK"
  } > "$CONF_FILE" 2>/dev/null
}
load_config
[[ -n ${DM_BRAND:-} ]]          && BRAND="$DM_BRAND"
[[ -n ${DM_APPS_DIR:-} ]]       && APPS_DIR="$DM_APPS_DIR"
[[ -n ${DM_DATA_DIR:-} ]]       && DATA_DIR="$DM_DATA_DIR"
[[ -n ${DM_QUOTA_CONF:-} ]]     && QUOTA_CONF="$DM_QUOTA_CONF"
[[ -n ${DM_QUOTA_MNT:-} ]]      && QUOTA_MNT="$DM_QUOTA_MNT"
[[ -n ${DM_FETCH_INTERVAL:-} ]] && FETCH_INTERVAL="$DM_FETCH_INTERVAL"
[[ -n ${DM_RENDER_TICK:-} ]]    && RENDER_TICK="$DM_RENDER_TICK"

PS_FMT='{{.ID}}\t{{.Label "com.docker.compose.project"}}\t{{.Label "com.docker.compose.service"}}\t{{.Label "com.docker.compose.project.working_dir"}}\t{{.Status}}\t{{.Names}}'
STATS_FMT='{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}'
SIZE_FMT='{{.Names}}\t{{.Size}}'

TMPDIR_RUN="$(mktemp -d)"
PS_FILE="$TMPDIR_RUN/ps"; STATS_FILE="$TMPDIR_RUN/stats"; SIZE_FILE="$TMPDIR_RUN/size"
OK_FILE="$TMPDIR_RUN/ok"
: > "$PS_FILE"; : > "$STATS_FILE"; : > "$SIZE_FILE"; echo 0 > "$OK_FILE"
FETCH_PID=""
HOST_G="$(hostname)"
DOCKER_OK=0

# ---- colori / tema ----------------------------------------------------------
if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  C_RESET=$'\e[0m';  C_DIM=$'\e[2m';   C_BOLD=$'\e[1m'
  C_AZ=$'\e[38;5;45m'; C_AZ2=$'\e[38;5;39m'
  C_AZBG=$'\e[48;5;24m\e[38;5;195m'
  C_OK=$'\e[38;5;42m'; C_WARN=$'\e[38;5;214m'; C_ERR=$'\e[38;5;203m'
  C_GREY=$'\e[38;5;244m'
  C_OKBG=$'\e[48;5;22m\e[38;5;231m'
  C_WARNBG=$'\e[48;5;94m\e[38;5;231m'
  C_ERRBG=$'\e[48;5;52m\e[38;5;231m'
  C_INFOBG=$'\e[48;5;24m\e[38;5;231m'
  USE_COLOR=1
else
  C_RESET=; C_DIM=; C_BOLD=; C_AZ=; C_AZ2=; C_AZBG=; C_OK=; C_WARN=; C_ERR=; C_GREY=
  C_OKBG=; C_WARNBG=; C_ERRBG=; C_INFOBG=
  USE_COLOR=0
fi

# \e[?1000h + \e[?1006h: cattura la rotella del mouse (blocca lo scrollback del
# terminale) e la usa per scorrere la lista. Alt-screen (smcup) blocca comunque
# lo scroll all'esterno dell'app.
term_setup(){ tput smcup 2>/dev/null; tput civis 2>/dev/null; stty -echo 2>/dev/null; printf '\e[?1000h\e[?1002h\e[?1006h'; }
term_restore(){ printf '\e[?1000l\e[?1002l\e[?1006l'; tput cnorm 2>/dev/null; tput rmcup 2>/dev/null; stty echo 2>/dev/null; printf '\e[0m'; }
cleanup(){
  [[ -n $FETCH_PID ]] && kill "$FETCH_PID" 2>/dev/null
  term_restore
  rm -rf "$TMPDIR_RUN"
}
trap cleanup EXIT
trap 'exit 0' INT TERM

# ---- geometria / layout a sidebar -------------------------------------------
COLS_G=100; LINES_G=30; DIMS_DIRTY=1
IW=17          # larghezza etichette sidebar
SB_W=18        # colonne totali occupate dalla sidebar (marker + IW)
SB_BLANK=""    # cella sidebar vuota (larghezza SB_W)
DIV_STR=""     # separatore verticale (colorato)
CX=21          # offset colonne prima del contenuto
CW=79          # larghezza area contenuto
trap 'DIMS_DIRTY=1' WINCH
update_dims(){
  (( DIMS_DIRTY )) || return 0
  COLS_G=$(tput cols 2>/dev/null || echo 100)
  LINES_G=$(tput lines 2>/dev/null || echo 30)
  if (( COLS_G < 74 )); then IW=9; else IW=17; fi
  SB_W=$(( IW + 1 ))
  CX=$(( SB_W + 3 ))
  CW=$(( COLS_G - CX )); (( CW < 24 )) && CW=24
  DIV_STR=" ${C_GREY}│${C_RESET} "
  printf -v SB_BLANK '%*s' "$SB_W" ''
  DIMS_DIRTY=0
}

# =============================================================================
#  RACCOLTA DATI (background)
# =============================================================================
fetch_snapshot(){
  if docker ps -a --no-trunc --format "$PS_FMT" >"$PS_FILE.tmp" 2>/dev/null; then
    mv "$PS_FILE.tmp" "$PS_FILE"; echo 1 > "$OK_FILE"
  else
    echo 0 > "$OK_FILE"
  fi
  docker stats --no-stream --format "$STATS_FMT" >"$STATS_FILE.tmp" 2>/dev/null && mv "$STATS_FILE.tmp" "$STATS_FILE"
}
fetch_sizes(){
  docker ps -as --no-trunc --format "$SIZE_FMT" >"$SIZE_FILE.tmp" 2>/dev/null && mv "$SIZE_FILE.tmp" "$SIZE_FILE"
}
fetch_loop(){
  local i=0
  while :; do
    fetch_snapshot
    (( i % SIZE_EVERY == 0 )) && fetch_sizes
    ((i++)); sleep "$FETCH_INTERVAL"
  done
}

# =============================================================================
#  SCOPERTA STRUTTURA
# =============================================================================
declare -a U_NAME U_PATH U_COMPOSE U_PROJNAME U_SVCSTR
derive_name(){ local n="$1"; n="${n,,}"; n="${n//[^a-z0-9_-]/-}"; printf '%s' "$n"; }
detect_project_name(){
  local wd="$1" id p s w st nm
  while IFS=$'\t' read -r id p s w st nm; do
    [[ "$w" == "$wd" && -n $p ]] && { printf '%s' "$p"; return; }
  done < "$PS_FILE"
}
discover(){
  U_NAME=(); U_PATH=(); U_COMPOSE=(); U_PROJNAME=(); U_SVCSTR=()
  [[ -d $APPS_DIR ]] || return 0
  shopt -s nullglob
  local dir name cf found envpath detected pname svcs
  for dir in "$APPS_DIR"/*/; do
    [[ -d $dir ]] || continue
    name=$(basename "$dir")
    found=""
    for cf in "${COMPOSE_CANDIDATES[@]}"; do
      [[ -f "$dir$cf" ]] && { found="$cf"; break; }
    done
    [[ -n $found ]] || continue
    envpath="$(cd "$dir" && pwd -P)"
    detected="$(detect_project_name "$envpath")"
    if [[ -n $detected ]]; then pname="$detected"; else pname="$(derive_name "$name")"; fi
    svcs="$( ( cd "$envpath" && "${DC[@]}" -f "$found" config --services ) 2>/dev/null )"
    if [[ -z $svcs ]]; then
      svcs="$(awk -F'\t' -v wd="$envpath" '$4==wd && $3!="" {print $3}' "$PS_FILE" | sort -u)"
    fi
    U_NAME+=("$name"); U_PATH+=("$envpath")
    U_COMPOSE+=("$found"); U_PROJNAME+=("$pname"); U_SVCSTR+=("$svcs")
  done
  shopt -u nullglob
}

declare -a R_TYPE R_UNIT R_SVC
build_rows(){
  R_TYPE=(); R_UNIT=(); R_SVC=()
  local i svc
  for i in "${!U_NAME[@]}"; do
    (( i > 0 )) && { R_TYPE+=("gap"); R_UNIT+=("$i"); R_SVC+=(""); }
    R_TYPE+=("proj"); R_UNIT+=("$i"); R_SVC+=("")
    while IFS= read -r svc; do
      [[ -n $svc ]] || continue
      R_TYPE+=("svc"); R_UNIT+=("$i"); R_SVC+=("$svc")
    done <<< "${U_SVCSTR[i]}"
  done
}

# =============================================================================
#  SNAPSHOT -> MAPPE
# =============================================================================
declare -A M_STATUS M_STATE M_SIZE M_NAME M_SVC M_WD
declare -A M_CPU M_MEM M_MEMP M_NET M_BLK
load_snapshots(){
  M_STATUS=(); M_STATE=(); M_SIZE=(); M_NAME=(); M_SVC=(); M_WD=()
  M_CPU=(); M_MEM=(); M_MEMP=(); M_NET=(); M_BLK=()
  DOCKER_OK=$(<"$OK_FILE")
  local id p s w st nm
  while IFS=$'\t' read -r id p s w st nm; do
    [[ -n $nm ]] || continue
    case "$st" in
      Up*Paused*)   M_STATE[$nm]=paused;;
      Up*)          M_STATE[$nm]=running;;
      Exited*)      M_STATE[$nm]=exited;;
      Created*)     M_STATE[$nm]=created;;
      Restarting*)  M_STATE[$nm]=restarting;;
      Dead*)        M_STATE[$nm]=dead;;
      *)            M_STATE[$nm]=unknown;;
    esac
    M_STATUS[$nm]="$st"; M_SVC[$nm]="$s"; M_WD[$nm]="$w"
    [[ -n $w && -n $s ]] && M_NAME["$w"$'\x1f'"$s"]="$nm"
  done < "$PS_FILE"
  local sz
  while IFS=$'\t' read -r nm sz; do [[ -n $nm ]] && M_SIZE[$nm]="$sz"; done < "$SIZE_FILE"
  local cpu mem memp net blk
  while IFS=$'\t' read -r nm cpu mem memp net blk; do
    [[ -n $nm ]] || continue
    M_CPU[$nm]="$cpu"; M_MEM[$nm]="$mem"; M_MEMP[$nm]="$memp"
    M_NET[$nm]="$net"; M_BLK[$nm]="$blk"
  done < "$STATS_FILE"
}

# =============================================================================
#  UTILITY DI RENDERING
# =============================================================================
pad_v(){  local s="$2" w="$3"; (( ${#s} > w )) && s="${s:0:w-1}…"; printf -v "$1" '%-*s' "$w" "$s"; }
padr_v(){ local s="$2" w="$3"; (( ${#s} > w )) && s="${s:0:w-1}…"; printf -v "$1" '%*s' "$w" "$s"; }

BADGE_OUT=""
badge_v(){
  local glyph label col
  case "$1" in
    running)    glyph="●"; label="attivo";  col=$C_OK;;
    exited)     glyph="○"; label="spento";  col=$C_ERR;;
    paused)     glyph="‖"; label="pausa";   col=$C_WARN;;
    created)    glyph="◌"; label="creato";  col=$C_WARN;;
    restarting) glyph="↻"; label="riavvio"; col=$C_WARN;;
    dead)       glyph="✝"; label="morto";   col=$C_ERR;;
    none)       glyph="·"; label="assente"; col=$C_GREY;;
    *)          glyph="?"; label="ignoto";  col=$C_GREY;;
  esac
  printf -v BADGE_OUT '%s%s %-8s%s' "$col" "$glyph" "$label" "$C_RESET"
}

BAR_OUT=""
bar_v(){ # bar_v pct [width] [colore]
  local pct=$1 w=${2:-16} col=${3:-} fill i s=""
  (( pct<0 )) && pct=0; (( pct>100 )) && pct=100
  if [[ -z $col ]]; then
    col=$C_AZ; (( pct>=70 )) && col=$C_WARN; (( pct>=90 )) && col=$C_ERR
  fi
  fill=$(( pct*w/100 ))
  for ((i=0;i<w;i++)); do if ((i<fill)); then s+="█"; else s+="░"; fi; done
  printf -v BAR_OUT '%s%s%s' "$col" "$s" "$C_RESET"
}

HB_OUT=""
hb_v(){ # bytes -> umano
  local b=$1
  if command -v numfmt >/dev/null 2>&1; then
    HB_OUT=$(numfmt --to=iec --suffix=B "$b" 2>/dev/null) || HB_OUT="${b}B"
  else
    HB_OUT=$(awk -v b="$b" 'BEGIN{s="B K M G T";split(s,u," ");i=1;while(b>=1024&&i<5){b/=1024;i++}printf "%.1f%sB",b,(i>1?u[i]:"")}')
  fi
}

to_bytes(){ # "128MB" "1.5GB" -> byte (stdout)
  awk -v s="$1" 'BEGIN{
    n=s; gsub(/[^0-9.]/,"",n); u=toupper(s); m=1
    if (u ~ /KB/) m=1024; else if (u ~ /MB/) m=1048576
    else if (u ~ /GB/) m=1073741824; else if (u ~ /TB/) m=1099511627776
    printf "%.0f", n*m }'
}

PANEL_OUT=""
panel_v(){ # panel_v "TITOLO" larghezza -> ┌─ TITOLO ────
  local t=" $1 " w=$2 head rem fill
  head="┌─${t}"
  rem=$(( w - ${#head} )); (( rem < 0 )) && rem=0
  printf -v fill '%*s' "$rem" ''; fill=${fill// /─}
  printf -v PANEL_OUT '%s%s%s%s%s' "$C_AZ2" "┌─" "$C_RESET$C_BOLD$t$C_RESET$C_AZ2" "$fill" "$C_RESET"
}
panel_ct(){ panel_v "$1" "$CW"; CT+=("$PANEL_OUT"); }

dashline(){ local w=$1 s; printf -v s '%*s' "$w" ''; printf '%s' "${s// /─}"; }

rowjoin(){ # $1 var  $2 leftC $3 leftLen  $4 rightC $5 rightLen  $6 width
  local gap=$(( $6 - $3 - $5 )); (( gap < 1 )) && gap=1
  local sp; printf -v sp '%*s' "$gap" ''
  printf -v "$1" '%s%s%s' "$2" "$sp" "$4"
}

# ---- messaggi (barra in basso) ----------------------------------------------
MSG=""; MSG_KIND=""
notify_ok(){   MSG="✔ $1"; MSG_KIND=ok; }
notify_warn(){ MSG="⚠ $1"; MSG_KIND=warn; }
notify_err(){  MSG="✘ $1"; MSG_KIND=err; }
notify_info(){ MSG="◆ $1"; MSG_KIND=info; }
notify_clear(){ MSG=""; MSG_KIND=""; }

HINT=""

# =============================================================================
#  OVERLAY  (dettagli servizio a schermo intero)
# =============================================================================
overlay(){
  local title="$1" body="$2"
  printf '\e[H\e[2J'
  printf '%s %s %s\n\n' "$C_AZBG$C_BOLD" "$title" "$C_RESET"
  printf '%s\n' "$body"
  printf '\n%s[ Esc torna indietro · q esce ]%s' "$C_DIM" "$C_RESET"
  while :; do
    read_key
    case "$KEY" in
      ESC) break;;
      q|Q) exit 0;;
      *) :;;
    esac
  done
  tput civis 2>/dev/null
  DIMS_DIRTY=1
}

# =============================================================================
#  AZIONI
# =============================================================================
confirm(){
  printf '\e[?1000l\e[?1002l\e[?1006l'   # mouse OFF: evita che eventi sporchino la risposta
  printf '\e[%d;1H\e[2K%s%s%s [s/N] ' "$LINES_G" "$C_WARN$C_BOLD" "⚠ $1" "$C_RESET"
  local a; IFS= read -rsn1 a
  printf '\e[?1000h\e[?1002h\e[?1006h'
  [[ $a == s || $a == S || $a == y || $a == Y ]]
}
report_action(){
  local label="$1" rc="$2" out="$3"
  if (( rc == 0 )); then notify_ok "$label completato"
  elif [[ $out == *containerd-shim* || $out == *"failed to start shim"* ]]; then
    notify_err "$label: shim containerd mancante — controlla il demone docker"
  else notify_err "$label: ${out##*$'\n'}"; fi
}
action_svc(){
  local unit="$1" svc="$2" act="$3"
  local path="${U_PATH[unit]}" cf="${U_COMPOSE[unit]}" proj="${U_PROJNAME[unit]}"
  local name="${M_NAME["$path"$'\x1f'"$svc"]}"
  local out rc
  case "$act" in
    start)
      if [[ -n $name ]]; then out=$(docker start "$name" 2>&1); rc=$?
      else out=$( ( cd "$path" && "${DC[@]}" -p "$proj" -f "$cf" up -d "$svc" ) 2>&1); rc=$?; fi;;
    stop)
      if [[ -n $name ]]; then out=$(docker stop "$name" 2>&1); rc=$?
      else notify_warn "$svc: nessun container da fermare"; return; fi;;
    restart)
      if [[ -n $name ]]; then out=$(docker restart "$name" 2>&1); rc=$?
      else out=$( ( cd "$path" && "${DC[@]}" -p "$proj" -f "$cf" up -d "$svc" ) 2>&1); rc=$?; fi;;
  esac
  report_action "$svc: $act" "$rc" "$out"
}
action_env(){
  local unit="$1" act="$2"
  local path="${U_PATH[unit]}" cf="${U_COMPOSE[unit]}" proj="${U_PROJNAME[unit]}"
  local label="${U_NAME[unit]}"
  local out rc
  case "$act" in
    start)   out=$( ( cd "$path" && "${DC[@]}" -p "$proj" -f "$cf" up -d )    2>&1); rc=$?;;
    stop)    out=$( ( cd "$path" && "${DC[@]}" -p "$proj" -f "$cf" stop )     2>&1); rc=$?;;
    restart) out=$( ( cd "$path" && "${DC[@]}" -p "$proj" -f "$cf" restart )  2>&1); rc=$?;;
  esac
  report_action "$label: $act" "$rc" "$out"
}
act_on_sel(){
  local act="$1"
  (( ${#R_TYPE[@]} == 0 )) && return
  local t="${R_TYPE[SEL]}" u="${R_UNIT[SEL]}" svc="${R_SVC[SEL]}"
  case "$t" in
    proj)
      if [[ $act == stop || $act == restart ]]; then
        confirm "$act di TUTTI i servizi di ${U_NAME[u]}?" || { notify_warn "annullato"; return; }
      fi
      notify_info "$act ${U_NAME[u]} in corso..."; render_frame; action_env "$u" "$act";;
    svc)
      notify_info "$act $svc in corso..."; render_frame; action_svc "$u" "$svc" "$act";;
  esac
}
logs_on_sel(){
  (( ${#R_TYPE[@]} == 0 )) && return
  local t="${R_TYPE[SEL]}" u="${R_UNIT[SEL]}" svc="${R_SVC[SEL]}"
  if [[ $t == svc ]]; then
    local name="${M_NAME["${U_PATH[u]}"$'\x1f'"$svc"]}"
    [[ -z $name ]] && { notify_warn "servizio non creato: nessun log"; return; }
    docker logs --tail 500 "$name" 2>&1 | less -R +G
  else
    ( cd "${U_PATH[u]}" && "${DC[@]}" -p "${U_PROJNAME[u]}" -f "${U_COMPOSE[u]}" logs --tail 300 ) 2>&1 | less -R
  fi
  tput civis 2>/dev/null; DIMS_DIRTY=1
}
details_on_sel(){
  (( ${#R_TYPE[@]} == 0 )) && return
  local t="${R_TYPE[SEL]}" u="${R_UNIT[SEL]}" svc="${R_SVC[SEL]}"
  if [[ $t == svc ]]; then
    local name="${M_NAME["${U_PATH[u]}"$'\x1f'"$svc"]}"
    [[ -z $name ]] && { notify_warn "servizio non creato: nessun dettaglio"; return; }
    local info live=""
    info=$(docker inspect "$name" --format \
'Container   : {{.Name}}   ({{printf "%.12s" .Id}})
Immagine    : {{.Config.Image}}
Compose     : progetto {{index .Config.Labels "com.docker.compose.project"}} · servizio {{index .Config.Labels "com.docker.compose.service"}}
Creato      : {{.Created}}
Avviato     : {{.State.StartedAt}}
Stato       : {{.State.Status}}   exit code: {{.State.ExitCode}}   Health: {{if .State.Health}}{{.State.Health.Status}}{{else}}n/d{{end}}
Riavvii     : {{.RestartCount}}   restart policy: {{.HostConfig.RestartPolicy.Name}}
Reti / IP   : {{range $k,$v := .NetworkSettings.Networks}}{{$k}}={{$v.IPAddress}} {{end}}
Porte       : {{range $p,$v := .NetworkSettings.Ports}}{{$p}}{{if $v}}→{{(index $v 0).HostPort}}{{end}} {{end}}
Volumi      : {{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}→{{.Destination}} {{end}}{{end}}
Bind mount  : {{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}→{{.Destination}} {{end}}{{end}}' 2>&1)
    live="Risorse live: CPU ${M_CPU[$name]:-–}   RAM ${M_MEM[$name]:-–} (${M_MEMP[$name]:-–})
Rete I/O    : ${M_NET[$name]:-–}
Disco I/O   : ${M_BLK[$name]:-–}
Layer disco : ${M_SIZE[$name]:-–}"
    overlay "Dettagli servizio: $svc" "$info"$'\n'"$live"
  else
    local out
    out=$( ( cd "${U_PATH[u]}" && "${DC[@]}" -p "${U_PROJNAME[u]}" -f "${U_COMPOSE[u]}" ps -a ) 2>&1 )
    overlay "Progetto ${U_NAME[u]}  (compose ps)" "compose file : ${U_COMPOSE[u]}
percorso     : ${U_PATH[u]}
nome compose : ${U_PROJNAME[u]}

$out"
  fi
}

# =============================================================================
#  MENU / SIDEBAR
# =============================================================================
MENU_KEY=(services filesystem images registry settings help)
MENU_LABEL=("SERVIZI" "FILESYSTEM" "IMMAGINI" "REGISTRY" "IMPOSTAZIONI" "AIUTO")
MSEL=0
FOCUS=content   # menu | content

active_key(){ case "$MODE" in browse) echo filesystem;; regbrowse) echo images;; *) echo "$MODE";; esac; }

sb_line(){ # $1 index $2 plaintext $3 color
  local t; pad_v t "$2" "$IW"
  SB[$1]=" ${3}${t}${C_RESET}"
}
declare -a SB
build_sidebar(){
  local active; active="$(active_key)"
  local idx dash t
  SB=()
  sb_line 0 "$BRAND" "$C_AZ$C_BOLD"
  sb_line 1 "server manager" "$C_DIM"
  dash="$(dashline "$IW")"
  SB[2]=" ${C_GREY}${dash}${C_RESET}"
  for idx in "${!MENU_KEY[@]}"; do
    local rowi=$((5+idx)) key="${MENU_KEY[idx]}" label="${MENU_LABEL[idx]}"
    local isact=0 isfoc=0
    [[ $key == "$active" ]] && isact=1
    [[ $FOCUS == menu && $idx -eq $MSEL ]] && isfoc=1
    pad_v t "$label" "$IW"
    if (( isfoc )); then
      SB[$rowi]="${C_AZBG}${C_BOLD}▌${t}${C_RESET}"
    elif (( isact )); then
      SB[$rowi]="${C_AZ}▌${C_BOLD}${t}${C_RESET}"
    else
      sb_line "$rowi" "$label" "$C_GREY"
    fi
  done
  # piede: host + stato online
  SB[$((LINES_G-4))]=" ${C_GREY}${dash}${C_RESET}"
  sb_line $((LINES_G-3)) "$HOST_G" "$C_DIM"
  local col plain
  if (( DOCKER_OK )); then col=$C_OK; plain="● online"; else col=$C_ERR; plain="● offline"; fi
  pad_v t "$plain" "$IW"
  SB[$((LINES_G-2))]=" ${col}${t}${C_RESET}"
}

# ---- header contenuto (breadcrumb + chip) -----------------------------------
header_ct(){ # $1 sezione (label)
  local sec="$1" row
  local bc_plain="ROOT / DEPLOY / ${sec}"
  local leftc=" ${C_DIM}ROOT${C_RESET} ${C_GREY}/${C_RESET} ${C_DIM}DEPLOY${C_RESET} ${C_GREY}/${C_RESET} ${C_AZ}${C_BOLD}${sec}${C_RESET}"
  local leftlen=$(( 1 + ${#bc_plain} ))
  local now; printf -v now '%(%H:%M:%S)T' -1
  local dchip dlen
  if (( DOCKER_OK )); then dchip="${C_OK}❰ DOCKER OK ❱${C_RESET}"; dlen=13
  else dchip="${C_ERR}❰ DOCKER ERR ❱${C_RESET}"; dlen=14; fi
  local tchip="${C_DIM}❰ ${now} ❱${C_RESET}"; local tlen=12
  local rightc="${dchip} ${tchip}" rightlen=$(( dlen + 1 + tlen ))
  rowjoin row "$leftc" "$leftlen" "$rightc" "$rightlen" "$CW"
  CT+=("$row")
  CT+=("${C_GREY}$(dashline "$CW")${C_RESET}")
}

# =============================================================================
#  COMPOSITOR
# =============================================================================
declare -a CT
compose_paint(){
  local buf="" i
  for ((i=0;i<LINES_G;i++)); do
    buf+="${SB[i]:-$SB_BLANK}${DIV_STR}${CT[i]:-}"$'\e[K'
    (( i < LINES_G-1 )) && buf+=$'\n'
  done
  printf '\e[H%s' "$buf"
}
paint_status(){
  local row=$LINES_G bg txt pad
  if [[ -n $MSG ]]; then
    case "$MSG_KIND" in
      err)  bg=$C_ERRBG;; warn) bg=$C_WARNBG;; ok) bg=$C_OKBG;; *) bg=$C_INFOBG;;
    esac
    printf -v pad '%-*s' "$COLS_G" " $MSG"
    (( ${#pad} > COLS_G )) && pad="${pad:0:COLS_G}"
    printf '\e[%d;1H\e[K%s%s%s%s' "$row" "$bg" "$C_BOLD" "$pad" "$C_RESET"
  else
    printf '\e[%d;1H\e[K %s%s%s' "$row" "$C_DIM" "$HINT" "$C_RESET"
  fi
}

render_frame(){
  update_dims
  build_sidebar
  CT=()
  case "$MODE" in
    services)   build_services;;
    filesystem) build_filesystem;;
    images)     build_images;;
    regbrowse)  build_regbrowse;;
    browse)     build_browse;;
    registry)   build_registry;;
    settings)   build_settings;;
    help)       build_help;;
    *)          build_services;;
  esac
  compose_paint
  paint_status
  # feedback grab: mostra il cursore che segue il mouse mentre ridimensiono
  if (( RZ_ACTIVE )); then
    printf '\e[%d;%dH' "$MOUSE_Y" "$MOUSE_X"; tput cnorm 2>/dev/null
  else
    tput civis 2>/dev/null
  fi
}
render_main(){ render_frame; }

# =============================================================================
#  VISTA SERVIZI (dashboard)
# =============================================================================
SEL=0; TOP=0; LAST_AVAIL=10
build_services(){
  local cols=$CW
  local show_size=1; (( cols < 96 )) && show_size=0

  header_ct "SERVIZI"

  local n=${#R_TYPE[@]}
  local run=0 tot=0 i nm
  for ((i=0;i<n;i++)); do
    [[ ${R_TYPE[i]} == svc ]] || continue
    ((tot++))
    nm="${M_NAME["${U_PATH[${R_UNIT[i]}]}"$'\x1f'"${R_SVC[i]}"]}"
    [[ -n $nm ]] && [[ ${M_STATE[$nm]} == running ]] && ((run++))
  done
  local runcol=$C_OK
  (( run == 0 && tot > 0 )) && runcol=$C_ERR
  (( run > 0 && run < tot ))  && runcol=$C_WARN
  local runpct=0; (( tot > 0 )) && runpct=$(( run*100/tot ))
  bar_v "$runpct" 12 "$runcol"
  local sm
  printf -v sm ' %sprogetti%s %s%d%s    %sattivi%s %s%d/%d%s %s' \
    "$C_DIM" "$C_RESET" "$C_AZ$C_BOLD" "${#U_NAME[@]}" "$C_RESET" \
    "$C_DIM" "$C_RESET" "$runcol$C_BOLD" "$run" "$tot" "$C_RESET" "$BAR_OUT"
  CT+=("$sm")
  CT+=("")

  panel_ct "STACKS"

  if (( n == 0 )); then
    if [[ ! -d $APPS_DIR ]]; then
      CT+=("  ${C_ERR}✘ La cartella non esiste: ${APPS_DIR}${C_RESET}")
    else
      CT+=("  ${C_WARN}⚠ Nessuno stack trovato in ${APPS_DIR}${C_RESET}")
    fi
    CT+=("  ${C_DIM}Atteso: <apps>/<progetto>/docker-compose.yml${C_RESET}")
    CT+=("  ${C_DIM}Apri IMPOSTAZIONI per cambiare percorso, poi 'p' per riprovare.${C_RESET}")
    HINT="${C_AZ}Tab${C_RESET}${C_DIM} menu  ${C_AZ}p${C_RESET}${C_DIM} refresh  ${C_AZ}?${C_RESET}${C_DIM} aiuto  ${C_AZ}q${C_RESET}${C_DIM} esci${C_RESET}"
    return
  fi

  local statow=10 cpuw=6 infow ramw discow=12
  infow=$(col_eff info 20); CUR_COLW[info]=$infow
  ramw=$(col_eff ram 14); CUR_COLW[ram]=$ramw
  (( show_size )) && { discow=$(col_eff disco 12); CUR_COLW[disco]=$discow; }
  local fixed=$(( statow + infow + cpuw + ramw )) ncols=5
  (( show_size )) && { fixed=$(( fixed + discow )); ncols=6; }
  local namew=$(( cols - fixed - 4 - (ncols-1) )); (( namew < 10 )) && namew=10
  CUR_COLW[servizio]=$namew
  # bordi ridimensionabili (INFO, RAM, DISCO)
  sep_reset; local _off=4
  _off=$((_off+namew+1)); _off=$((_off+statow+1))
  _off=$((_off+infow)); sep_add "$_off" info; _off=$((_off+1))
  _off=$((_off+cpuw+1))
  _off=$((_off+ramw)); sep_add "$_off" ram
  (( show_size )) && { _off=$((_off+1+discow)); sep_add "$_off" disco; }

  local h1 h2 h3 h4 h5 h6
  pad_v h1 'SERVIZIO' "$namew"; pad_v h2 'STATO' "$statow"; pad_v h3 'INFO' "$infow"
  padr_v h4 'CPU%' "$cpuw"; pad_v h5 'RAM' "$ramw"
  local hdr="    $h1 $h2 $h3 $h4 $h5"
  (( show_size )) && { pad_v h6 'DISCO' "$discow"; hdr+=" $h6"; }
  CT+=("${C_AZ2}${hdr}${C_RESET}")

  # paginazione
  local avail=$(( (LINES_G-1) - ${#CT[@]} )); (( avail < 3 )) && avail=3
  LAST_AVAIL=$avail
  (( SEL >= n )) && SEL=0
  (( SEL < TOP )) && TOP=$SEL
  (( SEL >= TOP+avail )) && TOP=$(( SEL-avail+1 ))
  (( TOP < 0 )) && TOP=0

  local end=$((TOP+avail)); (( end > n )) && end=$n
  for ((i=TOP;i<end;i++)); do
    local t=${R_TYPE[i]} u=${R_UNIT[i]}
    case $t in
      gap) CT+=("") ;;
      proj)
        local er=0 et=0 svc pnm
        while IFS= read -r svc; do
          [[ -n $svc ]] || continue; ((et++))
          pnm="${M_NAME["${U_PATH[u]}"$'\x1f'"$svc"]}"
          [[ -n $pnm ]] && [[ ${M_STATE[$pnm]} == running ]] && ((er++))
        done <<< "${U_SVCSTR[u]}"
        local dcol=$C_GREY dot="○"
        if (( et > 0 && er == et )); then dcol=$C_OK; dot="●"
        elif (( er > 0 )); then dcol=$C_WARN; dot="◐"
        elif (( et > 0 )); then dcol=$C_ERR; dot="○"; fi
        local bar=' ' sel="$C_BOLD"
        if (( i==SEL )); then bar="${C_AZ}▌${C_RESET}"; sel="$C_AZBG$C_BOLD"; fi
        CT+=("$bar${dcol} ${dot} ▸ ${C_RESET}${sel} ${U_NAME[u]} ${C_RESET} ${C_DIM}${er}/${et} attivi · ${U_COMPOSE[u]}${C_RESET}")
        ;;
      svc)
        local svc=${R_SVC[i]} path=${U_PATH[u]}
        local name="${M_NAME["$path"$'\x1f'"$svc"]}"
        local st status cpu mem size
        if [[ -n $name ]]; then
          st=${M_STATE[$name]:-none}
          status=${M_STATUS[$name]:-non creato}
          cpu=${M_CPU[$name]:-–}
          mem=${M_MEM[$name]:-} size=${M_SIZE[$name]:-}
        else
          st=none; status="non creato"; cpu="–"; mem=""; size=""
        fi
        local memshort=${mem%% / *}; [[ -z $memshort ]] && memshort='–'
        local sizeshort=${size%% (*}; [[ -z $sizeshort ]] && sizeshort='–'
        local bar=' ' nmc="$C_RESET"
        if (( i==SEL )); then bar="${C_AZ}▌${C_RESET}"; nmc="$C_BOLD$C_AZ"; fi
        local f_name f_st f_cpu f_mem f_sz
        pad_v  f_name "$svc" "$namew"
        badge_v "$st"
        pad_v  f_st  "$status" "$infow"
        padr_v f_cpu "$cpu" "$cpuw"
        pad_v  f_mem "$memshort" "$ramw"
        local line="$bar   ${nmc}${f_name}${C_RESET} ${BADGE_OUT} ${C_GREY}${f_st}${C_RESET} ${C_AZ2}${f_cpu}${C_RESET} ${f_mem}"
        if (( show_size )); then pad_v f_sz "$sizeshort" "$discow"; line+=" ${C_DIM}${f_sz}${C_RESET}"; fi
        CT+=("$line")
        ;;
    esac
  done
  HINT=" ${C_AZ}↑↓${C_RESET}${C_DIM} nav ${C_RESET}${C_AZ}↵${C_RESET}${C_DIM} dettagli ${C_RESET}${C_OK}s${C_RESET}${C_DIM} avvia ${C_RESET}${C_ERR}x${C_RESET}${C_DIM} ferma ${C_RESET}${C_WARN}r${C_RESET}${C_DIM} riavvia ${C_RESET}${C_AZ}l${C_RESET}${C_DIM} log ${C_RESET}${C_AZ}p${C_RESET}${C_DIM} refresh ${C_RESET}${C_AZ}Tab${C_RESET}${C_DIM} menu ${C_RESET}${C_AZ}q${C_RESET}${C_DIM} esci${C_RESET}"
}

move_sel(){
  local dir=$1 n=${#R_TYPE[@]} i=$SEL
  while :; do
    i=$((i+dir))
    (( i<0 || i>=n )) && return
    [[ ${R_TYPE[i]} != gap ]] && { SEL=$i; return; }
  done
}
move_page(){ local dir=$1 c; for ((c=0;c<LAST_AVAIL;c++)); do move_sel "$dir"; done; }

do_refresh(){
  notify_info "refresh in corso..."
  render_frame
  fetch_snapshot; fetch_sizes; discover; build_rows
  SEL=0; TOP=0; FS_LOADED=0
  DOCKER_OK=$(<"$OK_FILE")
  if (( DOCKER_OK )); then notify_ok "refresh completato (${#U_NAME[@]} progetti)"
  else notify_err "docker non raggiungibile — verifica il demone"; fi
}

handle_services(){
  case "$1" in
    UP|k)    move_sel -1;;
    DOWN|j)  move_sel 1;;
    PGUP)    move_page -1;;
    PGDN)    move_page 1;;
    LEFT)    FOCUS=menu;;
    ESC)     if [[ -n $MSG ]]; then notify_clear; else FOCUS=menu; fi;;
    g|G)     notify_clear;;
    R)       col_reset_view;;
    p|P)     do_refresh;;
    s)       act_on_sel start;;
    x|X)     act_on_sel stop;;
    r)       act_on_sel restart;;
    l|L)     logs_on_sel;;
    '?')     activate help;;
    ENTER)   details_on_sel;;
    *)       :;;
  esac
}

# =============================================================================
#  VISTA FILESYSTEM  (quote dei mount in /data/<stack> + occupazione cartelle)
# =============================================================================
# Modello quote: ext4 project quota. Fonte di verità = $QUOTA_CONF
#   riga: <projid> <kib> <mountpoint> <dirpath>   (kib = blocchi da 1 KiB)
# Uso/limiti live: repquota -P <mnt> (root).  Attiva?: quotaon -pP <mnt>.
# Project id di una cartella: lsattr -p -d <dir> (prima colonna, 0 = nessuno).
declare -a FS_NAME FS_DIR FS_PROJ FS_USED FS_HARD FS_HASQ   # FS_USED/FS_HARD in KiB
FS_LOADED=0; FSSEL=0; FSTOP=0
MACH_TOT=0; MACH_USED=0; MACH_PCT=0; MACH_MNT="?"
QUOTA_ACTIVE=0
QUOTA_STATE=unknown   # on | off | unknown (non autenticato)
IS_ROOT=0
declare -A RQ_USED RQ_HARD

# Privilegi: se non root uso sudo (chiede la password DENTRO l'app).
#   PRIV   = comando privilegiato interattivo (dopo ensure_sudo)
#   PRIV_N = lettura privilegiata non interattiva (sudo -n; fallisce in silenzio)
#   CAN_EDIT = posso modificare le quote (root, oppure sudo disponibile)
PRIV=(); PRIV_N=(); CAN_EDIT=0
setup_priv(){
  IS_ROOT=0; [[ ${EUID:-$(id -u)} -eq 0 ]] && IS_ROOT=1
  if (( IS_ROOT )); then PRIV=(); PRIV_N=(); CAN_EDIT=1
  elif command -v sudo >/dev/null 2>&1; then PRIV=(sudo); PRIV_N=(sudo -n); CAN_EDIT=1
  else PRIV=(); PRIV_N=(); CAN_EDIT=0; fi
}
setup_priv
# chiede la password sudo (una volta, in modalità testo pulita) e la mette in cache
ensure_sudo(){
  (( IS_ROOT )) && return 0
  command -v sudo >/dev/null 2>&1 || { notify_err "sudo non disponibile: serve root"; return 1; }
  sudo -n true 2>/dev/null && return 0
  printf '\e[?1000l\e[?1002l\e[?1006l\e[?2004l'
  tput cnorm 2>/dev/null; stty sane 2>/dev/null
  printf '\e[H\e[2J%s Autenticazione sudo richiesta %s\n\n' "$C_AZBG$C_BOLD" "$C_RESET"
  sudo -v; local rc=$?
  stty -echo 2>/dev/null; tput civis 2>/dev/null
  printf '\e[?1000h\e[?1002h\e[?1006h'; DIMS_DIRTY=1
  (( rc == 0 )) || { notify_err "sudo: autenticazione fallita"; return 1; }
  return 0
}

hb_kib(){ hb_v $(( $1 * 1024 )); }   # KiB -> stringa umana in HB_OUT

to_kib_input(){ # "20G" "512M" "0" -> KiB (stdout).  numero senza suffisso = GiB
  awk -v s="$1" 'BEGIN{
    u=toupper(s); n=s; gsub(/[^0-9.]/,"",n)
    if (n=="") { print ""; exit }
    m=1048576
    if      (u ~ /K/) m=1
    else if (u ~ /M/) m=1024
    else if (u ~ /G/) m=1048576
    else if (u ~ /T/) m=1073741824
    printf "%.0f", n*m }'
}

load_filesystem(){
  FS_NAME=(); FS_DIR=(); FS_PROJ=(); FS_USED=(); FS_HARD=(); FS_HASQ=()
  RQ_USED=(); RQ_HARD=()
  setup_priv
  # filesystem che ospita il mount delle quote
  read -r MACH_TOT MACH_USED MACH_PCT MACH_MNT < <(df -PB1 -- "$QUOTA_MNT" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $2, $3, $5, $6}')
  [[ -z $MACH_TOT ]] && { MACH_TOT=0; MACH_USED=0; MACH_PCT=0; MACH_MNT="?"; }
  # quota attiva?  (lettura privilegiata non interattiva)
  local qo; qo=$("${PRIV_N[@]}" quotaon -pP "$QUOTA_MNT" 2>/dev/null)
  if [[ $qo == *"is on"* ]]; then QUOTA_ACTIVE=1; QUOTA_STATE=on
  elif [[ -n $qo ]]; then QUOTA_ACTIVE=0; QUOTA_STATE=off
  elif (( IS_ROOT )); then QUOTA_ACTIVE=0; QUOTA_STATE=off
  else QUOTA_ACTIVE=0; QUOTA_STATE=unknown; fi
  # uso/limiti per project id: repquota -> "#<proj> -- <used> <soft> <hard> ..."
  local proj used hard
  while read -r proj used hard; do
    [[ -n $proj ]] || continue
    RQ_USED[$proj]="$used"; RQ_HARD[$proj]="$hard"
  done < <("${PRIV_N[@]}" repquota -P "$QUOTA_MNT" 2>/dev/null | awk '/^#[0-9]+/{p=$1; sub(/^#/,"",p); print p, $3, $5}')

  local -A seen
  # 1) voci di quota.conf (fonte di verità) — leggo via sudo se non accessibile
  local confdata=""
  if [[ -r $QUOTA_CONF ]]; then confdata=$(cat "$QUOTA_CONF" 2>/dev/null)
  else confdata=$("${PRIV_N[@]}" cat "$QUOTA_CONF" 2>/dev/null); fi
  if [[ -n $confdata ]]; then
    local pid kib mnt dir u h
    while read -r pid kib mnt dir; do
      [[ $pid =~ ^[0-9]+$ && -n $dir ]] || continue
      [[ -n ${seen[$dir]:-} ]] && continue; seen[$dir]=1
      u="${RQ_USED[$pid]:-}"; [[ -z $u ]] && u=$("${PRIV_N[@]}" du -sk "$dir" 2>/dev/null | cut -f1)
      h="${RQ_HARD[$pid]:-}"; [[ -z $h || $h == 0 ]] && h="$kib"
      FS_NAME+=("${dir##*/}"); FS_DIR+=("$dir"); FS_PROJ+=("$pid")
      FS_USED+=("${u:-0}"); FS_HARD+=("${h:-0}"); FS_HASQ+=(1)
    done <<< "$confdata"
  fi
  # 2) sottocartelle di DATA_DIR non ancora elencate (con o senza project id)
  if [[ -d $DATA_DIR ]]; then
    shopt -s nullglob
    local p pj u h
    for p in "$DATA_DIR"/*/; do
      p="${p%/}"; [[ -d $p ]] || continue
      [[ -n ${seen[$p]:-} ]] && continue; seen[$p]=1
      pj=$(lsattr -p -d "$p" 2>/dev/null | awk '{print $1; exit}'); pj=${pj:-0}
      if [[ $pj =~ ^[0-9]+$ ]] && (( pj > 0 )); then
        u="${RQ_USED[$pj]:-}"; [[ -z $u ]] && u=$(du -sk -- "$p" 2>/dev/null | cut -f1)
        h="${RQ_HARD[$pj]:-0}"
        FS_NAME+=("${p##*/}"); FS_DIR+=("$p"); FS_PROJ+=("$pj")
        FS_USED+=("${u:-0}"); FS_HARD+=("${h:-0}"); FS_HASQ+=(1)
      else
        u=$(du -sk -- "$p" 2>/dev/null | cut -f1)
        FS_NAME+=("${p##*/}"); FS_DIR+=("$p"); FS_PROJ+=(0)
        FS_USED+=("${u:-0}"); FS_HARD+=(0); FS_HASQ+=(0)
      fi
    done
    shopt -u nullglob
  fi
  FS_LOADED=1; FSSEL=0; FSTOP=0
}
fs_ensure(){
  if (( ! FS_LOADED )); then
    # per leggere quote reali (repquota/quotaon/quota.conf) serve root:
    # se non sono root autentico sudo una volta (annullabile con Esc)
    (( IS_ROOT )) || ensure_sudo
    notify_info "leggo quote in ${QUOTA_MNT} ..."; render_fs_loading
    load_filesystem; notify_clear
  fi
}
render_fs_loading(){
  update_dims
  printf '\e[H\e[2J %s◆ leggo quote (repquota) e occupazione ...%s' "$C_AZ$C_BOLD" "$C_RESET"
}

# ---- gestione quote (root, quota attiva) ------------------------------------
dir_mnt(){ df -P "$1" 2>/dev/null | awk 'NR==2{print $NF}'; }   # mount reale della cartella
quotaconf_set(){ # proj kib dir mnt  (scrive via sudo se serve)
  local proj="$1" kib="$2" dir="$3" mnt="${4:-$QUOTA_MNT}" cur=""
  "${PRIV[@]}" mkdir -p "$(dirname "$QUOTA_CONF")" 2>/dev/null
  cur=$("${PRIV_N[@]}" cat "$QUOTA_CONF" 2>/dev/null)
  { [[ -n $cur ]] && printf '%s\n' "$cur" | awk -v p="$proj" '$1!=p'; printf '%s %s %s %s\n' "$proj" "$kib" "$mnt" "$dir"; } \
    | "${PRIV[@]}" tee "$QUOTA_CONF" >/dev/null 2>&1
}
quotaconf_del(){ # proj
  local proj="$1" cur
  cur=$("${PRIV_N[@]}" cat "$QUOTA_CONF" 2>/dev/null) || return
  [[ -n $cur ]] || return
  printf '%s\n' "$cur" | awk -v p="$proj" '$1!=p' | "${PRIV[@]}" tee "$QUOTA_CONF" >/dev/null 2>&1
}
quota_free_projid(){ # primo id libero >= 200
  local max=199 p id
  for p in "${FS_PROJ[@]}"; do [[ $p =~ ^[0-9]+$ ]] && (( p>max )) && max=$p; done
  for id in "${!RQ_USED[@]}"; do [[ $id =~ ^[0-9]+$ ]] && (( id>max )) && max=$id; done
  (( max<199 )) && max=199
  echo $(( max+1 ))
}
quota_set_path(){ # $1 dir  $2 kib (0 = rimuovi).  Funziona su QUALSIASI cartella.
  local dir="$1" kib="$2" name="${1##*/}" proj out rc qo mnt
  [[ -d $dir ]] || { notify_err "cartella inesistente: ${dir}"; return; }
  (( CAN_EDIT )) || { notify_err "gestione quote: serve root o sudo"; return; }
  ensure_sudo || return
  # mount REALE che contiene la cartella (non assumo '/': se /home e' un mount
  # separato la quota va messa su quel filesystem, altrimenti non ha effetto)
  mnt=$(dir_mnt "$dir"); [[ -z $mnt ]] && mnt="$QUOTA_MNT"
  qo=$("${PRIV[@]}" quotaon -pP "$mnt" 2>/dev/null)
  [[ $qo == *"is on"* ]] || { notify_err "project quota non attiva/enforcing su ${mnt} (serve reboot?)"; return; }
  # project id attuale della cartella (0 = nessuno)
  proj=$("${PRIV_N[@]}" lsattr -p -d "$dir" 2>/dev/null | awk '{print $1; exit}')
  [[ $proj =~ ^[0-9]+$ ]] || proj=0
  if (( kib == 0 )); then
    (( proj > 0 )) || { notify_warn "${name}: nessuna quota da rimuovere"; return; }
    out=$("${PRIV[@]}" setquota -P "$proj" 0 0 0 0 "$mnt" 2>&1); rc=$?
    if (( rc == 0 )); then
      "${PRIV[@]}" chattr -R -p 0 "$dir" 2>/dev/null
      quotaconf_del "$proj"
      notify_ok "quota rimossa da ${name}"
    else notify_err "rimozione quota: ${out##*$'\n'}"; fi
  else
    (( proj == 0 )) && proj=$(quota_free_projid)
    # SEMPRE: assegna il project id con ereditarietà.
    #   -R  tagga anche i file GIA' presenti (altrimenti non contano nella quota)
    #   +P  fa ereditare il progetto ai file NUOVI creati nella cartella
    out=$("${PRIV[@]}" chattr -R -p "$proj" +P "$dir" 2>&1); rc=$?
    (( rc != 0 )) && { notify_err "chattr: ${out##*$'\n'}"; return; }
    out=$("${PRIV[@]}" setquota -P "$proj" 0 "$kib" 0 0 "$mnt" 2>&1); rc=$?
    if (( rc != 0 )); then notify_err "setquota: ${out##*$'\n'}"; FS_LOADED=0; load_filesystem; return; fi
    quotaconf_set "$proj" "$kib" "$dir" "$mnt"
    # verifica che il limite hard risulti davvero registrato per il progetto
    local vh; vh=$("${PRIV_N[@]}" repquota -P "$mnt" 2>/dev/null | awk -v p="#$proj" '$1==p{print $5; exit}')
    hb_kib "$kib"
    if [[ -n $vh && $vh != 0 ]]; then
      notify_ok "quota ${HB_OUT} su ${name} (proj ${proj}, mnt ${mnt}) · root ignora le quote"
    else
      notify_warn "limite impostato (proj ${proj}) ma repquota non lo conferma su ${mnt}"
    fi
  fi
  FS_LOADED=0; load_filesystem
}
quota_apply(){ quota_set_path "${FS_DIR[$1]}" "$2"; }  # wrapper su riga selezionata

quota_diagnose(){ # mostra stato reale della quota per una cartella
  local dir="$1" mnt proj qo rq owner body
  (( IS_ROOT )) || ensure_sudo
  mnt=$(dir_mnt "$dir"); [[ -z $mnt ]] && mnt="$QUOTA_MNT"
  proj=$("${PRIV_N[@]}" lsattr -p -d "$dir" 2>/dev/null | awk '{print $1; exit}'); proj=${proj:-?}
  owner=$(stat -c '%U' "$dir" 2>/dev/null)
  qo=$("${PRIV[@]}" quotaon -pP "$mnt" 2>&1 | grep -v 'Cannot stat' | head -4)
  rq=$("${PRIV[@]}" repquota -P "$mnt" 2>/dev/null | grep -v 'Cannot stat' | awk 'NR<=3 || $1=="#'"$proj"'"' | head -12)
  body="Cartella    : ${dir}   (owner: ${owner:-?})
Mount reale : ${mnt}       ${C_DIM}(QUOTA_MNT impostato = ${QUOTA_MNT})${C_RESET}
Project id  : ${proj}   ${C_DIM}(0 = cartella non taggata → quota non conta i file)${C_RESET}

${C_AZ2}quotaon -pP ${mnt}${C_RESET}   ${C_DIM}(deve dire 'project quota ... is on')${C_RESET}
${qo:-<nessun output: quota non attiva o sudo mancante>}

${C_AZ2}repquota -P ${mnt}${C_RESET}   ${C_DIM}(colonne: used  soft  hard, in KiB)${C_RESET}
${rq:-<nessun dato>}

${C_WARN}Attenzione:${C_RESET} root e sudo IGNORANO le project quota (CAP_SYS_RESOURCE).
Per testare il blocco scrivi COME UTENTE normale, es:
  su - ${owner:-utente} -c 'dd if=/dev/zero of=${dir}/prova bs=1M count=9999'
Se 'used' in repquota NON cresce dopo lo scritto, i file non sono taggati
col project id (manca chattr -R +P) oppure sono su un altro mount."
  overlay "Diagnosi quota" "$body"
}

build_filesystem(){
  header_ct "FILESYSTEM"

  # pannello macchina
  panel_ct "MACCHINA · $MACH_MNT"
  bar_v "$MACH_PCT" 24
  hb_v "$MACH_USED"; local used_h=$HB_OUT
  hb_v "$MACH_TOT";  local tot_h=$HB_OUT
  CT+=("  ${BAR_OUT}  ${C_BOLD}${MACH_PCT}%${C_RESET} pieno ${C_DIM}· ${used_h} usati su ${tot_h}${C_RESET}")
  local qline
  case "$QUOTA_STATE" in
    on)  qline="  ${C_OK}● project quota attiva${C_RESET} ${C_DIM}su ${QUOTA_MNT}${C_RESET}";;
    off) qline="  ${C_WARN}● project quota NON attiva${C_RESET} ${C_DIM}(serve reboot)${C_RESET}";;
    *)   qline="  ${C_GREY}● stato quota sconosciuto${C_RESET} ${C_DIM}· premi 'a' per autenticarti${C_RESET}";;
  esac
  if (( ! IS_ROOT )); then
    if (( CAN_EDIT )); then qline+=" ${C_DIM}· modifiche via sudo${C_RESET}"
    else qline+=" ${C_DIM}· sola lettura (no root/sudo)${C_RESET}"; fi
  fi
  CT+=("$qline")
  CT+=("")

  panel_ct "QUOTE CARTELLE · ${#FS_NAME[@]}"
  # colonne responsive: CARTELLA (nome) flex, barra USO/QUOTA ridimensionabile
  local cols=$CW barw=22
  (( cols < 96 )) && barw=16
  (( cols < 80 )) && barw=10
  barw=$(col_eff bar "$barw"); CUR_COLW[bar]=$barw
  local namew=$(( cols - barw - 9 - 9 - 9 - 5 - 7 )); (( namew < 10 )) && namew=10
  sep_reset; local _off=2
  _off=$((_off+namew+1)); _off=$((_off+barw)); sep_add "$_off" bar
  local h1 h2 h3 h4 h5 h6
  pad_v h1 'CARTELLA' "$namew"; pad_v h2 'USO / QUOTA' "$barw"
  padr_v h3 'USATO' 9; padr_v h4 'QUOTA' 9; padr_v h5 'LIBERO' 9; padr_v h6 'PROJ' 5
  CT+=("  ${C_AZ2}${h1} ${h2} ${h3} ${h4} ${h5} ${h6}${C_RESET}")

  local n=${#FS_NAME[@]}
  if (( n == 0 )); then
    CT+=("  ${C_DIM}(nessuna quota in ${QUOTA_CONF} ne' cartelle in ${DATA_DIR})${C_RESET}")
    CT+=("  ${C_DIM}Premi ${C_RESET}${C_AZ}n${C_RESET}${C_DIM} per applicare una quota a una cartella qualsiasi.${C_RESET}")
    HINT=" ${C_AZ}n${C_RESET}${C_DIM} nuova quota ${C_RESET}${C_AZ}g${C_RESET}${C_DIM} rileggi ${C_RESET}${C_AZ}Tab${C_RESET}${C_DIM} menu ${C_RESET}${C_AZ}q${C_RESET}${C_DIM} esci${C_RESET}"
    return
  fi

  local avail=$(( (LINES_G-1) - ${#CT[@]} )); (( avail < 3 )) && avail=3
  LAST_AVAIL=$avail
  (( FSSEL >= n )) && FSSEL=$((n-1))
  (( FSSEL < FSTOP )) && FSTOP=$FSSEL
  (( FSSEL >= FSTOP+avail )) && FSTOP=$(( FSSEL-avail+1 ))
  (( FSTOP < 0 )) && FSTOP=0

  local i end=$((FSTOP+avail)); (( end > n )) && end=$n
  for ((i=FSTOP;i<end;i++)); do
    local bar=' ' nmcol="$C_RESET" pct=0
    (( i==FSSEL )) && { bar="${C_AZ}▌${C_RESET}"; nmcol="$C_BOLD$C_AZ"; }
    local nm us qt av pj u=${FS_USED[i]} h=${FS_HARD[i]}
    pad_v nm "${FS_NAME[i]}" "$namew"
    hb_kib "$u"; padr_v us "$HB_OUT" 9
    if (( FS_HASQ[i] )); then
      if (( h > 0 )); then
        pct=$(( u*100/h ))
        bar_v "$pct" "$barw"
        hb_kib "$h"; padr_v qt "$HB_OUT" 9
        local free=$(( h-u )); (( free<0 )) && free=0
        hb_kib "$free"; padr_v av "$HB_OUT" 9
      else
        bar_v 0 "$barw" "$C_AZ"; padr_v qt "∞" 9; padr_v av "∞" 9
      fi
      padr_v pj "${FS_PROJ[i]}" 5
      CT+=("$bar ${nmcol}${nm}${C_RESET} ${BAR_OUT} ${us} ${C_DIM}${qt}${C_RESET} ${C_OK}${av}${C_RESET} ${C_AZ2}${pj}${C_RESET}")
    else
      bar_v 0 "$barw" "$C_GREY"; padr_v qt "—" 9; padr_v av "—" 9; padr_v pj "-" 5
      CT+=("$bar ${nmcol}${nm}${C_RESET} ${BAR_OUT} ${us} ${C_DIM}${qt}${C_RESET} ${C_DIM}${av}${C_RESET} ${C_DIM}${pj}${C_RESET}")
    fi
  done
  HINT=" ${C_AZ}↵${C_RESET}${C_DIM} sfoglia ${C_RESET}${C_AZ}e${C_RESET}${C_DIM} quota ${C_RESET}${C_AZ}n${C_RESET}${C_DIM} nuova ${C_RESET}${C_AZ}i${C_RESET}${C_DIM} diagnosi ${C_RESET}${C_AZ}a${C_RESET}${C_DIM} autentica ${C_RESET}${C_AZ}g${C_RESET}${C_DIM} rileggi ${C_RESET}${C_AZ}Tab${C_RESET}${C_DIM} menu ${C_RESET}${C_AZ}q${C_RESET}${C_DIM} esci${C_RESET}"
}

# chiede limite e applica quota a una cartella (con conferma)
quota_prompt_apply(){ # $1 dir $2 default_limite
  local dir="$1" def="$2" kib
  if prompt_input "Limite per ${dir} (es 20G, 512M, 0=rimuovi):" "$def"; then
    kib=$(to_kib_input "$REPLY_VAL")
    if [[ -z $kib ]]; then notify_err "valore non valido"
    elif (( kib > 0 )); then
      if confirm "Imposto quota ${REPLY_VAL} su ${dir}?"; then quota_set_path "$dir" "$kib"; else notify_warn "annullato"; fi
    else
      if confirm "Rimuovo la quota da ${dir}?"; then quota_set_path "$dir" 0; else notify_warn "annullato"; fi
    fi
  else notify_warn "annullato"; fi
  DIMS_DIRTY=1
}

handle_filesystem(){
  case "$1" in
    UP|k)    (( FSSEL>0 )) && ((FSSEL--));;
    DOWN|j)  (( FSSEL<${#FS_NAME[@]}-1 )) && ((FSSEL++));;
    PGUP)    FSSEL=$(( FSSEL-LAST_AVAIL )); (( FSSEL<0 )) && FSSEL=0;;
    PGDN)    FSSEL=$(( FSSEL+LAST_AVAIL )); (( FSSEL>=${#FS_NAME[@]} )) && FSSEL=$(( ${#FS_NAME[@]}-1 ));;
    ENTER)   (( ${#FS_NAME[@]} > 0 )) && browse_open "${FS_DIR[FSSEL]}" filesystem "${FS_NAME[FSSEL]}";;
    e|E)
      (( ${#FS_NAME[@]} > 0 )) || return
      local curk="${FS_HARD[FSSEL]}" def=""
      if [[ ${FS_HASQ[FSSEL]} == 1 && $curk -gt 0 ]]; then
        def=$(awk -v k="$curk" 'BEGIN{printf (k%1048576==0 ? "%dG" : "%.1fG"), k/1048576}')
      fi
      quota_prompt_apply "${FS_DIR[FSSEL]}" "$def";;
    n|N)
      if prompt_input "Cartella a cui applicare la quota (percorso assoluto):" ""; then
        local ndir="${REPLY_VAL%/}"
        if [[ $ndir != /* ]]; then notify_err "serve un percorso assoluto"
        elif [[ ! -d $ndir ]]; then notify_err "cartella inesistente: ${ndir}"
        else quota_prompt_apply "$ndir" ""; fi
      else notify_warn "annullato"; fi
      DIMS_DIRTY=1;;
    a|A)
      if ensure_sudo; then
        notify_info "rileggo con privilegi..."; render_fs_loading
        load_filesystem; notify_ok "dati quota aggiornati"
      fi;;
    i|I)   (( ${#FS_NAME[@]} > 0 )) && quota_diagnose "${FS_DIR[FSSEL]}";;
    g|G)     notify_info "rileggo quote..."; render_fs_loading; load_filesystem; notify_clear;;
    R)       col_reset_view;;
    LEFT)    FOCUS=menu;;
    ESC)     if [[ -n $MSG ]]; then notify_clear; else FOCUS=menu; fi;;
    '?')     activate help;;
    *)       :;;
  esac
}

# =============================================================================
#  FILE BROWSER  (sotto-vista di filesystem; ↵ entra, Esc risale)
# =============================================================================
declare -a B_NAME B_BYTES B_ISDIR
declare -a BR_STACK
B_TOTAL=0; BSEL=0; BTOP=0; BR_FROM=filesystem; BR_LABEL=""

load_browse(){
  local dir="$1"
  B_NAME=(); B_BYTES=(); B_ISDIR=(); B_TOTAL=0
  local b p n
  while IFS=$'\t' read -r b p; do
    [[ -n $p && $p != "$dir" ]] || continue
    n="${p##*/}"
    B_NAME+=("$n"); B_BYTES+=("$b")
    if [[ -d $p && ! -L $p ]]; then B_ISDIR+=(1); else B_ISDIR+=(0); fi
    B_TOTAL=$(( B_TOTAL + b ))
  done < <(du -sb -- "$dir"/* "$dir"/.[!.]* "$dir"/..?* 2>/dev/null | sort -rn | head -500)
  BSEL=0; BTOP=0
}
browse_open(){ # $1 dir, $2 vista di provenienza, $3 etichetta
  BR_STACK=("$1"); BR_FROM="$2"; BR_LABEL="$3"
  notify_info "leggo ${1}..."; render_browse_loading "$1"
  load_browse "$1"; notify_clear
  MODE=browse
}
browse_enter(){
  (( ${#B_NAME[@]} == 0 )) && return
  (( B_ISDIR[BSEL] )) || { notify_warn "${B_NAME[BSEL]}: e' un file"; return; }
  local cur="${BR_STACK[${#BR_STACK[@]}-1]}"
  local next="$cur/${B_NAME[BSEL]}"
  [[ -r $next && -x $next ]] || { notify_warn "permessi insufficienti su ${B_NAME[BSEL]}"; return; }
  BR_STACK+=("$next")
  notify_info "leggo ${next}..."; render_browse_loading "$next"
  load_browse "$next"; notify_clear
}
browse_back(){
  if (( ${#BR_STACK[@]} > 1 )); then
    unset 'BR_STACK[${#BR_STACK[@]}-1]'
    local cur="${BR_STACK[${#BR_STACK[@]}-1]}"
    load_browse "$cur"
  else
    MODE="$BR_FROM"
  fi
}
render_browse_loading(){
  update_dims
  printf '\e[H\e[2J %s◆ calcolo dimensioni di %s ...%s' "$C_AZ$C_BOLD" "$1" "$C_RESET"
}
build_browse(){
  local cols=$CW
  header_ct "FILESYSTEM / ${BR_LABEL}"
  panel_ct "CONTENUTO · $BR_LABEL"
  local cur="${BR_STACK[${#BR_STACK[@]}-1]}"
  hb_v "$B_TOTAL"
  local pathw=$(( cols - 16 )); local pshort="$cur"
  (( ${#pshort} > pathw )) && pshort="…${pshort: -$((pathw-1))}"
  CT+=("  ${C_DIM}${pshort}${C_RESET}  ${C_AZ}${HB_OUT}${C_RESET}")

  local h1 h2 h3 h4
  pad_v h1 'NOME' 34; pad_v h2 'USO (rel. tot)' 20; padr_v h3 'DIM.' 10; padr_v h4 '%' 6
  CT+=("  ${C_AZ2}${h1} ${h2} ${h3} ${h4}${C_RESET}")

  local n=${#B_NAME[@]}
  if (( n == 0 )); then
    CT+=("  ${C_DIM}(cartella vuota o non leggibile)${C_RESET}")
    HINT="${C_AZ}Esc${C_RESET}${C_DIM} indietro  ${C_AZ}q${C_RESET}${C_DIM} esci${C_RESET}"
    return
  fi

  local avail=$(( (LINES_G-1) - ${#CT[@]} )); (( avail < 3 )) && avail=3
  LAST_AVAIL=$avail
  (( BSEL >= n )) && BSEL=$((n-1))
  (( BSEL < BTOP )) && BTOP=$BSEL
  (( BSEL >= BTOP+avail )) && BTOP=$(( BSEL-avail+1 ))
  (( BTOP < 0 )) && BTOP=0

  local i end=$((BTOP+avail)); (( end > n )) && end=$n
  for ((i=BTOP;i<end;i++)); do
    local bar=' ' nmcol="$C_RESET" pct=0 icon="·" iconcol=$C_GREY
    (( i==BSEL )) && { bar="${C_AZ}▌${C_RESET}"; nmcol="$C_BOLD$C_AZ"; }
    (( B_TOTAL > 0 )) && pct=$(( B_BYTES[i]*100/B_TOTAL ))
    (( B_ISDIR[i] )) && { icon="▸"; iconcol=$C_AZ2; }
    bar_v "$pct" 20
    hb_v "${B_BYTES[i]}"
    local nm sz sh
    pad_v nm "${B_NAME[i]}" 32; padr_v sz "$HB_OUT" 10; padr_v sh "${pct}%" 6
    CT+=("$bar ${iconcol}${icon}${C_RESET} ${nmcol}${nm}${C_RESET} ${BAR_OUT} ${sz} ${C_DIM}${sh}${C_RESET}")
  done
  HINT=" ${C_AZ}↵${C_RESET}${C_DIM} entra (▸ = cartella) ${C_RESET}${C_AZ}e${C_RESET}${C_DIM} quota qui ${C_RESET}${C_AZ}Esc${C_RESET}${C_DIM} su di un livello ${C_RESET}${C_AZ}q${C_RESET}${C_DIM} esci${C_RESET}"
}
handle_browse(){
  case "$1" in
    ESC)     browse_back;;
    UP|k)    (( BSEL>0 )) && ((BSEL--));;
    DOWN|j)  (( BSEL<${#B_NAME[@]}-1 )) && ((BSEL++));;
    PGUP)    BSEL=$(( BSEL-LAST_AVAIL )); (( BSEL<0 )) && BSEL=0;;
    PGDN)    BSEL=$(( BSEL+LAST_AVAIL )); (( BSEL>=${#B_NAME[@]} )) && BSEL=$(( ${#B_NAME[@]}-1 ));;
    ENTER)   browse_enter;;
    e|E)
      local cur="${BR_STACK[${#BR_STACK[@]}-1]}" tgt="$cur"
      if (( ${#B_NAME[@]} > 0 )) && (( B_ISDIR[BSEL] )); then tgt="$cur/${B_NAME[BSEL]}"; fi
      quota_prompt_apply "$tgt" "";;
    LEFT)    FOCUS=menu;;
    '?')     activate help;;
    *)       :;;
  esac
}

# =============================================================================
#  REGISTRY  (login/logout a registry esterni; robot account inclusi)
# =============================================================================
declare -a RG_HOST RG_USER RG_MINE
RG_LOADED=0; RGSEL=0; RGTOP=0

parse_docker_auths(){ # $1 config.json -> hostname per riga (best-effort, pretty-print)
  [[ -r $1 ]] || return 0
  awk '
    function keyof(line,   s){
      if (match(line, /"[^"]+"[[:space:]]*:[[:space:]]*\{/)) {
        s=substr(line,RSTART,RLENGTH); sub(/"[[:space:]]*:.*/,"",s); sub(/^"/,"",s); return s
      }
      return ""
    }
    {
      if (!inauth) {
        if ($0 ~ /"auths"[[:space:]]*:[[:space:]]*\{/) { inauth=1; depth=1 }
        next
      }
      if (depth==1) { k=keyof($0); if (k!="") print k }
      o=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth += o - c
      if (depth<=0) inauth=0
    }' "$1"
}

normalize_registry(){ # toglie schema http(s):// e '/' finale -> stessa chiave di docker
  local h="$1"
  h="${h#http://}"; h="${h#https://}"; h="${h%/}"
  printf '%s' "$h"
}
# confronto per host normalizzato (schema/‘/’ finale ignorati)
_reg_awk_filter='{k=$1; sub(/^https?:\/\//,"",k); sub(/\/+$/,"",k); if(k!=h) print}'
reg_store(){ # host(normalizzato) user
  local h; h=$(normalize_registry "$1")
  local u="$2" tmp
  mkdir -p "$(dirname "$REG_FILE")" 2>/dev/null
  tmp=$(mktemp) || return
  { [[ -f $REG_FILE ]] && awk -F'\t' -v h="$h" "$_reg_awk_filter" "$REG_FILE"; printf '%s\t%s\n' "$h" "$u"; } > "$tmp"
  mv "$tmp" "$REG_FILE" 2>/dev/null || rm -f "$tmp"
}
reg_forget(){ # host (qualsiasi forma)
  local h; h=$(normalize_registry "$1")
  local tmp
  [[ -f $REG_FILE ]] || return
  tmp=$(mktemp) || return
  awk -F'\t' -v h="$h" "$_reg_awk_filter" "$REG_FILE" > "$tmp"
  mv "$tmp" "$REG_FILE" 2>/dev/null || rm -f "$tmp"
}

reg_user_from_cfg(){ # cfg host -> username (stdout) decodificato da auth base64
  local enc up
  enc=$(extract_docker_auth "$1" "$2")
  [[ -n $enc ]] || return 0
  up=$(img_b64_decode "$enc")
  printf '%s' "${up%%:*}"
}
load_registry(){
  RG_HOST=(); RG_USER=(); RG_MINE=()
  local -A seen; local h u uu
  local cfg="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
  if [[ -r $REG_FILE ]]; then
    while IFS=$'\t' read -r h u; do
      [[ -n $h ]] || continue
      h=$(normalize_registry "$h")
      [[ -n ${seen[$h]:-} ]] && continue; seen[$h]=1
      [[ -z $u || $u == "—" ]] && u=$(reg_user_from_cfg "$cfg" "$h")
      RG_HOST+=("$h"); RG_USER+=("${u:-—}"); RG_MINE+=(1)
    done < "$REG_FILE"
  fi
  while read -r h; do
    [[ -n $h ]] || continue
    h=$(normalize_registry "$h")
    [[ -n ${seen[$h]:-} ]] && continue; seen[$h]=1
    uu=$(reg_user_from_cfg "$cfg" "$h")
    RG_HOST+=("$h"); RG_USER+=("${uu:-—}"); RG_MINE+=(0)
  done < <(parse_docker_auths "$cfg")
  RG_LOADED=1; RGSEL=0; RGTOP=0
}
reg_ensure(){ (( RG_LOADED )) || load_registry; }

# --- input testo robusto (raw): gestisce incolla e ESC = annulla ---------------
input_begin(){
  printf '\e[?1000l\e[?1002l\e[?1006l'          # mouse OFF durante l'input
  tput cnorm 2>/dev/null
}
input_end(){
  stty -echo 2>/dev/null; tput civis 2>/dev/null
  printf '\e[?2004l\e[?1000h\e[?1002h\e[?1006h' # bracketed-paste OFF, mouse ON
  DIMS_DIRTY=1
}
sanitize_input(){ # rimuove marker bracketed-paste, CR e newline residui
  local s="$1"
  s="${s//$'\e[200~'/}"; s="${s//$'\e[201~'/}"
  s="${s//$'\r'/}"; s="${s//$'\n'/}"
  printf '%s' "$s"
}
# read_line <silent> -> REPLY_LINE ; rc 1 = annullato con ESC.
# Legge in raw mode: Invio conferma, ESC (da solo) annulla, gestisce incolla
# (bracketed paste \e[200~ .. \e[201~), backspace e frecce (ignorate).
read_line(){
  local silent="${1:-0}" ch nx seq s2 buf="" pbuf pc t2 e
  REPLY_LINE=""
  stty -icanon -echo min 1 time 0 2>/dev/null
  printf '\e[?2004h'
  while IFS= read -rsn1 ch; do
    case "$ch" in
      $'\e')
        if IFS= read -rsn1 -t 0.03 nx; then
          if [[ $nx == '[' || $nx == 'O' ]]; then
            seq=""
            while IFS= read -rsn1 -t 0.05 s2; do seq+="$s2"; [[ $s2 == [A-Za-z~] ]] && break; done
            if [[ $seq == '200~' ]]; then         # incolla
              pbuf=""
              while IFS= read -rsn1 pc; do
                if [[ $pc == $'\e' ]]; then
                  IFS= read -rsn1 -t 0.05 t2
                  if [[ $t2 == '[' ]]; then
                    e=""; while IFS= read -rsn1 -t 0.05 s2; do e+="$s2"; [[ $s2 == [A-Za-z~] ]] && break; done
                    [[ $e == '201~' ]] && break
                  fi
                else pbuf+="$pc"; fi
              done
              pbuf="${pbuf//$'\r'/}"; pbuf="${pbuf//$'\n'/}"
              buf+="$pbuf"; (( silent )) || printf '%s' "$pbuf"
            fi
            # altre sequenze (frecce, home, ...) ignorate
          fi
          # ESC + altro carattere: ignora (non annulla, per sicurezza)
        else
          printf '\e[?2004l'; return 1            # ESC da solo = annulla
        fi ;;
      $'\n'|$'\r'|'') break ;;                     # Invio = conferma
      $'\x7f'|$'\x08')                             # backspace
        if [[ -n $buf ]]; then buf="${buf%?}"; (( silent )) || printf '\b \b'; fi ;;
      *) buf+="$ch"; (( silent )) || printf '%s' "$ch" ;;
    esac
  done
  printf '\e[?2004l'
  REPLY_LINE="$buf"; return 0
}
prompt_secret(){ # $1 label -> REPLY_SECRET (rc 1 = annulla/vuoto)
  input_begin
  printf '\e[%d;1H\e[2K%s%s%s' $((LINES_G-1)) "$C_AZ$C_BOLD" "$1" "$C_RESET"
  printf '\e[%d;1H\e[2K%s>%s ' "$LINES_G" "$C_AZ" "$C_RESET"
  read_line 1; local rc=$?; printf '\n'
  input_end
  (( rc != 0 )) && return 1
  local v; v=$(sanitize_input "$REPLY_LINE")
  [[ -z $v ]] && return 1
  REPLY_SECRET="$v"; return 0
}

reg_add(){
  local host user pw out rc
  if ! prompt_input "Registry host[:porta] (vuoto = annulla):" ""; then notify_warn "annullato"; DIMS_DIRTY=1; return; fi
  host=$(normalize_registry "$REPLY_VAL")
  if ! prompt_input "Utente (es. robot\$nome):" ""; then notify_warn "annullato"; DIMS_DIRTY=1; return; fi
  user="$REPLY_VAL"
  if ! prompt_secret "Password / token (nascosto):"; then notify_warn "annullato"; DIMS_DIRTY=1; return; fi
  pw="$REPLY_SECRET"
  notify_info "login a ${host} ..."; render_frame
  out=$(printf '%s' "$pw" | docker login "$host" -u "$user" --password-stdin 2>&1); rc=$?
  pw=""
  if (( rc == 0 )); then reg_store "$host" "$user"; notify_ok "login riuscito su ${host}"
  else notify_err "login fallito: ${out##*$'\n'}"; fi
  RG_LOADED=0; load_registry; DIMS_DIRTY=1
}
reg_remove(){
  (( ${#RG_HOST[@]} > 0 )) || return
  local h="${RG_HOST[RGSEL]}"
  confirm "Logout ed elimina credenziali di ${h}?" || { notify_warn "annullato"; return; }
  docker logout "$h" >/dev/null 2>&1
  reg_forget "$h"
  notify_ok "rimosso ${h}"
  RG_LOADED=0; load_registry
}

build_registry(){
  header_ct "REGISTRY"
  panel_ct "REGISTRY CONFIGURATI · ${#RG_HOST[@]}"
  CT+=("  ${C_DIM}login docker verso registry esterni (es. Harbor, robot account)${C_RESET}")
  CT+=("")
  # colonne responsive: REGISTRY (host) flex, UTENTE e ORIGINE ridimensionabili
  local cols=$CW userw=24 ogw=10
  (( cols < 96 )) && userw=18
  (( cols < 78 )) && { userw=14; ogw=8; }
  userw=$(col_eff user "$userw"); CUR_COLW[user]=$userw
  ogw=$(col_eff origine "$ogw"); CUR_COLW[origine]=$ogw
  local hostw=$(( cols - userw - ogw - 4 )); (( hostw < 12 )) && hostw=12
  CUR_COLW[host]=$hostw
  sep_reset; local _off=2
  _off=$((_off+hostw+1))
  _off=$((_off+userw)); sep_add "$_off" user; _off=$((_off+1))
  _off=$((_off+ogw));   sep_add "$_off" origine
  local h1 h2 h3
  pad_v h1 'REGISTRY' "$hostw"; pad_v h2 'UTENTE' "$userw"; pad_v h3 'ORIGINE' "$ogw"
  CT+=("  ${C_AZ2}${h1} ${h2} ${h3}${C_RESET}")

  local n=${#RG_HOST[@]}
  if (( n == 0 )); then
    CT+=("  ${C_DIM}(nessun registry configurato — premi 'a' per aggiungerne uno)${C_RESET}")
    HINT=" ${C_AZ}a${C_RESET}${C_DIM} aggiungi ${C_RESET}${C_AZ}g${C_RESET}${C_DIM} aggiorna ${C_RESET}${C_AZ}Tab${C_RESET}${C_DIM} menu ${C_RESET}${C_AZ}q${C_RESET}${C_DIM} esci${C_RESET}"
    return
  fi

  local avail=$(( (LINES_G-1) - ${#CT[@]} )); (( avail < 3 )) && avail=3
  LAST_AVAIL=$avail
  (( RGSEL >= n )) && RGSEL=$((n-1))
  (( RGSEL < RGTOP )) && RGTOP=$RGSEL
  (( RGSEL >= RGTOP+avail )) && RGTOP=$(( RGSEL-avail+1 ))
  (( RGTOP < 0 )) && RGTOP=0

  local i end=$((RGTOP+avail)); (( end > n )) && end=$n
  for ((i=RGTOP;i<end;i++)); do
    local bar=' ' nmcol="$C_RESET" hn un og
    (( i==RGSEL )) && { bar="${C_AZ}▌${C_RESET}"; nmcol="$C_BOLD$C_AZ"; }
    pad_v hn "${RG_HOST[i]}" "$hostw"; pad_v un "${RG_USER[i]}" "$userw"
    if (( RG_MINE[i] )); then pad_v og "gestito" "$ogw"; else pad_v og "docker" "$ogw"; fi
    CT+=("$bar ${nmcol}${hn}${C_RESET} ${C_GREY}${un}${C_RESET} ${C_DIM}${og}${C_RESET}")
  done
  HINT=" ${C_AZ}a${C_RESET}${C_DIM} aggiungi ${C_RESET}${C_ERR}x${C_RESET}${C_DIM} rimuovi ${C_RESET}${C_AZ}g${C_RESET}${C_DIM} aggiorna ${C_RESET}${C_AZ}Tab${C_RESET}${C_DIM} menu ${C_RESET}${C_AZ}q${C_RESET}${C_DIM} esci${C_RESET}"
}
handle_registry(){
  case "$1" in
    UP|k)    (( RGSEL>0 )) && ((RGSEL--));;
    DOWN|j)  (( RGSEL<${#RG_HOST[@]}-1 )) && ((RGSEL++));;
    PGUP)    RGSEL=$(( RGSEL-LAST_AVAIL )); (( RGSEL<0 )) && RGSEL=0;;
    PGDN)    RGSEL=$(( RGSEL+LAST_AVAIL )); (( RGSEL>=${#RG_HOST[@]} )) && RGSEL=$(( ${#RG_HOST[@]}-1 ));;
    a|A)     reg_add;;
    x|X)     reg_remove;;
    g|G)     notify_info "aggiorno..."; RG_LOADED=0; load_registry; notify_clear;;
    R)       col_reset_view;;
    LEFT)    FOCUS=menu;;
    ESC)     if [[ -n $MSG ]]; then notify_clear; else FOCUS=menu; fi;;
    '?')     activate help;;
    *)       :;;
  esac
}

# =============================================================================
#  IMMAGINI  (lista/rimozione locale + pull da URL o da registry salvato)
# =============================================================================
img_b64_decode(){ # base64 -> testo (stdout). vuoto se input vuoto
  [[ -n $1 ]] || return 0
  printf '%s' "$1" | base64 -d 2>/dev/null || printf '%s' "$1" | base64 --decode 2>/dev/null
}

extract_docker_auth(){ # config.json host -> stringa base64 "auth" (stdout)
  local cfg="$1" host="$2"
  [[ -r $cfg ]] || return 0
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg h "$host" '.auths[$h].auth // empty' "$cfg" 2>/dev/null; return
  fi
  # fallback: trova il blocco dell'host e il primo "auth" al suo interno
  awk -v h="$host" '
    function keyopen(l){ return (l ~ /"[^"]+"[[:space:]]*:[[:space:]]*\{/) }
    {
      line=$0
      started=0
      if (!intarget && index(line, "\"" h "\"") > 0 && keyopen(line)) { intarget=1; started=1 }
      if (intarget) {
        if (match(line, /"auth"[[:space:]]*:[[:space:]]*"[^"]+"/)) {
          s=substr(line,RSTART,RLENGTH); sub(/.*"auth"[[:space:]]*:[[:space:]]*"/,"",s); sub(/".*/,"",s)
          print s; exit
        }
        if (!started && keyopen(line)) { intarget=0 }
      }
    }' "$cfg" 2>/dev/null
}
img_registry_auth(){ # host -> REPLY_AUTH="user:pass" (rc 1 se assente)
  REPLY_AUTH=""
  local host; host=$(normalize_registry "$1")
  local cfg="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
  local enc; enc=$(extract_docker_auth "$cfg" "$host")
  [[ -n $enc ]] || return 1
  REPLY_AUTH=$(img_b64_decode "$enc")
  [[ -n $REPLY_AUTH ]] || return 1
  return 0
}

_json_string_array(){ # body chiave -> elementi array (stdout, uno per riga)
  local body="$1" key="$2"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$body" | jq -r --arg k "$key" '.[$k][]?' 2>/dev/null; return
  fi
  # fallback: isola [ ... ] dopo "key" e stampa le stringhe
  printf '%s' "$body" | tr -d '\n' \
    | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\\[\\([^]]*\\)\\].*/\\1/p" \
    | grep -oE '"[^"]*"' | sed 's/^"//; s/"$//'
}
parse_v2_catalog(){ _json_string_array "$1" repositories; }
parse_v2_tags(){    _json_string_array "$1" tags; }

parse_harbor_names(){ # array [{"name":...}] -> name per riga
  local body="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$body" | jq -r '.[].name? // empty' 2>/dev/null; return
  fi
  printf '%s' "$body" | grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]+"' \
    | sed 's/.*"\([^"]*\)"$/\1/'
}
parse_harbor_tags(){ # array artifacts con .tags[].name -> name per riga
  local body="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$body" | jq -r '.[].tags[]?.name? // empty' 2>/dev/null; return
  fi
  # fallback: isola i blocchi "tags":[...] (i tag object non contengono ']'),
  # poi estrae i "name" SOLO dentro quei blocchi (esclude labels[].name ecc.)
  printf '%s' "$body" | tr -d '\n' \
    | grep -oE '"tags"[[:space:]]*:[[:space:]]*\[[^]]*\]' \
    | grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]+"' \
    | sed 's/.*"\([^"]*\)"$/\1/'
}
reg_kind_from_status(){ case "$1" in 2??) echo harbor;; *) echo v2;; esac; }

# =============================================================================
#  LAYER HTTP (curl) — probe stato e GET body
# =============================================================================
HTTP_TIMEOUT=8
http_available(){ command -v curl >/dev/null 2>&1; }
http_status(){ # url userpass -> codice http su stdout (000 se irraggiungibile)
  local url="$1" up="$2" auth=()
  [[ -n $up ]] && auth=(-u "$up")
  curl -s -o /dev/null -w '%{http_code}' --max-time "$HTTP_TIMEOUT" "${auth[@]}" "$url" 2>/dev/null || echo 000
}
http_get(){ # url userpass -> body su stdout ; rc di curl
  local url="$1" up="$2" auth=()
  [[ -n $up ]] && auth=(-u "$up")
  curl -fsSL --max-time "$HTTP_TIMEOUT" "${auth[@]}" "$url" 2>/dev/null
}

# =============================================================================
#  ORCHESTRAZIONE REGISTRY (rilevamento + listing repos/tags)
# =============================================================================
reg_scheme(){ case "$1" in localhost*|127.0.0.1*) echo http;; *) echo https;; esac; }

reg_detect_kind(){ # host userpass -> harbor|v2
  local host="$1" up="$2" sch st
  sch=$(reg_scheme "$host")
  st=$(http_status "$sch://$host/api/v2.0/systeminfo" "$up")
  reg_kind_from_status "$st"
}

reg_list_repos(){ # host userpass kind -> repo per riga
  local host="$1" up="$2" kind="$3" sch body
  sch=$(reg_scheme "$host")
  if [[ $kind == harbor ]]; then
    # enumera i progetti, poi i repository di ciascuno.
    # L'endpoint globale /repositories su Harbor puo' tornare [] (dipende da
    # permessi/versione); projects + repositories-per-progetto e' affidabile.
    # Il campo name dei repo e' gia' "progetto/repo" (pronto per tag/pull).
    local proj pbody
    pbody=$(http_get "$sch://$host/api/v2.0/projects?page_size=100" "$up")
    while IFS= read -r proj; do
      [[ -n $proj ]] || continue
      body=$(http_get "$sch://$host/api/v2.0/projects/$proj/repositories?page_size=100" "$up")
      parse_harbor_names "$body"
    done < <(parse_harbor_names "$pbody")
  else
    body=$(http_get "$sch://$host/v2/_catalog?n=1000" "$up")
    parse_v2_catalog "$body"
  fi
}

reg_list_tags(){ # host userpass kind repo -> tag per riga
  local host="$1" up="$2" kind="$3" repo="$4" sch body proj rest
  sch=$(reg_scheme "$host")
  if [[ $kind == harbor ]]; then
    proj="${repo%%/*}"; rest="${repo#*/}"
    # Harbor richiede il nome repository URL-encoded (le '/' interne diventano %2F)
    rest="${rest//\//%2F}"
    body=$(http_get "$sch://$host/api/v2.0/projects/$proj/repositories/$rest/artifacts?with_tag=true&page_size=100" "$up")
    parse_harbor_tags "$body"
  else
    body=$(http_get "$sch://$host/v2/$repo/tags/list" "$up")
    parse_v2_tags "$body"
  fi
}

# =============================================================================
#  LOAD_IMAGES / IMG_ENSURE (caricamento immagini locali)
# =============================================================================
declare -a IM_ID IM_REPO IM_TAG IM_SIZE IM_CREATED IM_DIGEST
declare -A IMG_INUSE
IMG_LOADED=0; IMGSEL=0; IMGTOP=0; IMG_DANGLING=0; IMG_TOTAL=0
# ridimensionamento colonne col mouse (generico, tutte le tabelle)
declare -A COLW_OVR                 # "vista:colonna" -> larghezza forzata
declare -A CUR_COLW                 # "colonna" -> larghezza corrente nella vista mostrata
declare -a SEP_X SEP_COL           # x-schermo del bordo destro + chiave colonna (hit-test)
RZ_ACTIVE=0; RZ_COL=""; RZ_STARTX=0; RZ_STARTW=0
MOUSE_BTN=""; MOUSE_X=0; MOUSE_Y=0; MOUSE_REL=0
sep_reset(){ SEP_X=(); SEP_COL=(); }
sep_add(){ SEP_X+=($(( CX+1+$1 ))); SEP_COL+=("$2"); }   # $1=offset contenuto, $2=chiave
col_eff(){ # chiave default -> larghezza effettiva (override+clamp) su stdout
  local w="$2" ov="${COLW_OVR["$MODE:$1"]:-}" maxw=$(( CW/3 ))
  (( maxw<8 )) && maxw=8
  [[ -n $ov ]] && w=$ov
  (( w>maxw )) && w=$maxw; (( w<4 )) && w=4
  printf '%s' "$w"
}
col_reset_view(){ local k; for k in "${!COLW_OVR[@]}"; do [[ $k == "$MODE:"* ]] && unset 'COLW_OVR[$k]'; done; notify_info "larghezze colonne ripristinate"; }

load_images(){
  IM_ID=(); IM_REPO=(); IM_TAG=(); IM_SIZE=(); IM_CREATED=(); IM_DIGEST=()
  IMG_INUSE=(); IMG_DANGLING=0; IMG_TOTAL=0
  # immagini usate da container (running o meno).
  # Chiave affidabile = ID immagine completo (.Image da inspect = sha256:...),
  # piu' il ref usato (.Config.Image) come fallback. Nome container da .Name.
  local iid iref cname
  while IFS=$'\t' read -r iid iref cname; do
    cname="${cname#/}"; [[ -n $cname ]] || continue
    if [[ -n $iid ]]; then
      if [[ -n ${IMG_INUSE["$iid"]:-} ]]; then IMG_INUSE["$iid"]+=",${cname}"; else IMG_INUSE["$iid"]="$cname"; fi
    fi
    if [[ -n $iref ]]; then
      if [[ -n ${IMG_INUSE["$iref"]:-} ]]; then IMG_INUSE["$iref"]+=",${cname}"; else IMG_INUSE["$iref"]="$cname"; fi
    fi
  done < <(docker ps -aq 2>/dev/null | xargs -r docker inspect \
             --format '{{.Image}}{{"\t"}}{{.Config.Image}}{{"\t"}}{{.Name}}' 2>/dev/null)
  local id repo tag size created digest
  while IFS=$'\t' read -r id repo tag size created digest; do
    [[ -n $id ]] || continue
    IM_ID+=("$id"); IM_REPO+=("$repo"); IM_TAG+=("$tag")
    IM_SIZE+=("$size"); IM_CREATED+=("$created"); IM_DIGEST+=("$digest")
    ((IMG_TOTAL++))
    [[ $repo == "<none>" ]] && ((IMG_DANGLING++))
  done < <(docker images --no-trunc \
      --format '{{.ID}}\t{{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}\t{{.Digest}}' 2>/dev/null)
  IMG_LOADED=1; IMGSEL=0; IMGTOP=0
}
img_ensure(){ (( IMG_LOADED )) || load_images; }
img_containers(){ # repo tag fullid -> nomi container che la usano (stdout), vuoto se nessuno
  local repo="$1" tag="$2" fid="$3" v
  v="${IMG_INUSE["$fid"]:-}"
  [[ -z $v ]] && v="${IMG_INUSE["$repo:$tag"]:-}"
  printf '%s' "$v"
}
img_split_registry(){ # full-repo -> REPLY_REG (host), REPLY_NAME (nome senza host)
  local r="$1"; local first="${r%%/*}"
  if [[ $r == "<none>" ]]; then REPLY_REG="—"; REPLY_NAME="<none>"; return; fi
  if [[ $r == */* && ( $first == *.* || $first == *:* || $first == localhost* ) ]]; then
    REPLY_REG="$first"; REPLY_NAME="${r#*/}"
  else
    REPLY_REG="docker.io"; REPLY_NAME="$r"
  fi
}

RB_LEVEL=registry   # registry | repos | tags
RB_HOST=""; RB_REPO=""; RB_AUTH=""; RB_KIND=""
declare -a RB_ITEMS
RBSEL=0; RBTOP=0

regbrowse_open(){
  if ! http_available; then notify_err "curl non disponibile: browsing remoto disattivato"; return; fi
  reg_ensure
  if (( ${#RG_HOST[@]} == 0 )); then notify_err "nessun registry: aggiungine uno in REGISTRY"; return; fi
  RB_LEVEL=registry; RB_HOST=""; RB_REPO=""; RB_AUTH=""; RB_KIND=""
  RB_ITEMS=("${RG_HOST[@]}"); RBSEL=0; RBTOP=0
  MODE=regbrowse; notify_clear; DIMS_DIRTY=1
}
regbrowse_load_level(){ # carica RB_ITEMS in base a RB_LEVEL
  RB_ITEMS=(); RBSEL=0; RBTOP=0
  local line
  case "$RB_LEVEL" in
    registry)
      RB_ITEMS=("${RG_HOST[@]}");;
    repos)
      if ! img_registry_auth "$RB_HOST"; then
        notify_err "credenziali assenti per ${RB_HOST}: fai login in REGISTRY"
        RB_LEVEL=registry; RB_ITEMS=("${RG_HOST[@]}"); return
      fi
      RB_AUTH="$REPLY_AUTH"
      notify_info "rilevo ${RB_HOST} ..."; render_frame
      RB_KIND=$(reg_detect_kind "$RB_HOST" "$RB_AUTH")
      notify_info "carico repository (${RB_KIND}) ..."; render_frame
      while IFS= read -r line; do [[ -n $line ]] && RB_ITEMS+=("$line"); done \
        < <(reg_list_repos "$RB_HOST" "$RB_AUTH" "$RB_KIND")
      notify_clear;;
    tags)
      notify_info "carico tag di ${RB_REPO} ..."; render_frame
      while IFS= read -r line; do [[ -n $line ]] && RB_ITEMS+=("$line"); done \
        < <(reg_list_tags "$RB_HOST" "$RB_AUTH" "$RB_KIND" "$RB_REPO")
      notify_clear;;
  esac
}
regbrowse_pull(){
  local tag="${RB_ITEMS[RBSEL]}" ref out rc
  ref="${RB_HOST}/${RB_REPO}:${tag}"
  confirm "Pull di ${ref}?" || { notify_warn "annullato"; return; }
  notify_info "pull ${ref} ..."; render_frame
  out=$(docker pull "$ref" 2>&1); rc=$?
  if (( rc == 0 )); then notify_ok "scaricata ${ref}"; IMG_LOADED=0; load_images
  else notify_err "pull: ${out##*$'\n'}"; fi
}

handle_images(){
  case "$1" in
    UP|k)    (( IMGSEL>0 )) && ((IMGSEL--));;
    DOWN|j)  (( IMGSEL<${#IM_ID[@]}-1 )) && ((IMGSEL++));;
    PGUP)    IMGSEL=$(( IMGSEL-LAST_AVAIL )); (( IMGSEL<0 )) && IMGSEL=0;;
    PGDN)    IMGSEL=$(( IMGSEL+LAST_AVAIL )); (( IMGSEL>=${#IM_ID[@]} )) && IMGSEL=$(( ${#IM_ID[@]}-1 )); (( IMGSEL<0 )) && IMGSEL=0;;
    ENTER)   images_details;;
    x|X)     image_remove;;
    u|U)     image_pull_url;;
    R)       col_reset_view;;
    b|B)     regbrowse_open;;
    p)       notify_info "aggiorno..."; IMG_LOADED=0; load_images; notify_clear;;
    g|G)     notify_info "aggiorno..."; IMG_LOADED=0; load_images; notify_clear;;
    LEFT)    FOCUS=menu;;
    ESC)     if [[ -n $MSG ]]; then notify_clear; else FOCUS=menu; fi;;
    '?')     activate help;;
    *)       :;;
  esac
}
build_regbrowse(){
  header_ct "IMMAGINI"
  local crumb
  case "$RB_LEVEL" in
    registry) crumb="scegli registry";;
    repos)    crumb="${RB_HOST}  (${RB_KIND:-?})";;
    tags)     crumb="${RB_HOST} / ${RB_REPO}";;
  esac
  panel_ct "SFOGLIA · ${crumb}"

  local n=${#RB_ITEMS[@]}
  if (( n == 0 )); then
    if [[ $RB_LEVEL == repos ]]; then
      CT+=("  ${C_DIM}(nessun repository: catalogo vuoto o non esposto dal registry)${C_RESET}")
    elif [[ $RB_LEVEL == tags ]]; then
      CT+=("  ${C_DIM}(nessun tag per questo repository)${C_RESET}")
    else
      CT+=("  ${C_DIM}(nessun registry configurato)${C_RESET}")
    fi
    HINT=" ${C_AZ}←${C_RESET}${C_DIM} indietro ${C_RESET}${C_AZ}g${C_RESET}${C_DIM} ricarica ${C_RESET}${C_AZ}q${C_RESET}${C_DIM} esci${C_RESET}"
    return
  fi

  local avail=$(( (LINES_G-1) - ${#CT[@]} )); (( avail < 3 )) && avail=3
  LAST_AVAIL=$avail
  (( RBSEL >= n )) && RBSEL=$((n-1))
  (( RBSEL < RBTOP )) && RBTOP=$RBSEL
  (( RBSEL >= RBTOP+avail )) && RBTOP=$(( RBSEL-avail+1 ))
  (( RBTOP < 0 )) && RBTOP=0

  local iw=$(( CW - 2 )); (( iw < 10 )) && iw=10
  local i end=$((RBTOP+avail)); (( end > n )) && end=$n
  for ((i=RBTOP;i<end;i++)); do
    local bar=' ' nmcol="$C_RESET" it
    (( i==RBSEL )) && { bar="${C_AZ}▌${C_RESET}"; nmcol="$C_BOLD$C_AZ"; }
    pad_v it "${RB_ITEMS[i]}" "$iw"
    CT+=("$bar ${nmcol}${it}${C_RESET}")
  done

  case "$RB_LEVEL" in
    tags) HINT=" ${C_AZ}↵${C_RESET}${C_DIM} pull ${C_RESET}${C_AZ}←${C_RESET}${C_DIM} indietro ${C_RESET}${C_AZ}g${C_RESET}${C_DIM} ricarica ${C_RESET}${C_AZ}q${C_RESET}${C_DIM} esci${C_RESET}";;
    *)    HINT=" ${C_AZ}↵${C_RESET}${C_DIM} apri ${C_RESET}${C_AZ}←${C_RESET}${C_DIM} indietro ${C_RESET}${C_AZ}g${C_RESET}${C_DIM} ricarica ${C_RESET}${C_AZ}q${C_RESET}${C_DIM} esci${C_RESET}";;
  esac
}
handle_regbrowse(){
  case "$1" in
    UP|k)    (( RBSEL>0 )) && ((RBSEL--));;
    DOWN|j)  (( RBSEL<${#RB_ITEMS[@]}-1 )) && ((RBSEL++));;
    PGUP)    RBSEL=$(( RBSEL-LAST_AVAIL )); (( RBSEL<0 )) && RBSEL=0;;
    PGDN)    RBSEL=$(( RBSEL+LAST_AVAIL )); (( RBSEL>=${#RB_ITEMS[@]} )) && RBSEL=$(( ${#RB_ITEMS[@]}-1 )); (( RBSEL<0 )) && RBSEL=0;;
    ENTER)
      (( ${#RB_ITEMS[@]} > 0 )) || return
      case "$RB_LEVEL" in
        registry) RB_HOST="${RB_ITEMS[RBSEL]}"; RB_LEVEL=repos; regbrowse_load_level;;
        repos)    RB_REPO="${RB_ITEMS[RBSEL]}"; RB_LEVEL=tags;  regbrowse_load_level;;
        tags)     regbrowse_pull;;
      esac;;
    LEFT|ESC)
      if [[ -n $MSG && $1 == ESC ]]; then notify_clear; return; fi
      case "$RB_LEVEL" in
        tags)     RB_LEVEL=repos; regbrowse_load_level;;
        repos)    RB_LEVEL=registry; RB_ITEMS=("${RG_HOST[@]}"); RBSEL=0; RBTOP=0;;
        registry) MODE=images;;
      esac;;
    g|G)     regbrowse_load_level;;
    '?')     activate help;;
    *)       :;;
  esac
}

build_images(){
  header_ct "IMMAGINI"
  # riassunto: totale + spazio + dangling
  local totb=0 i b
  for ((i=0; i<${#IM_SIZE[@]}; i++)); do b=$(to_bytes "${IM_SIZE[i]}"); totb=$(( totb + b )); done
  hb_v "$totb"
  local sm
  printf -v sm ' %simmagini%s %s%d%s   %sspazio%s %s%s%s   %sdangling%s %s%d%s' \
    "$C_DIM" "$C_RESET" "$C_AZ$C_BOLD" "$IMG_TOTAL" "$C_RESET" \
    "$C_DIM" "$C_RESET" "$C_AZ2" "$HB_OUT" "$C_RESET" \
    "$C_DIM" "$C_RESET" "$C_WARN" "$IMG_DANGLING" "$C_RESET"
  CT+=("$sm"); CT+=("")
  panel_ct "IMMAGINI LOCALI · ${IMG_TOTAL}"

  local n=${#IM_ID[@]}

  # colonne responsive in base alla larghezza contenuto (CW)
  local cols=$CW
  local regw=20 tagw=14 sizew=9 idw=12 usew=18
  local show_reg=1 show_id=1 show_use=1
  if (( cols < 104 )); then regw=16; tagw=12; idw=10; usew=14; fi
  if (( cols < 86  )); then show_id=0; fi
  if (( cols < 72  )); then show_reg=0; fi
  if (( cols < 58  )); then show_use=0; fi
  # override da resize mouse (con clamp) via col_eff; CUR_COLW nella shell principale
  (( show_reg )) && { regw=$(col_eff reg "$regw"); CUR_COLW[reg]=$regw; }
  tagw=$(col_eff tag "$tagw"); CUR_COLW[tag]=$tagw
  (( show_id )) && { idw=$(col_eff id "$idw"); CUR_COLW[id]=$idw; }
  (( show_use )) && { usew=$(col_eff use "$usew"); CUR_COLW[use]=$usew; }
  local otherw=$(( tagw + sizew )) nvis=3
  (( show_reg )) && { otherw=$(( otherw + regw )); ((nvis++)); }
  (( show_id ))  && { otherw=$(( otherw + idw ));  ((nvis++)); }
  (( show_use )) && { otherw=$(( otherw + usew )); ((nvis++)); }
  local namew=$(( cols - otherw - (nvis-1) - 2 )); (( namew < 8 )) && namew=8

  # posizioni x dei bordi colonna ridimensionabili
  sep_reset
  local _off=2
  if (( show_reg )); then _off=$((_off+regw)); sep_add "$_off" reg; _off=$((_off+1)); fi
  _off=$((_off+namew+1))
  _off=$((_off+tagw)); sep_add "$_off" tag; _off=$((_off+1))
  _off=$((_off+sizew))
  if (( show_id )); then _off=$((_off+1+idw)); sep_add "$_off" id; fi
  if (( show_use )); then _off=$((_off+1+usew)); sep_add "$_off" use; fi

  # intestazione (stessa struttura di spaziatura delle righe)
  local hr hn ht hs hi hu hdr="  "
  (( show_reg )) && { pad_v hr 'REGISTRY' "$regw"; hdr+="${C_AZ2}${hr}${C_RESET} "; }
  pad_v hn 'IMMAGINE' "$namew"; hdr+="${C_AZ2}${hn}${C_RESET} "
  pad_v ht 'TAG' "$tagw"; hdr+="${C_AZ2}${ht}${C_RESET} "
  padr_v hs 'SIZE' "$sizew"; hdr+="${C_AZ2}${hs}${C_RESET}"
  (( show_id ))  && { pad_v hi 'ID' "$idw"; hdr+=" ${C_AZ2}${hi}${C_RESET}"; }
  (( show_use )) && { pad_v hu 'USATA DA' "$usew"; hdr+=" ${C_AZ2}${hu}${C_RESET}"; }
  CT+=("$hdr")

  if (( n == 0 )); then
    CT+=("  ${C_DIM}(nessuna immagine locale — 'u' pull da URL · 'b' sfoglia registry)${C_RESET}")
    HINT=" ${C_AZ}u${C_RESET}${C_DIM} pull URL ${C_RESET}${C_AZ}b${C_RESET}${C_DIM} sfoglia ${C_RESET}${C_AZ}g${C_RESET}${C_DIM} aggiorna ${C_RESET}${C_AZ}Tab${C_RESET}${C_DIM} menu ${C_RESET}${C_AZ}q${C_RESET}${C_DIM} esci${C_RESET}"
    return
  fi

  local avail=$(( (LINES_G-1) - ${#CT[@]} )); (( avail < 3 )) && avail=3
  LAST_AVAIL=$avail
  (( IMGSEL >= n )) && IMGSEL=$((n-1))
  (( IMGSEL < IMGTOP )) && IMGTOP=$IMGSEL
  (( IMGSEL >= IMGTOP+avail )) && IMGTOP=$(( IMGSEL-avail+1 ))
  (( IMGTOP < 0 )) && IMGTOP=0

  local end=$((IMGTOP+avail)); (( end > n )) && end=$n
  for ((i=IMGTOP;i<end;i++)); do
    local bar=' ' nmcol="$C_RESET" repo tag idshort reg name cont contcol
    (( i==IMGSEL )) && { bar="${C_AZ}▌${C_RESET}"; nmcol="$C_BOLD$C_AZ"; }
    repo="${IM_REPO[i]}"; tag="${IM_TAG[i]}"
    if [[ ${IM_ID[i]} == sha256:* ]]; then idshort="${IM_ID[i]:7:12}"; else idshort="${IM_ID[i]:0:12}"; fi
    img_split_registry "$repo"; reg="$REPLY_REG"; name="$REPLY_NAME"
    cont=$(img_containers "$repo" "$tag" "${IM_ID[i]}"); contcol=$C_OK
    [[ -z $cont ]] && { cont="—"; contcol=$C_DIM; }
    local fr fn ft fs fi2 fu line="$bar "
    (( show_reg )) && { pad_v fr "$reg" "$regw"; line+="${C_GREY}${fr}${C_RESET} "; }
    pad_v fn "$name" "$namew"; line+="${nmcol}${fn}${C_RESET} "
    pad_v ft "$tag" "$tagw"; line+="${C_GREY}${ft}${C_RESET} "
    padr_v fs "${IM_SIZE[i]}" "$sizew"; line+="${C_AZ2}${fs}${C_RESET}"
    (( show_id ))  && { pad_v fi2 "$idshort" "$idw"; line+=" ${C_DIM}${fi2}${C_RESET}"; }
    (( show_use )) && { pad_v fu "$cont" "$usew"; line+=" ${contcol}${fu}${C_RESET}"; }
    CT+=("$line")
  done
  HINT=" ${C_AZ}↑↓${C_RESET}${C_DIM} nav ${C_RESET}${C_AZ}↵${C_RESET}${C_DIM} dettagli ${C_RESET}${C_ERR}x${C_RESET}${C_DIM} rimuovi ${C_RESET}${C_AZ}u${C_RESET}${C_DIM} pull ${C_RESET}${C_AZ}b${C_RESET}${C_DIM} sfoglia ${C_RESET}${C_AZ}g${C_RESET}${C_DIM} refresh ${C_RESET}${C_AZ}R${C_RESET}${C_DIM} reset col ${C_RESET}${C_AZ}q${C_RESET}${C_DIM} esci${C_RESET}"
}
images_details(){
  (( ${#IM_ID[@]} > 0 )) || return
  local id="${IM_ID[IMGSEL]}"
  local info
  info=$(docker image inspect "$id" --format \
'Immagine    : {{range .RepoTags}}{{.}} {{end}}
ID          : {{.Id}}
Digest      : {{range .RepoDigests}}{{.}} {{end}}
Creata      : {{.Created}}
Dimensione  : {{.Size}} byte
Arch / OS   : {{.Architecture}} / {{.Os}}
Entrypoint  : {{join .Config.Entrypoint " "}}
Cmd         : {{join .Config.Cmd " "}}
Porte       : {{range $p,$v := .Config.ExposedPorts}}{{$p}} {{end}}
Env         : {{range .Config.Env}}{{println .}}{{end}}' 2>&1)
  overlay "Dettagli immagine: ${IM_REPO[IMGSEL]}:${IM_TAG[IMGSEL]}" "$info"
}
image_remove(){
  (( ${#IM_ID[@]} > 0 )) || return
  local id="${IM_ID[IMGSEL]}" ref="${IM_REPO[IMGSEL]}:${IM_TAG[IMGSEL]}" out rc
  confirm "Rimuovere l'immagine ${ref}?" || { notify_warn "annullato"; return; }
  notify_info "rimozione ${ref} ..."; render_frame
  out=$(docker rmi "$id" 2>&1); rc=$?
  if (( rc == 0 )); then notify_ok "rimossa ${ref}"
  else
    if confirm "Rimozione fallita (in uso?). Forzare con -f?"; then
      out=$(docker rmi -f "$id" 2>&1); rc=$?
      if (( rc == 0 )); then notify_ok "rimossa (forzata) ${ref}"
      else notify_err "rmi: ${out##*$'\n'}"; fi
    else notify_warn "annullato"; fi
  fi
  IMG_LOADED=0; load_images
}
image_pull_url(){
  if ! prompt_input "Immagine (es. nginx:1.25 o ghcr.io/org/img:tag):" ""; then
    notify_warn "annullato"; DIMS_DIRTY=1; return
  fi
  local ref="$REPLY_VAL" out rc
  notify_info "pull ${ref} ..."; render_frame
  out=$(docker pull "$ref" 2>&1); rc=$?
  if (( rc == 0 )); then notify_ok "scaricata ${ref}"
  else notify_err "pull: ${out##*$'\n'}"; fi
  IMG_LOADED=0; load_images; DIMS_DIRTY=1
}

# =============================================================================
#  IMPOSTAZIONI
# =============================================================================
SSEL=0
declare -a S_KEY S_LABEL
S_KEY=(BRAND APPS_DIR DATA_DIR QUOTA_CONF QUOTA_MNT FETCH_INTERVAL RENDER_TICK)
S_LABEL=("Nome in alto (brand)" "Percorso apps (cartelle progetto)" "Percorso dati (es. /home/mexage/data)" "File quote (quota.conf)" "Mount quote (di norma /)" "Intervallo fetch docker (secondi)" "Refresh schermo (secondi)")

setting_value(){
  case "$1" in
    BRAND)          printf '%s' "$BRAND";;
    APPS_DIR)       printf '%s' "$APPS_DIR";;
    DATA_DIR)       printf '%s' "$DATA_DIR";;
    QUOTA_CONF)     printf '%s' "$QUOTA_CONF";;
    QUOTA_MNT)      printf '%s' "$QUOTA_MNT";;
    FETCH_INTERVAL) printf '%s' "$FETCH_INTERVAL";;
    RENDER_TICK)    printf '%s' "$RENDER_TICK";;
  esac
}
prompt_input(){ # $1 label $2 default(hint) -> REPLY_VAL (rc 1 = ESC/vuoto = annulla)
  local label="$1" def="$2"
  input_begin
  printf '\e[%d;1H\e[2K%s%s%s' $((LINES_G-1)) "$C_AZ$C_BOLD" "$label" "$C_RESET"
  [[ -n $def ]] && printf ' %s[invio = %s]%s' "$C_DIM" "$def" "$C_RESET"
  printf ' %s(Esc annulla)%s' "$C_DIM" "$C_RESET"
  printf '\e[%d;1H\e[2K%s>%s ' "$LINES_G" "$C_AZ" "$C_RESET"
  read_line 0; local rc=$?
  input_end
  (( rc != 0 )) && return 1
  local v; v=$(sanitize_input "$REPLY_LINE")
  [[ -z $v ]] && return 1
  REPLY_VAL="$v"
  return 0
}
apply_setting(){
  local key="$1" val="$2"
  case "$key" in
    BRAND)
      BRAND="$val"; save_config; notify_ok "nome in alto: $BRAND";;
    APPS_DIR)
      APPS_DIR="$val"; save_config
      if [[ -d $APPS_DIR ]]; then
        fetch_snapshot; discover; build_rows; SEL=0; TOP=0; FS_LOADED=0
        notify_ok "percorso apps: $APPS_DIR (${#U_NAME[@]} progetti trovati)"
      else
        U_NAME=(); build_rows; FS_LOADED=0
        notify_warn "percorso salvato ma la cartella non esiste: $APPS_DIR"
      fi;;
    DATA_DIR)
      DATA_DIR="$val"; save_config; FS_LOADED=0
      if [[ -d $DATA_DIR ]]; then notify_ok "percorso dati: $DATA_DIR"
      else notify_warn "percorso salvato ma la cartella non esiste: $DATA_DIR"; fi;;
    QUOTA_CONF)
      QUOTA_CONF="$val"; save_config; FS_LOADED=0
      notify_ok "file quote: $QUOTA_CONF";;
    QUOTA_MNT)
      QUOTA_MNT="$val"; save_config; FS_LOADED=0
      notify_ok "mount quote: $QUOTA_MNT";;
    FETCH_INTERVAL)
      if [[ $val =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v v="$val" 'BEGIN{exit !(v>=0.5)}'; then
        FETCH_INTERVAL="$val"; save_config
        if [[ -n $FETCH_PID ]]; then kill "$FETCH_PID" 2>/dev/null; fetch_loop & FETCH_PID=$!; fi
        notify_ok "intervallo fetch: ${FETCH_INTERVAL}s"
      else notify_err "valore non valido (numero >= 0.5)"; fi;;
    RENDER_TICK)
      if [[ $val =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v v="$val" 'BEGIN{exit !(v>=0.2)}'; then
        RENDER_TICK="$val"; save_config
        notify_ok "refresh schermo: ${RENDER_TICK}s"
      else notify_err "valore non valido (numero >= 0.2)"; fi;;
  esac
}
build_settings(){
  header_ct "IMPOSTAZIONI"
  panel_ct "CONFIGURAZIONE"
  CT+=("  ${C_DIM}file: ${CONF_FILE}${C_RESET}")
  CT+=("  ${C_DIM}le variabili DM_* hanno la precedenza sul file${C_RESET}")
  CT+=("")
  local i val lb
  for i in "${!S_KEY[@]}"; do
    local bar=' ' nmcol="$C_BOLD"
    (( i==SSEL )) && { bar="${C_AZ}▌${C_RESET}"; nmcol="$C_BOLD$C_AZ"; }
    val="$(setting_value "${S_KEY[i]}")"
    pad_v lb "${S_LABEL[i]}" 38
    CT+=("$bar ${nmcol}${lb}${C_RESET} ${C_AZ2}${val}${C_RESET}")
  done
  CT+=("")
  CT+=("  ${C_DIM}APPS_DIR: cartelle con docker-compose.yml${C_RESET}")
  CT+=("  ${C_DIM}DATA_DIR: base delle quote mostrate in FILESYSTEM${C_RESET}")
  HINT=" ${C_AZ}↵${C_RESET}${C_DIM} modifica ${C_RESET}${C_AZ}Tab${C_RESET}${C_DIM} menu ${C_RESET}${C_AZ}q${C_RESET}${C_DIM} esci${C_RESET}"
}
handle_settings(){
  case "$1" in
    UP|k)    (( SSEL>0 )) && ((SSEL--));;
    DOWN|j)  (( SSEL<${#S_KEY[@]}-1 )) && ((SSEL++));;
    LEFT)    FOCUS=menu;;
    ESC)     if [[ -n $MSG ]]; then notify_clear; else FOCUS=menu; fi;;
    ENTER)
      local key="${S_KEY[SSEL]}" cur
      cur="$(setting_value "$key")"
      if prompt_input "${S_LABEL[SSEL]}:" "$cur"; then apply_setting "$key" "$REPLY_VAL"
      else notify_warn "modifica annullata"; fi
      DIMS_DIRTY=1;;
    '?')     activate help;;
    *)       :;;
  esac
}

# =============================================================================
#  AIUTO
# =============================================================================
build_help(){
  header_ct "AIUTO"
  panel_ct "GUIDA RAPIDA"
  CT+=("  ${C_AZ2}Menu (colonna sinistra)${C_RESET}")
  CT+=("    ${C_AZ}Tab${C_RESET}${C_DIM} sposta il focus tra menu e contenuto${C_RESET}")
  CT+=("    ${C_AZ}↑ ↓ ↵${C_RESET}${C_DIM} scegli e apri la sezione${C_RESET}")
  CT+=("    ${C_AZ}1..6${C_RESET}${C_DIM} salta a Servizi/Filesystem/Immagini/Registry/Impostazioni/Aiuto${C_RESET}")
  CT+=("    ${C_AZ}←${C_RESET}${C_DIM} dal contenuto torna al menu · ${C_RESET}${C_AZ}rotella${C_RESET}${C_DIM} scorre la lista${C_RESET}")
  CT+=("")
  CT+=("  ${C_AZ2}Servizi${C_RESET}")
  CT+=("    ${C_OK}s${C_RESET} avvia   ${C_ERR}x${C_RESET} ferma   ${C_WARN}r${C_RESET} riavvia   ${C_AZ}l${C_RESET} log   ${C_AZ}↵${C_RESET} dettagli   ${C_AZ}p${C_RESET} refresh")
  CT+=("    ${C_DIM}Le azioni su un PROGETTO valgono per tutti i suoi servizi.${C_RESET}")
  CT+=("")
  CT+=("  ${C_AZ2}Filesystem (project quota ext4)${C_RESET}")
  CT+=("    ${C_DIM}Legge le quote da ${C_RESET}${C_AZ}${QUOTA_CONF}${C_RESET}${C_DIM} + repquota (root).${C_RESET}")
  CT+=("    ${C_AZ}e${C_RESET}${C_DIM} imposta/rimuovi quota · ${C_RESET}${C_AZ}↵${C_RESET}${C_DIM} sfoglia le dimensioni.${C_RESET}")
  CT+=("")
  CT+=("  ${C_AZ2}Registry${C_RESET}")
  CT+=("    ${C_AZ}a${C_RESET}${C_DIM} login (host, utente, token) · ${C_RESET}${C_ERR}x${C_RESET}${C_DIM} logout e rimuovi.${C_RESET}")
  CT+=("")
  CT+=("  ${C_AZ2}Immagini${C_RESET}")
  CT+=("    ${C_AZ}↵${C_RESET} dettagli   ${C_ERR}x${C_RESET} rimuovi   ${C_AZ}u${C_RESET} pull da URL   ${C_AZ}b${C_RESET} sfoglia registry")
  CT+=("    ${C_DIM}'b' sfoglia un registry salvato (Harbor o v2) e fa il pull. Serve curl + login.${C_RESET}")
  CT+=("")
  CT+=("  ${C_AZ2}Legenda stato${C_RESET}")
  CT+=("    ${C_OK}● attivo${C_RESET}  ${C_ERR}○ spento${C_RESET}  ${C_WARN}‖ pausa  ◌ creato  ↻ riavvio${C_RESET}  ${C_GREY}· assente${C_RESET}")
  HINT=" ${C_AZ}Tab${C_RESET}${C_DIM} menu ${C_RESET}${C_AZ}1${C_RESET}${C_DIM} servizi ${C_RESET}${C_AZ}q${C_RESET}${C_DIM} esci${C_RESET}"
}
handle_help(){
  case "$1" in
    LEFT|ESC) FOCUS=menu;;
    *)        :;;
  esac
}

# =============================================================================
#  ATTIVAZIONE SEZIONI + MENU
# =============================================================================
activate(){
  case "$1" in
    services)   MODE=services;   MSEL=0;;
    filesystem) MODE=filesystem; MSEL=1; fs_ensure;;
    images)     MODE=images;     MSEL=2; img_ensure;;
    registry)   MODE=registry;   MSEL=3; reg_ensure;;
    settings)   MODE=settings;   MSEL=4; SSEL=0;;
    help)       MODE=help;       MSEL=5;;
  esac
  FOCUS=content; notify_clear; DIMS_DIRTY=1
}
handle_menu(){
  case "$1" in
    UP|k)         (( MSEL>0 )) && ((MSEL--));;
    DOWN|j)       (( MSEL<${#MENU_KEY[@]}-1 )) && ((MSEL++));;
    ENTER|RIGHT)  activate "${MENU_KEY[MSEL]}";;
    ESC)          notify_clear;;
    *)            :;;
  esac
}

handle_mouse(){ # drag sui bordi colonna -> ridimensiona (tutte le tabelle)
  if (( MOUSE_REL )); then (( RZ_ACTIVE )) && notify_ok "colonna ${RZ_COL} ridimensionata"; RZ_ACTIVE=0; RZ_COL=""; return; fi
  local x=$MOUSE_X
  if (( RZ_ACTIVE )); then
    local neww=$(( RZ_STARTW + (x - RZ_STARTX) )) maxw=$(( CW/3 ))
    (( maxw < 8 )) && maxw=8
    (( neww < 4 )) && neww=4; (( neww > maxw )) && neww=$maxw
    COLW_OVR["$MODE:$RZ_COL"]=$neww
    notify_info "↔ ${RZ_COL}: ${neww} col (trascina · rilascia per confermare)"
    return
  fi
  # press: cerca un bordo colonna vicino (±1) e inizia il resize
  local j
  for j in "${!SEP_X[@]}"; do
    if (( x >= SEP_X[j]-1 && x <= SEP_X[j]+1 )); then
      RZ_ACTIVE=1; RZ_COL="${SEP_COL[j]}"; RZ_STARTX=$x
      RZ_STARTW=${CUR_COLW["$RZ_COL"]:-10}
      notify_info "↔ grab colonna ${RZ_COL} — trascina per ridimensionare"
      return
    fi
  done
}
dispatch(){
  case "$KEY" in
    TIMEOUT) return;;
    q|Q)     exit 0;;
    MOUSE)   handle_mouse; return;;
    TAB)     if [[ $FOCUS == menu ]]; then FOCUS=content; else FOCUS=menu; fi; return;;
    1)       activate services;   return;;
    2)       activate filesystem; return;;
    3)       activate images;     return;;
    4)       activate registry;   return;;
    5)       activate settings;   return;;
    6)       activate help;       return;;
  esac
  if [[ $FOCUS == menu ]]; then handle_menu "$KEY"; return; fi
  case "$MODE" in
    services)   handle_services "$KEY";;
    filesystem) handle_filesystem "$KEY";;
    images)     handle_images "$KEY";;
    regbrowse)  handle_regbrowse "$KEY";;
    browse)     handle_browse "$KEY";;
    registry)   handle_registry "$KEY";;
    settings)   handle_settings "$KEY";;
    help)       handle_help "$KEY";;
    *)          handle_services "$KEY";;
  esac
}

# =============================================================================
#  INPUT
# =============================================================================
read_key(){
  KEY=""
  local k k1 k2 k3
  if ! IFS= read -rsn1 -t "$RENDER_TICK" k; then KEY="TIMEOUT"; return; fi
  if [[ -z $k ]]; then KEY="ENTER"; return; fi
  if [[ $k == $'\t' ]]; then KEY="TAB"; return; fi
  if [[ $k == $'\e' ]]; then
    if ! IFS= read -rsn1 -t 0.05 k1; then KEY="ESC"; return; fi
    if [[ $k1 == '[' || $k1 == 'O' ]]; then
      if ! IFS= read -rsn1 -t 0.05 k2; then KEY="ESC"; return; fi
      case $k2 in
        A) KEY="UP";;  B) KEY="DOWN";;
        C) KEY="RIGHT";; D) KEY="LEFT";;
        H) KEY="HOME";;  F) KEY="END";;
        '<')
          # mouse SGR: <btn;x;y(M|m). rotella (64/65) scorre; il resto -> MOUSE
          local mseq="" ch
          while IFS= read -rsn1 -t 0.05 ch; do
            [[ $ch == 'M' || $ch == 'm' ]] && { [[ $ch == 'm' ]] && MOUSE_REL=1 || MOUSE_REL=0; break; }
            mseq+="$ch"
          done
          IFS=';' read -r MOUSE_BTN MOUSE_X MOUSE_Y <<< "$mseq"
          case "$MOUSE_BTN" in
            64) KEY="UP";;
            65) KEY="DOWN";;
            *)  KEY="MOUSE";;
          esac;;
        [0-9])
          IFS= read -rsn1 -t 0.05 k3
          case "$k2$k3" in
            '5~') KEY="PGUP";; '6~') KEY="PGDN";;
            '1~'|'7~') KEY="HOME";; '4~'|'8~') KEY="END";;
            *) KEY="ESC";;
          esac;;
        *) KEY="ESC";;
      esac
    else
      KEY="ESC"
    fi
    return
  fi
  KEY="$k"
}
input_pending(){ IFS= read -t 0; }

# =============================================================================
#  MAIN
# =============================================================================
if [[ ${DM_NO_MAIN:-0} != 1 ]]; then
MODE=services
SEL=0; TOP=0; LAST_AVAIL=10

# mini loading di avvio (spinner braille)
BOOT_FR=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
boot(){ printf '\r\e[2K  %s%s%s  %s%s%s  %s%s%s' \
  "$C_AZ$C_BOLD" "${BOOT_FR[$1]}" "$C_RESET" \
  "$C_BOLD" "$BRAND" "$C_RESET" "$C_DIM" "$2" "$C_RESET"; }
printf '\e[?25l'
boot 0 "avvio…";              docker info >/dev/null 2>&1 && echo 1 > "$OK_FILE"
boot 2 "scansione stack…";    fetch_snapshot
boot 4 "calcolo dimensioni…"; fetch_sizes
boot 6 "scoperta progetti…";  discover
boot 8 "pronto";              build_rows
printf '\r\e[2K'; printf '\e[?25h'
SEL=0

term_setup
fetch_loop & FETCH_PID=$!

NEED_RENDER=1
while :; do
  if (( NEED_RENDER )); then
    load_snapshots
    render_frame
  fi
  read_key
  dispatch
  if (( RZ_ACTIVE )); then NEED_RENDER=1
  elif [[ $KEY != TIMEOUT ]] && input_pending; then NEED_RENDER=0; else NEED_RENDER=1; fi
done
fi
