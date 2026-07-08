#!/usr/bin/env bash
#
# init.sh — bootstrap di una Ubuntu barebone appena installata.
#
# Cosa fa (in ordine):
#   1. Chiede interattivamente il nuovo hostname e lo imposta.
#   2. Installa i pacchetti prerequisiti (unattended).
#   3. Crea l'utente target 'mexage' (se manca) con sudo e password.
#   4. Inserisce le chiavi pubbliche SSH in authorized_keys di 'mexage'.
#   5. Hardening SSH: disabilita password auth e login di root.
#   6. Carica i moduli kernel per il networking rootless.
#   7. Installa Docker in modalità rootless PER 'mexage'.
#   8. Abilita l'avvio del daemon rootless al boot (systemd --user + linger).
#   9. Installa e collega il Synology Active Backup for Business Agent.
#  10. Crea le cartelle di lavoro di mexage e imposta le project quota (ext4).
#
# Va lanciato COME ROOT (o via sudo) perché può dover creare l'utente:
#   sudo bash -c "$(curl -fsSL <URL> | tr -d '\r')"
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configurazione.
# ---------------------------------------------------------------------------
# Versione di questo script (riportata anche nel README.txt generato).
SCRIPT_VERSION="1.2.0"

# Base URL raw del repo da cui scaricare gli asset (README.txt, server-manager.sh).
ASSETS_BASE="https://raw.githubusercontent.com/IacopoSb/init-cloud-machine/main"

# Utente target: riceve Docker rootless e l'accesso SSH via chiave.
TARGET_USER="mexage"

# Chiavi pubbliche SSH da autorizzare per TARGET_USER (una per riga).
SSH_PUBLIC_KEYS=(
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGF1zvqfiPqcP5sXTOHj5yxcybA00aoxiRXG/xurU3q6 warpgate"
)

# ---------------------------------------------------------------------------
# Helper di logging.
# ---------------------------------------------------------------------------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. Guard iniziali.
# ---------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "Questo script va eseguito come root (crea/configura l'utente '$TARGET_USER'). Rilancialo con: sudo bash ..."

# Verifica che ci sia almeno una chiave: senza chiavi disabilitare la password
# significherebbe restare tagliati fuori.
[ "${#SSH_PUBLIC_KEYS[@]}" -gt 0 ] || die "Nessuna chiave SSH configurata in SSH_PUBLIC_KEYS: mi rifiuto di disabilitare l'auth via password (rischio lockout)."

# ---------------------------------------------------------------------------
# 0b. Rilevamento distribuzione + astrazione pacchetti.
# ---------------------------------------------------------------------------
# Le parti base (utente, hardening SSH, cartelle, README) girano su Debian/Ubuntu
# e RHEL/AlmaLinux. Le parti Docker/quota/Beszel/Synology restano Debian-only e
# vengono saltate sulle altre distribuzioni.
[ -r /etc/os-release ] || die "/etc/os-release assente: distribuzione non riconoscibile."
. /etc/os-release
case "${ID:-}" in
  ubuntu|debian) DISTRO_FAMILY="debian" ;;
  almalinux|rocky|rhel|centos|fedora) DISTRO_FAMILY="rhel" ;;
  *)
    case " ${ID_LIKE:-} " in
      *debian*) DISTRO_FAMILY="debian" ;;
      *rhel*|*fedora*) DISTRO_FAMILY="rhel" ;;
      *) die "Distribuzione non supportata: '${ID:-?}' (attese Debian/Ubuntu o RHEL/AlmaLinux)." ;;
    esac ;;
esac

# Gruppo admin: 'sudo' su Debian/Ubuntu, 'wheel' su RHEL/AlmaLinux.
if [ "$DISTRO_FAMILY" = "debian" ]; then ADMIN_GROUP="sudo"; else ADMIN_GROUP="wheel"; fi

# Installazione pacchetti astratta per famiglia.
pkg_refresh() {
  if [ "$DISTRO_FAMILY" = "debian" ]; then apt-get update -y; else dnf -y makecache || true; fi
}
pkg_install() {
  if [ "$DISTRO_FAMILY" = "debian" ]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
  else
    dnf install -y "$@"
  fi
}

log "Bootstrap avviato. Distribuzione: ${PRETTY_NAME:-$ID} (famiglia $DISTRO_FAMILY). Utente target: '$TARGET_USER'."

# ---------------------------------------------------------------------------
# 1. Hostname interattivo.
# ---------------------------------------------------------------------------
CURRENT_HOSTNAME="$(hostname)"
read -rp "Nuovo hostname [$CURRENT_HOSTNAME]: " NEW_HOSTNAME
NEW_HOSTNAME="${NEW_HOSTNAME:-$CURRENT_HOSTNAME}"

# Validazione basilare del formato hostname (RFC 1123: lettere, cifre, trattini).
if ! printf '%s' "$NEW_HOSTNAME" | grep -Eq '^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$'; then
  die "Hostname '$NEW_HOSTNAME' non valido (ammessi lettere, cifre e trattini, max 63 caratteri, no trattino iniziale/finale)."
fi

