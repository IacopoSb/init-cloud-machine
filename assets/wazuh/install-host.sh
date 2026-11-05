#!/bin/bash
# Installa sull'host l'agent Wazuh e (classe A) ClamAV con la scansione settimanale.
# Da root. I file di supporto (clamav-scan*, wazuh-enroll) li prende dalla cartella dello script
# oppure, se mancano, li scarica da --src-url (uso da init.sh / init-mvps.sh).
#
#  Installazione + registrazione (rollout manuale):
#    sudo bash install-host.sh --name <target-warpgate> --class A|C --group ovh|mvps|small
#  Solo installazione, registrazione dopo con 'sudo wazuh-enroll <nome> <gruppo>' (init.sh):
#    sudo bash install-host.sh --no-enroll --class auto [--src-url <base>] [--steps-file <file>]
#
#  Opzioni: --manager (default wazuh-agent.mexage.net)  --version (default 4.14.9, = versione del manager)
#  --class auto: A (ClamAV) se la RAM totale è >= 3000 MB, altrimenti C (solo agent).
#
# La password di enrollment viene chiesta a prompt (oppure da WAZUH_REGISTRATION_PASSWORD
# nell'ambiente): mai come argomento, per non lasciarla nella history o in ps.
# Idempotente: se l'agent è già installato non lo reinstalla; i file della scansione vengono riallineati.
set -euo pipefail

AGENT_NAME="" CLASS="" GROUP="" MANAGER="wazuh-agent.mexage.net" WAZUH_VER="4.14.9"
NO_ENROLL=0 SRC_URL="" STEPS_FILE=""
SRC="$(cd "$(dirname "$0")" && pwd)"
CLASS_A_MIN_MB=3000

die() { echo "ERRORE: $*" >&2; exit 1; }
log() { echo "==> $*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --name) AGENT_NAME="$2"; shift 2 ;;
    --class) CLASS="$2"; shift 2 ;;
    --group) GROUP="$2"; shift 2 ;;
    --manager) MANAGER="$2"; shift 2 ;;
    --version) WAZUH_VER="$2"; shift 2 ;;
    --no-enroll) NO_ENROLL=1; shift ;;
    --src-url) SRC_URL="${2%/}"; shift 2 ;;
    --steps-file) STEPS_FILE="$2"; shift 2 ;;
    *) die "argomento sconosciuto: $1" ;;
  esac
done
[ "$(id -u)" -eq 0 ] || die "va eseguito come root"

MEM_MB=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo)
if [ "$CLASS" = auto ]; then
  if [ "$MEM_MB" -ge "$CLASS_A_MIN_MB" ]; then CLASS=A; else CLASS=C; fi
fi
case "$CLASS" in A|C) ;; *) die "--class deve essere A, C o auto" ;; esac
if [ "$NO_ENROLL" -eq 0 ]; then
  [ -n "$AGENT_NAME" ] || die "--name obbligatorio (nome del target Warpgate: molti host MVPS hanno hostname 'vps')"
  case "$GROUP" in ovh|mvps|small) ;; *) die "--group deve essere ovh, mvps o small" ;; esac
  [ "$CLASS" = C ] && [ "$GROUP" != small ] && die "classe C va nel gruppo small"
  [ "$CLASS" = A ] && [ "$GROUP" = small ] && die "il gruppo small è solo per la classe C"
fi

# /etc/os-release definisce anche NAME e VERSION: lo leggo in una subshell per non sovrascrivere nulla
OS_IDS=$(. /etc/os-release; echo " ${ID:-} ${ID_LIKE:-} ")
OS_PRETTY=$(. /etc/os-release; echo "${PRETTY_NAME:-?}")
case "$OS_IDS" in
  *" debian "*|*" ubuntu "*) FAMILY=debian ;;
  *" rhel "*|*" fedora "*|*" centos "*) FAMILY=rhel ;;
  *) die "distribuzione non supportata: $OS_PRETTY" ;;
esac
if [ "$NO_ENROLL" -eq 1 ]; then
  log "$OS_PRETTY ($FAMILY), RAM ${MEM_MB} MB → classe $CLASS, Wazuh $WAZUH_VER (installazione senza registrazione)"
