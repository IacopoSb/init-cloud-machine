Server inizializzato da init.sh (v%%VERSION%%)
Utente: %%USER%%

STRUTTURA CARTELLE (%%HOME%%)
  apps/     Stack Docker Compose - una sottocartella per stack (es. apps/beszel/)
  data/     Dati persistenti dei container
  logs/     Log applicativi
  backup/   Backup locali

DOCKER (rootless, come utente %%USER%%)
  Socket: DOCKER_HOST=unix:///run/user/%%UID%%/docker.sock  (gia' in ~/.bashrc)
  Deploy di uno stack:
    mkdir -p ~/apps/<nome>
    cd ~/apps/<nome>
    # crea qui docker-compose.yml
    docker compose up -d

GESTIONE  ->  ./server-manager.sh
  Gestisce gli stack Docker in esecuzione, le quote disco (con sudo) e i
  login ai registry Docker; mostra hardware e uso delle cartelle.

NOTE
  - Accesso SSH: solo tramite Warpgate (bastion). Accesso diretto con
    password e login di root disabilitati; sudo con password.