if [ "$NEW_HOSTNAME" != "$CURRENT_HOSTNAME" ]; then
  log "Imposto l'hostname a '$NEW_HOSTNAME'."
  hostnamectl set-hostname "$NEW_HOSTNAME"

  # Aggiorna/crea la riga 127.0.1.1 in /etc/hosts (idempotente).
  if grep -qE '^127\.0\.1\.1' /etc/hosts; then
    sed -i -E "s/^(127\.0\.1\.1)\s+.*/\1\t$NEW_HOSTNAME/" /etc/hosts
  else
    printf '127.0.1.1\t%s\n' "$NEW_HOSTNAME" >> /etc/hosts
  fi
else
  log "Hostname invariato ('$CURRENT_HOSTNAME')."
fi

# ---------------------------------------------------------------------------
# 2. Pacchetti prerequisiti (unattended).
# ---------------------------------------------------------------------------
log "Installo i pacchetti prerequisiti di base..."
pkg_refresh
pkg_install ca-certificates curl sudo

# ---------------------------------------------------------------------------
# 3. Utente target.
# ---------------------------------------------------------------------------
if id "$TARGET_USER" >/dev/null 2>&1; then
  log "Utente '$TARGET_USER' già esistente: non tocco account né password."
else
  log "Creo l'utente '$TARGET_USER' con home e shell bash."
  useradd --create-home --shell /bin/bash "$TARGET_USER"
  usermod -aG "$ADMIN_GROUP" "$TARGET_USER"

  # sudo con password (niente NOPASSWD): imposto subito la password, richiesta
  # da sudo. L'accesso SSH resta comunque solo-a-chiave. Prompt con conferma.
  log "Imposta la password per '$TARGET_USER' (serve per sudo; SSH resta solo-a-chiave)."
  if ! passwd "$TARGET_USER"; then
    warn "Password non impostata: fallo a mano con 'passwd $TARGET_USER'. Senza password '$TARGET_USER' non potrà usare sudo."
  fi
  log "Utente '$TARGET_USER' creato (gruppo '$ADMIN_GROUP', con password)."
fi

# Dati dell'utente target usati nel resto dello script.
TARGET_UID="$(id -u "$TARGET_USER")"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[ -n "$TARGET_HOME" ] && [ -d "$TARGET_HOME" ] || die "Home dell'utente '$TARGET_USER' non trovata."

# subuid/subgid: indispensabili al rootless. useradd di norma li crea; se
# mancano (utente pre-esistente atipico) li aggiungiamo.
grep -q "^${TARGET_USER}:" /etc/subuid || usermod --add-subuids 100000-165535 "$TARGET_USER"
grep -q "^${TARGET_USER}:" /etc/subgid || usermod --add-subgids 100000-165535 "$TARGET_USER"

# Motore container per famiglia: Docker (Debian/Ubuntu) o Podman (RHEL/AlmaLinux).
# CONTAINER_SOCK è il socket Docker-API (Podman ne espone uno compatibile).
if [ "$DISTRO_FAMILY" = "debian" ]; then
  CONTAINER_ENGINE="docker"
  CONTAINER_SOCK="/run/user/$TARGET_UID/docker.sock"
  COMPOSE_CMD="docker compose"
else
  CONTAINER_ENGINE="podman"
  CONTAINER_SOCK="/run/user/$TARGET_UID/podman/podman.sock"
  COMPOSE_CMD="podman compose"
fi

# Esegue un comando come TARGET_USER con l'ambiente systemd --user corretto.
run_as_target() {
  sudo -u "$TARGET_USER" \
    HOME="$TARGET_HOME" \
    XDG_RUNTIME_DIR="/run/user/$TARGET_UID" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$TARGET_UID/bus" \
    DOCKER_HOST="unix://$CONTAINER_SOCK" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    "$@"
}

# ---------------------------------------------------------------------------
# Beszel agent (condiviso Docker/Podman): compose in ~/apps/beszel, modalità
# WebSocket. Usa CONTAINER_SOCK e COMPOSE_CMD del motore attivo.
# ---------------------------------------------------------------------------
setup_beszel() {
  local dir="$TARGET_HOME/apps/beszel"
  mkdir -p "$dir"
  log "Configuro l'agent Beszel (vuoto = scrivo il compose senza avviarlo)."
  read -rp "  Beszel HUB_URL [https://status.mexage.net]: " BESZEL_HUB_URL
  BESZEL_HUB_URL="${BESZEL_HUB_URL:-https://status.mexage.net}"
  read -rp "  Beszel TOKEN: " BESZEL_TOKEN
  read -rp "  Beszel KEY (chiave pubblica hub, ssh-ed25519 ...): " BESZEL_KEY

  cat > "$dir/docker-compose.yml" <<EOF
services:
  beszel-agent:
    image: docker.io/henrygd/beszel-agent
    container_name: beszel-agent
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./beszel_agent_data:/var/lib/beszel-agent
      - $CONTAINER_SOCK:/var/run/docker.sock:ro
    environment:
      LISTEN: 45876
      HUB_URL: "${BESZEL_HUB_URL}"
      TOKEN: "${BESZEL_TOKEN}"
      KEY: "${BESZEL_KEY}"
EOF
  chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/apps"

  if [ -n "$BESZEL_HUB_URL" ] && [ -n "$BESZEL_TOKEN" ] && [ -n "$BESZEL_KEY" ]; then
    log "Avvio l'agent Beszel ($COMPOSE_CMD up -d)."
    if run_as_target $COMPOSE_CMD -f "$dir/docker-compose.yml" up -d; then
      BESZEL_STATUS="agent avviato ($dir, $CONTAINER_ENGINE)"
      log "Agent Beszel avviato."
    else
      BESZEL_STATUS="avvio FALLITO — vedi '$COMPOSE_CMD -f $dir/docker-compose.yml logs'"
      warn "Avvio dell'agent Beszel fallito."
    fi
  else
    BESZEL_STATUS="compose scritto con placeholder — completa e avvia in $dir"
    warn "Dati Beszel incompleti: compose scritto in $dir con i campi vuoti."
    warn "Completa HUB_URL/TOKEN/KEY nel file e avvia con: cd $dir && $COMPOSE_CMD up -d"
  fi
}