else
  log "host $AGENT_NAME ($OS_PRETTY, $FAMILY), classe $CLASS, gruppo $GROUP, manager $MANAGER, Wazuh $WAZUH_VER"
fi

# file di supporto: dalla cartella dello script, altrimenti da --src-url
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fetch() { # nome -> stampa il percorso del file
  if [ -f "$SRC/$1" ]; then echo "$SRC/$1"; return; fi
  [ -n "$SRC_URL" ] || die "manca $SRC/$1 (e nessun --src-url)"
  curl -fsSL "$SRC_URL/$1" -o "$TMP/$1" || die "download fallito: $SRC_URL/$1"
  echo "$TMP/$1"
}

# --- 1. ClamAV + scansione (solo classe A) ----------------------------------------------------
if [ "$CLASS" = A ]; then
  F_SCAN=$(fetch clamav-scan); F_SVC=$(fetch clamav-scan.service)
  F_TIMER=$(fetch clamav-scan.timer); F_ROT=$(fetch clamav-scan.logrotate)
  if [ "$FAMILY" = debian ]; then
    log "installo clamav + clamav-freshclam"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq clamav clamav-freshclam >/dev/null
    FC=/etc/clamav/freshclam.conf
  else
    log "installo clamav + clamav-update (EPEL)"
    dnf install -y -q epel-release >/dev/null
    dnf install -y -q clamav clamav-update >/dev/null
    FC=/etc/freshclam.conf
    sed -i 's/^Example/#Example/' "$FC"
  fi
  FCSVC=clamav-freshclam.service
  # log di freshclam in un percorso unico su tutte le famiglie (letto da Wazuh, regola 100103)
  mkdir -p /var/log/clamav
  if grep -qE '^#?UpdateLogFile' "$FC"; then
    sed -i -E 's|^#?UpdateLogFile.*|UpdateLogFile /var/log/clamav/freshclam.log|' "$FC"
  else
    echo "UpdateLogFile /var/log/clamav/freshclam.log" >> "$FC"
  fi
  FCUSER=$(awk '/^DatabaseOwner/{print $2}' "$FC"); FCUSER=${FCUSER:-$( [ "$FAMILY" = debian ] && echo clamav || echo clamupdate )}
  touch /var/log/clamav/freshclam.log && chown "$FCUSER" /var/log/clamav /var/log/clamav/freshclam.log
  systemctl enable "$FCSVC" >/dev/null 2>&1 || true
  systemctl restart "$FCSVC" 2>/dev/null || true
  log "attendo le firme (max 5 min)"
  for _ in $(seq 60); do ls /var/lib/clamav/daily.* >/dev/null 2>&1 && break; sleep 5; done
  ls /var/lib/clamav/daily.* >/dev/null 2>&1 || die "firme non scaricate: controlla /var/log/clamav/freshclam.log"

  install -m 0755 -o root -g root "$F_SCAN" /usr/local/bin/clamav-scan
  install -m 0644 -o root -g root "$F_SVC" /etc/systemd/system/clamav-scan.service
  install -m 0644 -o root -g root "$F_TIMER" /etc/systemd/system/clamav-scan.timer
  install -m 0644 -o root -g root "$F_ROT" /etc/logrotate.d/clamav-scan
  install -d -m 0750 -o root -g root /var/log/clamav-scan
  touch /var/log/clamav-scan/events.log && chmod 0640 /var/log/clamav-scan/events.log
  systemctl daemon-reload
  systemctl enable --now clamav-scan.timer >/dev/null
  log "ClamAV pronto: $(clamscan --version)"
fi

# --- 2. Agent Wazuh -------------------------------------------------------------------------
install -m 0755 -o root -g root "$(fetch wazuh-enroll)" /usr/local/sbin/wazuh-enroll

agent_installed() {
  if [ "$FAMILY" = debian ]; then dpkg -s wazuh-agent >/dev/null 2>&1; else rpm -q wazuh-agent >/dev/null 2>&1; fi
}
if agent_installed; then
  log "wazuh-agent già installato: non lo reinstallo"
