# init-cloud-machine

Questo repository contiene lo script di inizializzazione delle macchine cloud (one-line-install).

Per eseguire (come root):

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/IacopoSb/init-cloud-machine/main/init.sh)"
```

Lo script scarica a runtime gli asset da `assets/` del repo (README.txt, server-manager.sh e il pacchetto ClamAV + Wazuh in `assets/wazuh/`).

## Changelog

### 1.4.3

`clamav-scan`: chiusa un'evasione. Un nome di file con a-capo seguito da `----------- SCAN SUMMARY` faceva credere iniziato il riepilogo e nascondeva i rilevamenti successivi (allarme perso). Ora il riepilogo vero si riconosce per posizione (l'ultimo marcatore), e se `clamscan` segnala infetti (`rc=1` o `Infected files`) ma le righe `FOUND` estratte sono di meno, viene emesso comunque un evento `FOUND` "non analizzabile": un rilevamento non resta mai senza allarme.

### 1.4.2

`clamav-scan`: se l'output di `clamscan` contiene una riga che non è `… FOUND` (segno di un nome di file con a-capo, che spezza la riga e può far comparire il nome di un altro file esistente), **tutti** i percorsi di quella scansione sono marcati come non affidabili negli eventi per Wazuh; la firma trovata resta segnalata. Lo stderr di `clamscan` va nel log completo invece che nell'output analizzato. Corretto il changelog: lo spostamento del log in `/var/log/clamav-scan/` è della 1.4.0, non della 1.4.1.

### 1.4.1

Correzioni di sicurezza del pacchetto ClamAV + Wazuh (sezione 11b):

- `install-host.sh` con `--src-url` scarica **sempre** i file di supporto in una cartella privata e non usa più quelli presenti accanto allo script: lanciato da `init.sh` in `/tmp`, avrebbe installato da root un `clamav-scan` piantato lì da un altro utente. `init.sh` ora scarica l'installer in una cartella `mktemp -d` con permessi 700.
- `clamav-scan`: i campi degli eventi per Wazuh perdono i caratteri di controllo (un a-capo nel nome di un file poteva creare un evento falso) e `\`/`"` sono neutralizzati.

### 1.4.0

Nuova sezione **11b — ClamAV + agent Wazuh** (Debian/Ubuntu e RHEL/AlmaLinux, anche in `init-mvps.sh`). Scarica ed esegue `assets/wazuh/install-host.sh --no-enroll --class auto`, lo stesso script usato per il rollout manuale sui server esistenti:

- **ClamAV** con aggiornamento firme e scansione settimanale (`clamav-scan.timer`, domenica notte, sfalsata) **solo se la RAM totale è ≥ 3 GB** (classe A); sotto quella soglia le firme in memoria (1–1,5 GB) metterebbero in crisi la macchina e si installa solo l'agent (classe C).
- **Agent Wazuh** alla stessa versione del manager (4.14.9, repo disattivato dopo l'installazione), **non registrato**: la registrazione richiede la password di enrollment (Vaultwarden) e il nome del target Warpgate, e si fa dopo con `sudo wazuh-enroll <nome> <gruppo>` (installato in `/usr/local/sbin`).
- I passi per completare la configurazione sono stampati in fondo all'output e aggiunti al `README.txt` del server.

Il log completo delle scansioni sta in `/var/log/clamav-scan/` (root): root non scrive né fa `chown` in cartelle controllate da un utente.

Un errore in questa sezione non interrompe il bootstrap: il riepilogo lo segnala (`ClamAV + Wazuh`).

### 1.3.1

**fzf** installato di default insieme ai pacchetti di base. Su RHEL/AlmaLinux sta in EPEL: se manca lo script avvisa e prosegue. Chiave SSH `warpgate` aggiornata a quella del nuovo bastione.

### 1.3.0

Nuova sezione **1b — DNS over TLS**. Il resolver assegnato via DHCP da OVH
(`213.186.33.99`) risponde **SERVFAIL** su una quota rilevante delle query per la
zona `mexage.net` (misurato il 04/08/2026: 89 fallimenti su 280, contro 0 su 280
verso Cloudflare) ed è l'**unico** resolver configurato, quindi senza fallback.
Lo script lo sostituisce con tre resolver **DNS over TLS** su due provider
(`DNS_TLS_SERVERS`, configurabile in testa): drop-in
`/etc/systemd/resolved.conf.d/99-dns-over-tls.conf` più
`/etc/netplan/99-dns-over-tls.yaml` con `use-dns: false`, che impedisce al DHCP di
reimporre il proprio resolver al boot. Si usa DoT e non un semplice secondario in
chiaro perché su OVH l'egress **UDP/53** verso resolver terzi può essere filtrato
(protezione anti-amplificazione), mentre la **853/TCP** del DoT no.

Due guard prima di toccare qualcosa — 853/TCP raggiungibile, e search domain del
link che non risolva nomi interni — più validazione con `netplan generate` e
verifica finale con **rollback automatico**: in ogni caso di dubbio la
configurazione del DHCP resta invariata, come già fa la sezione 5 con `sshd -t`.
Non viene eseguito `netplan apply`, per non riapplicare la rete sotto la sessione
SSH: l'effetto immediato arriva da `resolvectl`, il file netplan serve al boot.

### 1.2.0

Su **AlmaLinux/RHEL** il motore container è **Podman** (al posto di Docker),
con parità di funzioni: Podman rootless per `mexage`, socket compat (API Docker),
`podman compose`, agent **Beszel** (via il socket Podman) e limite dimensione
log dei container (`containers.conf`). Su Debian/Ubuntu resta Docker. La project
quota su AlmaLinux (root XFS) resta rimandata. **NOTA: il percorso Podman non è
ancora stato validato end-to-end sul vivo.**

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