# ---------------------------------------------------------------------------
# 4. Chiavi SSH in authorized_keys di TARGET_USER.
# ---------------------------------------------------------------------------
log "Configuro authorized_keys per '$TARGET_USER'."
SSH_DIR="$TARGET_HOME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

mkdir -p "$SSH_DIR"
touch "$AUTH_KEYS"

for key in "${SSH_PUBLIC_KEYS[@]}"; do
  # Append idempotente: aggiungo solo se la chiave non è già presente.
  if grep -qxF "$key" "$AUTH_KEYS"; then
    log "Chiave già presente, salto: ${key%% *} ...${key##* }"
  else
    printf '%s\n' "$key" >> "$AUTH_KEYS"
    log "Chiave aggiunta: ${key%% *} ...${key##* }"
  fi
done

# Proprietà e permessi corretti (il file è stato creato da root).
chown -R "$TARGET_USER:$TARGET_USER" "$SSH_DIR"
chmod 700 "$SSH_DIR"
chmod 600 "$AUTH_KEYS"

# ---------------------------------------------------------------------------
# 5. Hardening SSH.
# ---------------------------------------------------------------------------
# In sshd VINCE IL PRIMO valore letto per ogni direttiva. Il main sshd_config
# fa 'Include /etc/ssh/sshd_config.d/*.conf' in cima e i file sono letti in
# ordine alfanumerico: usiamo '00-' per battere eventuali 50-cloud-init.conf.
HARDENING_CONF="/etc/ssh/sshd_config.d/00-hardening.conf"
log "Scrivo la configurazione di hardening SSH in $HARDENING_CONF."
tee "$HARDENING_CONF" >/dev/null <<'EOF'
# Gestito da init.sh — hardening accesso SSH.
PasswordAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
EOF
chmod 644 "$HARDENING_CONF"

# Valida la configurazione PRIMA di riavviare: se sshd -t fallisce, rimuovo il
# drop-in per non lasciare il servizio in uno stato non riavviabile.
log "Valido la configurazione sshd..."
if ! sshd -t; then
  rm -f "$HARDENING_CONF"
  die "sshd -t ha fallito: config di hardening rimossa, nessun riavvio eseguito. SSH è rimasto invariato."
fi

# Nome del servizio ssh (ssh su Debian/Ubuntu; fallback a sshd).
SSH_SERVICE="ssh"
systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service' || SSH_SERVICE="sshd"

log "Riavvio $SSH_SERVICE per applicare l'hardening."
systemctl restart "$SSH_SERVICE"

# ---------------------------------------------------------------------------
# 5b. Cartelle di lavoro dell'utente (tutte le distribuzioni).
# ---------------------------------------------------------------------------
log "Creo le cartelle di lavoro in $TARGET_HOME."
for d in apps data logs backup; do
  mkdir -p "$TARGET_HOME/$d"
done
chown -R "$TARGET_USER:$TARGET_USER" \
  "$TARGET_HOME/apps" "$TARGET_HOME/data" "$TARGET_HOME/logs" "$TARGET_HOME/backup"

# Default per il riepilogo (sovrascritti dalle sezioni Debian-only qui sotto).
DOCKER_SUMMARY="non installato (solo Debian/Ubuntu in questa versione)"
SYNO_STATUS="non applicabile su $ID"
BESZEL_STATUS="non applicabile su $ID"
QUOTA_SUMMARY="non applicabile su $ID"
QUOTA_REBOOT=0

# ===========================================================================
# Sezioni Docker / quota / Beszel / Synology: SOLO Debian/Ubuntu (v1.1.0).
# Su RHEL/AlmaLinux vengono saltate (gestione futura, es. Podman).
# ===========================================================================
if [ "$DISTRO_FAMILY" = "debian" ]; then
pkg_install uidmap dbus-user-session slirp4netns

