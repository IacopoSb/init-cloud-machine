# init-cloud-machine

Questo repository contiene lo script di inizializzazione delle macchine cloud (one-line-install).

Per eseguire (come root):

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/IacopoSb/init-cloud-machine/main/init.sh)"
```

Lo script scarica a runtime gli asset da `assets/` del repo (README.txt e server-manager.sh).

## Changelog

### 1.1.0

Supporto base a **RHEL/AlmaLinux** (oltre a Debian/Ubuntu): rilevamento della
distribuzione, gruppo admin `sudo`/`wheel`, installazione pacchetti astratta
(`apt`/`dnf`). Su AlmaLinux vengono eseguite le parti base — **utente `mexage`,
hardening SSH, struttura cartelle, README** — mentre **Docker, project quota,
Beszel e Synology restano Debian-only** e vengono saltati (gestione futura, es.
Podman). `server-manager.sh` non viene installato su AlmaLinux.

### 1.0.0

Prima versione. Bootstrap di una Ubuntu/Debian barebone (va eseguito come root).
Lo script (in ordine):

1. **Hostname** — chiede interattivamente il nuovo hostname, lo imposta con `hostnamectl` e aggiorna `/etc/hosts`.
2. **Prerequisiti** — installa (unattended) `ca-certificates`, `curl`, `sudo`, `uidmap`, `dbus-user-session`, `slirp4netns`.
3. **Utente `mexage`** — se assente lo crea (home + bash), lo aggiunge al gruppo `sudo` e ne imposta la password interattivamente (niente NOPASSWD); garantisce le voci subuid/subgid per il rootless.
4. **Chiavi SSH** — inserisce le chiavi pubbliche autorizzate in `~mexage/.ssh/authorized_keys` (idempotente, permessi corretti).
5. **Hardening SSH** — drop-in `00-hardening.conf` con `PasswordAuthentication no` e `PermitRootLogin no`, validato con `sshd -t` prima del riavvio del servizio.
6. **Moduli kernel + userns** — carica `nf_tables`/`ip_tables` per il networking rootless e li rende persistenti; se la restrizione AppArmor sugli unprivileged user namespaces (Ubuntu 23.10+) è attiva, la **disabilita via sysctl** (`kernel.apparmor_restrict_unprivileged_userns=0`, persistente) perché rootlesskit ne ha bisogno.
7. **Docker** — installa Docker CE **a livello di sistema** (binari in `/usr/bin`) e abilita il **rootless** per `mexage` con `dockerd-rootless-setuptool.sh` (nessun binario in `~/bin`); il daemon rootful di sistema viene disabilitato. Fallback `--skip-iptables` se i moduli non si caricano.
8. **Avvio al boot + log** — abilita il daemon rootless via `systemd --user` + `loginctl enable-linger`; `docker compose` dal pacchetto di sistema `docker-compose-plugin`; configura il daemon rootless (`~/.config/docker/daemon.json`) con driver di log `local` e rotazione (`max-size 10m`, `max-file 5`) così i log dei container non crescono all'infinito.
9. **Synology ABB agent** *(opzionale, interattivo)* — installa e collega l'agent Active Backup for Business; su kernel recenti fa fallback automatico alla patch community (Peppershade) per il driver `synosnap`.
10. **Cartelle di lavoro + project quota** — crea `apps`, `data`, `logs`, `backup` in home; chiede interattivamente le quote hard di `data`/`logs` (es. `20G`; vuoto = nessuna). Su ext4 la feature quota si abilita solo da smontato: un **modulo dracut** la attiva al boot e un **servizio oneshot** applica i limiti al primo riavvio (poi si auto-disabilita) — nessun re-run manuale.
11. **Beszel agent** — scrive il compose in `~/apps/beszel` (modalità WebSocket: `HUB_URL`/`TOKEN`/`KEY` interattivi) e lo avvia via Docker rootless.
12. **README.txt + server-manager.sh** — scarica dagli asset del repo (`assets/`) e installa in home un `README.txt` della struttura cartelle e lo script `server-manager.sh` (hardware, container Docker raggruppati per stack, uso delle cartelle).
