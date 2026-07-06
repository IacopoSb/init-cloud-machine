#!/bin/sh
# Applica le project quota registrate in /etc/init-cloud-machine/quota.conf.
# Eseguito da init-cloud-machine-quota.service al primo boot con quota attiva,
# poi il servizio si disabilita da solo. Righe conf: <projid> <kib> <mnt> <dir>
CONF=/etc/init-cloud-machine/quota.conf
[ -r "$CONF" ] || exit 0

while read -r projid kib mnt dir; do
  [ -n "$projid" ] || continue
  case "$projid" in \#*) continue ;; esac
  [ -d "$dir" ] || continue
  chattr -p "$projid" +P "$dir" 2>/dev/null || true
  setquota -P "$projid" 0 "$kib" 0 0 "$mnt" 2>/dev/null || true
done < "$CONF"

# Applicato: non serve più ai boot successivi.
systemctl disable init-cloud-machine-quota.service 2>/dev/null || true
exit 0