# ---------------------------------------------------------------------------
# 6. Moduli kernel per il networking rootless (iptables/nftables).
# ---------------------------------------------------------------------------
# Docker rootless usa iptables per pubblicare le porte. A seconda del kernel e
# del backend (le Ubuntu recenti usano nftables via iptables-nft) l'installer
# richiede nf_tables e/o ip_tables. Proviamo a caricarli tutti, persistiamo
# quelli riusciti al boot, e ripieghiamo su SKIP_IPTABLES=1 solo se non ne
# carica nessuno (port-forwarding limitato).
log "Carico i moduli kernel per il networking rootless (nf_tables, ip_tables)."
SKIP_IPTABLES_ENV=""
MODULES_CONF="/etc/modules-load.d/docker-rootless.conf"
loaded_any=0
rm -f "$MODULES_CONF"
for mod in nf_tables ip_tables ip6_tables; do
  if modprobe "$mod" 2>/dev/null; then
    echo "$mod" >> "$MODULES_CONF"
    loaded_any=1
  fi
done
if [ "$loaded_any" -eq 0 ]; then
  rm -f "$MODULES_CONF"
  warn "Nessun modulo iptables/nftables caricabile (kernel senza i moduli?)."
  warn "Installo Docker rootless con SKIP_IPTABLES=1: il port-forwarding potrebbe essere limitato."
  SKIP_IPTABLES_ENV="SKIP_IPTABLES=1"
fi

# ---------------------------------------------------------------------------
# 6b. User namespaces per il rootless (Ubuntu 23.10+) — definizione funzione.
# ---------------------------------------------------------------------------
# Da Ubuntu 23.10 gli unprivileged user namespaces sono ristretti via AppArmor
# (kernel.apparmor_restrict_unprivileged_userns=1): rootlesskit fallisce con
# "fork/exec /proc/self/exe: permission denied". Il profilo AppArmor mirato per
# rootlesskit si è rivelato inaffidabile sulle Ubuntu recenti, quindi
# disabilitiamo la restrizione a livello di sysctl (in modo persistente): i
# container rootless hanno comunque bisogno degli user namespace.
# NOTA: riduce leggermente l'hardening (userns non privilegiati permessi a
# tutti, com'era prima della 23.10) — accettabile su un host per container.
ensure_userns_allowed() {
  local key="kernel.apparmor_restrict_unprivileged_userns"
  [ -e "/proc/sys/kernel/apparmor_restrict_unprivileged_userns" ] || return 0
  [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)" = "1" ] || return 0
  log "Disabilito la restrizione AppArmor sugli unprivileged user namespaces (serve al rootless)."
  echo "$key = 0" > /etc/sysctl.d/99-rootless-userns.conf
  sysctl -w "$key=0" >/dev/null 2>&1 \
    || warn "Impossibile disabilitare $key a caldo; sarà attivo al prossimo boot."
}

# ---------------------------------------------------------------------------
# 7. Docker rootless per TARGET_USER.
# ---------------------------------------------------------------------------
# Abilita il linger PRIMA: crea /run/user/$TARGET_UID e avvia user@.service,
# così systemctl --user (usato dall'installer) funziona senza login attivo.
log "Abilito il linger per '$TARGET_USER'."
loginctl enable-linger "$TARGET_USER"

# Attende che la runtime dir dell'utente sia pronta (creata dal linger).
for _ in $(seq 1 10); do
  [ -d "/run/user/$TARGET_UID" ] && break
  sleep 1
done
[ -d "/run/user/$TARGET_UID" ] || warn "/run/user/$TARGET_UID non ancora presente: l'installer potrebbe non configurare il servizio (verrà comunque avviato al boot)."

DOCKER_SOCK="unix:///run/user/$TARGET_UID/docker.sock"

# Docker CE a livello di SISTEMA (binari in /usr/bin), poi rootless per l'utente.
if ! command -v dockerd >/dev/null 2>&1; then
  log "Installo Docker CE (system-wide) tramite lo script ufficiale."
  curl -fsSL https://get.docker.com | sh
fi
# rootless-extras fornisce dockerd-rootless-setuptool.sh e /usr/bin/rootlesskit.
apt-get install -y docker-ce-rootless-extras uidmap >/dev/null 2>&1 || true
# Il daemon rootful di sistema non ci serve: usiamo solo il rootless dell'utente.
systemctl disable --now docker.service docker.socket >/dev/null 2>&1 || true

# Config del daemon rootless: driver di log 'local' con rotazione, così i log
# dei container non crescono all'infinito (max ~50 MB per container).
DOCKER_CFG_DIR="$TARGET_HOME/.config/docker"
mkdir -p "$DOCKER_CFG_DIR"
cat > "$DOCKER_CFG_DIR/daemon.json" <<'EOF'
{
  "log-driver": "local",
  "log-opts": {
    "max-size": "10m",
    "max-file": "5"
  }
}
EOF
chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.config"

SKIP_ARG=""
[ -n "${SKIP_IPTABLES_ENV:-}" ] && SKIP_ARG="--skip-iptables"
if [ -S "/run/user/$TARGET_UID/docker.sock" ]; then
  log "Docker rootless già configurato per '$TARGET_USER', salto il setup."