else
  if [ "$NO_ENROLL" -eq 0 ]; then
    if [ -z "${WAZUH_REGISTRATION_PASSWORD:-}" ]; then
      read -rsp "Password di enrollment Wazuh: " WAZUH_REGISTRATION_PASSWORD; echo
    fi
    [ -n "$WAZUH_REGISTRATION_PASSWORD" ] || die "password di enrollment vuota"
    # le variabili WAZUH_* lette dal pacchetto al momento dell'installazione fanno la registrazione
    export WAZUH_MANAGER="$MANAGER" WAZUH_REGISTRATION_SERVER="$MANAGER" WAZUH_AGENT_NAME="$AGENT_NAME" \
           WAZUH_AGENT_GROUP="$GROUP" WAZUH_REGISTRATION_PASSWORD
  fi
  if [ "$FAMILY" = debian ]; then
    log "repo Wazuh (apt) + wazuh-agent=$WAZUH_VER-1"
    command -v gpg >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gnupg >/dev/null
    curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --dearmor --yes -o /usr/share/keyrings/wazuh.gpg
    chmod 644 /usr/share/keyrings/wazuh.gpg
    echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" > /etc/apt/sources.list.d/wazuh.list
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "wazuh-agent=$WAZUH_VER-1" >/dev/null
    apt-mark hold wazuh-agent >/dev/null
    # repo disattivato: l'agent si aggiorna solo a mano, insieme al manager
    sed -i 's/^deb /#deb /' /etc/apt/sources.list.d/wazuh.list
  else
    log "repo Wazuh (dnf) + wazuh-agent-$WAZUH_VER-1"
    rpm --import https://packages.wazuh.com/key/GPG-KEY-WAZUH
    cat > /etc/yum.repos.d/wazuh.repo <<'EOF'
[wazuh]
gpgcheck=1
gpgkey=https://packages.wazuh.com/key/GPG-KEY-WAZUH
enabled=1
name=EL-$releasever - Wazuh
baseurl=https://packages.wazuh.com/4.x/yum/
protect=1
EOF
    dnf install -y -q "wazuh-agent-$WAZUH_VER-1" >/dev/null
    sed -i 's/^enabled=1/enabled=0/' /etc/yum.repos.d/wazuh.repo
  fi
  unset WAZUH_REGISTRATION_PASSWORD
fi

if [ "$CLASS" = A ]; then GROUP_HINT="ovh (macchina OVH) oppure mvps (macchina MVPS)"; else GROUP_HINT="small (host senza ClamAV)"; fi
STEPS="WAZUH / CLAMAV - passi per completare la configurazione
  Stato: ClamAV $( [ "$CLASS" = A ] && echo "installato, scansione settimanale domenica notte" || echo "NON installato (RAM ${MEM_MB} MB < ${CLASS_A_MIN_MB}: classe C)" ); agent Wazuh $WAZUH_VER installato.
  1. Registra l'agent sul manager (password di enrollment in Vaultwarden, 'Wazuh enrollment'):
       sudo wazuh-enroll <nome-target-warpgate> <gruppo>
     gruppo: $GROUP_HINT
  2. Controlla che l'agent risulti attivo su https://wazuh.mexage.net
$( [ "$CLASS" = A ] && echo "  3. (facoltativo) prova la scansione su una cartella piccola: sudo /usr/local/bin/clamav-scan /tmp
     poi: tail -2 /var/log/clamav-scan/events.log" )"

if [ "$NO_ENROLL" -eq 1 ]; then
  log "agent installato ma NON registrato e NON avviato: vedi i passi qui sotto"
  [ -n "$STEPS_FILE" ] && printf '%s\n' "$STEPS" > "$STEPS_FILE"
  printf '\n%s\n' "$STEPS"
else
  systemctl daemon-reload
  systemctl enable --now wazuh-agent >/dev/null
  sleep 10
  log "wazuh-agent: $(systemctl is-active wazuh-agent)"
  grep -E "Connected to the server|Valid key received|ERROR" /var/ossec/logs/ossec.log | tail -3 || true
fi
log "fatto"
