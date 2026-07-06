#!/usr/bin/env bash
# server-manager.sh — informazioni/gestione del server.
# Parte di init-cloud-machine; scaricato nella home dell'utente da init.sh.
set -u
export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"
HOME_DIR="$(cd "$(dirname "$0")" && pwd)"

line() { printf '%s\n' "------------------------------------------------------------"; }

echo "==== SERVER INFO — $(hostname) — $(date '+%Y-%m-%d %H:%M:%S') ===="

line; echo "HARDWARE"
echo "  CPU:    $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ //') ($(nproc) core)"
echo "  RAM:    $(free -h | awk '/^Mem:/ {print $3" / "$2" (usata/totale)"}')"
echo "  Uptime:$(uptime -p | sed 's/^up/ /')"
echo "  Disco:"
df -h --output=target,used,size,pcent / 2>/dev/null | sed '1d;s/^/    /'

line; echo "DOCKER (rootless) — container per stack in apps/"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  running=$(docker ps -q | wc -l); total=$(docker ps -aq | wc -l)
  echo "  Totale: $running attivi / $total totali"
  docker ps -a \
    --format '{{.Label "com.docker.compose.project.working_dir"}}\t{{.Names}}\t{{.Status}}' 2>/dev/null \
  | awk -F'\t' -v app="$HOME_DIR/apps" '
      {
        wd=$1
        if (wd ~ ("^" app "/")) { g=substr(wd, length(app)+2); sub("/.*","",g) }
        else if (wd == "")      { g="(senza compose)" }
        else                    { g="(fuori da apps: " wd ")" }
        items[g]=items[g] sprintf("    %s  %s\n", $2, $3); seen[g]=1
      }
      END {
        n=0
        for (g in seen) { printf "  [%s]\n%s", g, items[g]; n++ }
        if (n==0) print "  (nessun container)"
      }'
else
  echo "  docker non raggiungibile (daemon rootless avviato?)"
fi

line; echo "CARTELLE DI LAVORO"
for d in apps data logs backup; do
  [ -d "$HOME_DIR/$d" ] && echo "  $d/  uso: $(du -sh "$HOME_DIR/$d" 2>/dev/null | cut -f1)"
done
if command -v repquota >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
  line; echo "PROJECT QUOTA (repquota -P /)"
  repquota -P / 2>/dev/null | sed 's/^/  /'
fi
line