else
  # Permetti gli unprivileged user namespaces (necessari a rootlesskit).
  ensure_userns_allowed
  log "Configuro Docker rootless per '$TARGET_USER' con i binari di sistema."
  run_as_target dockerd-rootless-setuptool.sh install $SKIP_ARG \
    || warn "Setup rootless non completato ora; riprovabile con 'dockerd-rootless-setuptool.sh install'."
fi

# Env per l'utente: solo DOCKER_HOST (i binari sono di sistema in /usr/bin).
BASHRC="$TARGET_HOME/.bashrc"
add_line_once() {
  # add_line_once <file> <riga>
  local file="$1" line="$2"
  grep -qxF "$line" "$file" 2>/dev/null || printf '%s\n' "$line" >> "$file"
}

log "Aggiorno l'ambiente in $BASHRC (DOCKER_HOST)."
touch "$BASHRC"
add_line_once "$BASHRC" "# --- Docker rootless (init.sh) ---"
add_line_once "$BASHRC" "export DOCKER_HOST=$DOCKER_SOCK"
chown "$TARGET_USER:$TARGET_USER" "$BASHRC"

# ---------------------------------------------------------------------------
# 8. Avvio del daemon rootless al boot.
# ---------------------------------------------------------------------------
log "Abilito e avvio il servizio docker rootless (systemd --user di '$TARGET_USER')."
if run_as_target systemctl --user enable --now docker 2>/dev/null; then
  log "Servizio docker rootless attivo per '$TARGET_USER'."
else
  warn "Non sono riuscito ad avviare 'docker' via systemd --user adesso."
  warn "Verrà avviato automaticamente al prossimo login/boot grazie a enable-linger."
fi

# Il plugin 'docker compose' arriva dal pacchetto di sistema docker-compose-plugin
# (installato con Docker CE) ed è disponibile anche al CLI rootless.
run_as_target docker compose version >/dev/null 2>&1 \
  || warn "'docker compose' non disponibile: verifica il pacchetto docker-compose-plugin."

DOCKER_SUMMARY="rootless per $TARGET_USER, DOCKER_HOST=$DOCKER_SOCK"

# ---------------------------------------------------------------------------
# 9. Synology Active Backup for Business Agent.
# ---------------------------------------------------------------------------
# L'archivio .zip contiene install.run + il .deb. Lo scarichiamo, estraiamo ed
# eseguiamo install.run come root (installa il servizio + il driver kernel
# synosnap). Il collegamento al NAS è interattivo (abb-cli -c) più sotto.
SYNO_AGENT_URL="https://global.synologydownload.com/download/Utility/ActiveBackupBusinessAgent/3.2.0-5053/Linux/x86_64/Synology%20Active%20Backup%20for%20Business%20Agent-3.2.0-5053-x64-deb.zip"

install_synology_agent() {
  log "Scarico e installo il Synology Active Backup for Business Agent."
  apt-get install -y unzip

  local workdir zip installer rc=0
  workdir="$(mktemp -d)"
  zip="$workdir/abb-agent.zip"

  if ! curl -fsSL "$SYNO_AGENT_URL" -o "$zip"; then
    warn "Download dell'agent Synology fallito."
    rm -rf "$workdir"
    return 1
  fi

  unzip -q -o "$zip" -d "$workdir"

  # install.run è in una sottocartella dell'archivio.
  installer="$(find "$workdir" -maxdepth 2 -name 'install.run' -type f | head -n1)"
  if [ -z "$installer" ]; then
    warn "install.run non trovato nell'archivio Synology: struttura inattesa."
    rm -rf "$workdir"
    return 1
  fi

  chmod +x "$installer"
  # install.run si aspetta il .deb accanto a sé: eseguo dalla sua cartella.
  ( cd "$(dirname "$installer")" && ./install.run ) || rc=$?
  rm -rf "$workdir"
  return $rc
}

# Fallback: su kernel recenti (6.15+) il driver synosnap ufficiale non compila.
# Usiamo la patch community Peppershade/abb-linux-agent: scarica l'installer
# UFFICIALE, applica le patch al sorgente di synosnap e ri-pacchettizza un
# install.run compilabile via DKMS. È software di terze parti (l'utente ha
# scelto esplicitamente questo fallback). Richiede Secure Boot disabilitato.
install_synology_agent_patched() {
  log "Fallback: costruisco l'installer Synology patchato (Peppershade) e installo."
  apt-get install -y git unzip dpkg tar gzip perl

  local workdir zip official patched rc=0
  workdir="$(mktemp -d)"
  zip="$workdir/abb-agent.zip"

  # Pulisco un'eventuale installazione parziale del driver dall'installer ufficiale.
  dpkg --purge --force-all synosnap >/dev/null 2>&1 || true

  # 1) Installer ufficiale (sorgente da patchare).
  if ! curl -fsSL "$SYNO_AGENT_URL" -o "$zip"; then
    warn "Download dell'installer ufficiale (per la patch) fallito."
    rm -rf "$workdir"; return 1
  fi
  unzip -q -o "$zip" -d "$workdir"
  official="$(find "$workdir" -maxdepth 2 -name 'install.run' -type f | head -n1)"
  if [ -z "$official" ]; then
    warn "install.run ufficiale non trovato per la patch."
    rm -rf "$workdir"; return 1
  fi

  # 2) Repo della patch.
  if ! git clone --depth 1 https://github.com/Peppershade/abb-linux-agent.git "$workdir/patch"; then
    warn "Clone del repo della patch fallito."
    rm -rf "$workdir"; return 1
  fi

  # 3) Build: produce l'install.run patchato nella cwd (la dir della repo).
  ( cd "$workdir/patch" && bash build-tools/build.sh "$official" ) || rc=$?
  if [ "$rc" -ne 0 ]; then
    warn "Build dell'installer patchato fallita."
    rm -rf "$workdir"; return 1
  fi
  patched="$(find "$workdir/patch" -maxdepth 1 -name 'install.run' -type f | head -n1)"
  if [ -z "$patched" ]; then
    warn "Installer patchato non trovato dopo la build."
    rm -rf "$workdir"; return 1
  fi

  # 4) Installo l'installer patchato.
  ( cd "$(dirname "$patched")" && bash "$patched" ) || rc=$?
  rm -rf "$workdir"
  return $rc
}

