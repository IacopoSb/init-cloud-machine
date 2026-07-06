Server inizializzato da init.sh (v%%VERSION%%)
Utente: %%USER%%

Struttura cartelle in %%HOME%%:

  apps/     Stack Docker Compose delle applicazioni (una sottocartella per stack).
            Es. apps/beszel/  -> agent di monitoraggio Beszel.
            Nessuna project quota.

  data/     Dati persistenti dei container/applicazioni.
            Una sottocartella per stack. Project quota (hard limit) opzionale.

  logs/     Log applicativi.
            Una sottocartella per stack. Project quota (hard limit) opzionale.

  backup/   Backup locali. Nessuna project quota.

File in home:

  README.txt          Questo file.
  server-manager.sh   Info/gestione del server (hardware, docker per stack, uso cartelle).
                      Uso:  ./server-manager.sh

Note:
  - Docker gira in modalità ROOTLESS come utente %%USER%% con binari di sistema
    (DOCKER_HOST=unix:///run/user/%%UID%%/docker.sock).
  - Accesso SSH: solo tramite chiave (password e root login disabilitati).