SYNO_OK=0
SYNO_SKIPPED=0
# Scelta interattiva: l'agent (physical server) serve al backup a livello di
# sistema e richiede il driver kernel synosnap. Per il solo backup di una
# cartella (es. ./data) conviene la modalità File Server agentless (rsync/SMB)
# sul NAS, che non installa nulla qui. Default: NON installare.
read -rp "Installare l'agent Synology ABB (physical server, richiede synosnap)? [y/N]: " SYNO_ANS
case "${SYNO_ANS:-N}" in
  [yY]|[yY][eE][sS])
    if command -v abb-cli >/dev/null 2>&1; then
      log "Agent Synology già installato, salto l'installazione."
      SYNO_OK=1
    elif install_synology_agent; then
      SYNO_OK=1
    else
      warn "Installer ufficiale fallito (su kernel recenti synosnap non compila: limite noto)."
      warn "Provo il fallback con la patch community (Peppershade/abb-linux-agent)."
      if install_synology_agent_patched; then
        SYNO_OK=1
      else
        warn "Anche il fallback con la patch è fallito. Gestisci l'agent Synology a mano."
      fi
    fi
    # Collegamento interattivo al NAS (indirizzo + credenziali admin; nulla salvato).
    if [ "$SYNO_OK" -eq 1 ] && command -v abb-cli >/dev/null 2>&1; then
      log "Collego l'agent al NAS: inserisci indirizzo del NAS e credenziali admin quando richiesto."
      abb-cli -c || warn "Collegamento al NAS non completato. Rilancialo quando vuoi con: sudo abb-cli -c"
    fi
    ;;
  *)
    SYNO_SKIPPED=1
    log "Agent Synology NON installato (scelta)."
    log "Per il backup di '$TARGET_HOME/data' configura un task File Server (rsync/SMB) sul NAS."
    ;;
esac

if [ "$SYNO_SKIPPED" -eq 1 ]; then
  SYNO_STATUS="non installato (scelta) — usa File Server sul NAS"
elif [ "$SYNO_OK" -eq 1 ]; then
  SYNO_STATUS="installato (verifica: sudo abb-cli -s)"
else
  SYNO_STATUS="installazione FALLITA — riprova a mano"
fi

# ---------------------------------------------------------------------------
# 10. Project quota ext4 (hard limit) sulle cartelle di lavoro.
# ---------------------------------------------------------------------------
# La quota (hard limit) viene chiesta interattivamente per tutte le cartelle
# (apps, data, logs, backup): vuoto = nessuna quota. Le cartelle sono già create
# (sezione 5b). Project quota ext4: niente modifiche a /etc/fstab.
pkg_install quota

QUOTA_MNT="$(findmnt -no TARGET --target "$TARGET_HOME")"
QUOTA_DEV="$(findmnt -no SOURCE --target "$TARGET_HOME")"
QUOTA_FSTYPE="$(findmnt -no FSTYPE --target "$TARGET_HOME")"

# Converte una taglia (20G / 500M / 1024K, default K) in blocchi da 1KiB.
size_to_kib() {
  local s="$1" num unit
  num="$(printf '%s' "$s" | sed -E 's/^([0-9]+).*/\1/')"
  unit="$(printf '%s' "$s" | sed -E 's/^[0-9]+([A-Za-z]?).*/\1/' | tr 'a-z' 'A-Z')"
  case "$unit" in
    K|"") echo "$num" ;;
    M) echo $(( num * 1024 )) ;;
    G) echo $(( num * 1024 * 1024 )) ;;
    T) echo $(( num * 1024 * 1024 * 1024 )) ;;
    *) echo "" ;;
  esac
}

# Test funzionale: la project quota è operativa se setquota (no-op su un projid
# alto e inutilizzato, limiti 0 = illimitato) va a buon fine.
quota_is_active() { setquota -P 2147483647 0 0 0 0 "$QUOTA_MNT" >/dev/null 2>&1; }

QUOTA_CONF_DIR="/etc/init-cloud-machine"
QUOTA_CONF="$QUOTA_CONF_DIR/quota.conf"

# Chiede le dimensioni di data/logs e le registra in QUOTA_CONF (projid kib mnt dir).
prompt_quota_sizes() {
  local projid=100 d qsize kib
  mkdir -p "$QUOTA_CONF_DIR"
  : > "$QUOTA_CONF"
  for d in apps data logs backup; do
    projid=$((projid + 1))
    read -rp "Quota per '$d' (es. 20G, 500M; vuoto = nessuna quota): " qsize
    [ -z "$qsize" ] && { log "Nessuna quota per '$d'."; continue; }
    kib="$(size_to_kib "$qsize")"
    [ -z "$kib" ] && { warn "Valore '$qsize' non valido per '$d' (usa K/M/G/T): salto."; continue; }
    printf '%s %s %s %s\n' "$projid" "$kib" "$QUOTA_MNT" "$TARGET_HOME/$d" >> "$QUOTA_CONF"
    log "Quota '$d' = $qsize (projid $projid) registrata."
  done
}

# Applica subito i limiti registrati in QUOTA_CONF (richiede quota già attiva).
apply_quota_conf() {
  local projid kib mnt dir
  [ -r "$QUOTA_CONF" ] || return 0
  while read -r projid kib mnt dir; do
    [ -n "$projid" ] || continue
    [ -d "$dir" ] || continue
    chattr -p "$projid" +P "$dir" >/dev/null 2>&1 || warn "chattr su '$dir' non riuscito."
    if setquota -P "$projid" 0 "$kib" 0 0 "$mnt" >/dev/null 2>&1; then
      log "Quota hard applicata a '$dir' (projid $projid, ${kib}KiB)."
    else
      warn "setquota fallito per '$dir'."
    fi
  done < "$QUOTA_CONF"
}

# Installa (dagli asset) il modulo dracut che abilita la feature quota su root al
# boot (offline: la feature non si abilita a caldo) + il servizio oneshot che
# applica i limiti al primo boot con quota attiva. Per Ubuntu con dracut.
setup_quota_boot() {
  local mod="/usr/lib/dracut/modules.d/99ext4quota" base="$ASSETS_BASE/assets/quota"
  mkdir -p "$mod"
  curl -fsSL "$base/dracut-module-setup.sh" -o "$mod/module-setup.sh" || { warn "download modulo dracut fallito."; return 1; }
  curl -fsSL "$base/dracut-ext4-quota.sh"   -o "$mod/ext4-quota.sh"   || { warn "download hook dracut fallito."; return 1; }
  chmod 0755 "$mod/module-setup.sh" "$mod/ext4-quota.sh"
  curl -fsSL "$base/apply-quota.sh" -o /usr/local/sbin/init-cloud-machine-apply-quota.sh || { warn "download apply-quota fallito."; return 1; }
  chmod 0755 /usr/local/sbin/init-cloud-machine-apply-quota.sh
  curl -fsSL "$base/init-cloud-machine-quota.service" -o /etc/systemd/system/init-cloud-machine-quota.service || { warn "download service fallito."; return 1; }
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable init-cloud-machine-quota.service >/dev/null 2>&1 || warn "enable del servizio quota fallito."
  update-initramfs -u >/dev/null 2>&1 || warn "update-initramfs (dracut) fallito."
}

if [ "$QUOTA_FSTYPE" != "ext4" ]; then
  warn "Filesystem di $TARGET_HOME è '$QUOTA_FSTYPE', non ext4: cartelle create ma project quota saltata."
  QUOTA_SUMMARY="saltata (fs '$QUOTA_FSTYPE' non ext4)"
elif quota_is_active; then
  log "Project quota già attiva su $QUOTA_MNT: chiedo e applico i limiti."
  prompt_quota_sizes
  apply_quota_conf
  QUOTA_SUMMARY="attive (verifica: sudo repquota -P $QUOTA_MNT)"
else
  # Feature quota non attiva: su ext4 si abilita solo da smontato → la abilitiamo
  # al boot (modulo dracut) e applichiamo i limiti al primo boot (servizio oneshot).
  log "Project quota non attiva: preparo l'abilitazione al boot (dracut) e l'applicazione automatica."
  prompt_quota_sizes
  if setup_quota_boot; then
    QUOTA_REBOOT=1
    QUOTA_SUMMARY="configurata, applicata automaticamente al prossimo REBOOT"
  else
    warn "Preparazione della quota al boot non riuscita: le quote non verranno applicate."
    QUOTA_SUMMARY="preparazione FALLITA"
  fi
fi

# ---------------------------------------------------------------------------
# 11. Beszel agent (motore Docker attivo).
# ---------------------------------------------------------------------------
setup_beszel

# ===========================================================================
elif [ "$DISTRO_FAMILY" = "rhel" ]; then
  # -------------------------------------------------------------------------
  # Motore container su RHEL/AlmaLinux: PODMAN rootless (parità con Docker).
  # NOTA: percorso NON ancora testato sul vivo (validazione in sospeso).
  # -------------------------------------------------------------------------
  log "Installo Podman (rootless) per '$TARGET_USER'."
  pkg_install podman podman-docker
  # Provider per 'podman compose' (necessario a Beszel).
  pkg_install podman-compose 2>/dev/null || warn "podman-compose non installato: 'podman compose' potrebbe non funzionare."

  # Limite dimensione log dei container (containers.conf dell'utente, ~50 MB).
  mkdir -p "$TARGET_HOME/.config/containers"
  cat > "$TARGET_HOME/.config/containers/containers.conf" <<'EOF'
[containers]
log_driver = "journald"
log_size_max = 52428800
EOF
  chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.config"

  # Linger + socket rootless (API Docker-compat) via systemd --user.
  log "Abilito il linger e il socket Podman rootless per '$TARGET_USER'."
  loginctl enable-linger "$TARGET_USER"
  for _ in $(seq 1 10); do [ -d "/run/user/$TARGET_UID" ] && break; sleep 1; done
  run_as_target systemctl --user enable --now podman.socket 2>/dev/null \
    || warn "podman.socket non avviato ora; partirà al prossimo login/boot."

  # DOCKER_HOST verso il socket Podman (per compose e Beszel).
  BASHRC="$TARGET_HOME/.bashrc"
  touch "$BASHRC"
  grep -qxF "export DOCKER_HOST=unix://$CONTAINER_SOCK" "$BASHRC" 2>/dev/null || \
    printf '# --- Podman rootless (init.sh) ---\nexport DOCKER_HOST=unix://%s\n' "$CONTAINER_SOCK" >> "$BASHRC"
  chown "$TARGET_USER:$TARGET_USER" "$BASHRC"

  DOCKER_SUMMARY="podman rootless per $TARGET_USER, DOCKER_HOST=unix://$CONTAINER_SOCK"

  setup_beszel
fi
# ===========================================================================

# ---------------------------------------------------------------------------
# 12. README.txt e server-manager.sh (scaricati dagli asset del repo).
# ---------------------------------------------------------------------------
# Gli asset stanno in assets/ del repo e vengono scaricati qui: init.sh resta
# leggero e i file si manutengono nel repo. README.txt è un template con
# placeholder, sostituiti con i valori di questa macchina.
log "Scarico README.txt e server-manager.sh dagli asset del repo in $TARGET_HOME."

if curl -fsSL "$ASSETS_BASE/assets/README.txt" -o "$TARGET_HOME/README.txt"; then
  sed -i \
    -e "s|%%VERSION%%|$SCRIPT_VERSION|g" \
    -e "s|%%USER%%|$TARGET_USER|g" \
    -e "s|%%UID%%|$TARGET_UID|g" \
    -e "s|%%HOME%%|$TARGET_HOME|g" \
    "$TARGET_HOME/README.txt"
  chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/README.txt"
else
  warn "Download di README.txt fallito ($ASSETS_BASE/assets/README.txt)."
fi

if [ "$DISTRO_FAMILY" = "debian" ]; then
  if curl -fsSL "$ASSETS_BASE/assets/server-manager.sh" -o "$TARGET_HOME/server-manager.sh"; then
    chmod +x "$TARGET_HOME/server-manager.sh"
    chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/server-manager.sh"
  else
    warn "Download di server-manager.sh fallito ($ASSETS_BASE/assets/server-manager.sh)."
  fi
else
  log "server-manager.sh non installato su $ID (gestione container/Podman in una versione futura)."
fi

# ---------------------------------------------------------------------------
# Fine.
# ---------------------------------------------------------------------------
cat <<EOF

$(log "Bootstrap completato.")

  Versione script ....... $SCRIPT_VERSION
  Distribuzione ......... ${PRETTY_NAME:-$ID} (famiglia $DISTRO_FAMILY)
  Hostname .............. $NEW_HOSTNAME
  Utente target ......... $TARGET_USER (uid $TARGET_UID), gruppo $ADMIN_GROUP, con password
  authorized_keys ....... $AUTH_KEYS (${#SSH_PUBLIC_KEYS[@]} chiave/i)
  SSH hardening ......... password auth OFF, root login OFF
  Motore container ...... $DOCKER_SUMMARY
  Synology ABB agent .... $SYNO_STATUS
  Beszel agent .......... $BESZEL_STATUS
  Cartelle utente ....... apps, data, logs, backup in $TARGET_HOME
  README ................ $TARGET_HOME/README.txt
  Project quota ......... $QUOTA_SUMMARY

ATTENZIONE (rischio lockout):
  L'accesso SSH via PASSWORD e il login di ROOT sono ora DISABILITATI.
  NON chiudere questa sessione finché non hai verificato, da un'ALTRA shell,
  di riuscire ad accedere via chiave come '$TARGET_USER'.

EOF

if [ "$QUOTA_REBOOT" -eq 1 ]; then
  warn "=============================================================="
  warn " REBOOT necessario per attivare le project quota ext4."
  warn "   sudo reboot"
  warn " Le quote verranno applicate AUTOMATICAMENTE al riavvio (nessun re-run)."
  warn "=============================================================="
fi
