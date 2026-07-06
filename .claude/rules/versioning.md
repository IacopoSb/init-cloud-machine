# Versioning di init.sh e changelog

**Ambito**: repository `init-cloud-machine`. Si applica ogni volta che si modifica lo script `init.sh`.

## Regola

A **ogni modifica** funzionale a `init.sh` devono essere aggiornati insieme:

1. la variabile **`SCRIPT_VERSION`** in testa a `init.sh`;
2. il **changelog** in `README.md` (una sezione `### <versione>` con l'elenco delle modifiche).

Versione e changelog vanno sempre **allineati**: la versione in `SCRIPT_VERSION` deve avere una voce corrispondente nel changelog.

## Quando creare una NUOVA versione vs integrare in quella corrente

La discriminante è lo **stato git** della versione corrente:

- **Se la versione corrente è già stata committata/rilasciata** (esiste un commit che la contiene) → la nuova modifica apre una **nuova versione**: incrementa `SCRIPT_VERSION` e aggiungi una nuova sezione nel changelog.
- **Se la versione corrente è ancora nel working tree** (modifiche non ancora committate dopo l'ultimo bump di versione) → **NON** creare una nuova versione: si sta ancora integrando la stessa release. Mantieni lo stesso numero di versione e **aggiungi/estendi** la voce di changelog della versione corrente.

In sintesi: **una sola versione per release/commit**. Finché non si committa, tutte le modifiche confluiscono nella stessa versione.

## Incremento (semver `MAJOR.MINOR.PATCH`)

Quando si apre una nuova versione, scegli l'incremento in base al tipo di modifica:

- **PATCH** (`x.y.Z+1`): fix, correzioni, ritocchi che non cambiano il comportamento atteso.
- **MINOR** (`x.Y+1.0`): nuove funzionalità retrocompatibili (es. una nuova sezione/opzione dello script).
- **MAJOR** (`X+1.0.0`): cambiamenti non retrocompatibili (es. rimozione/riorganizzazione che cambia l'uso o l'output atteso).

## Checklist operativa a ogni modifica di `init.sh`

1. Determina se la versione corrente è già committata (`git log`, `git status`).
2. Decidi: nuova versione (con incremento semver adeguato) **oppure** integra nella versione non ancora committata.
3. Aggiorna `SCRIPT_VERSION` in `init.sh` (solo se apri una nuova versione).
4. Aggiorna la sezione corrispondente nel changelog di `README.md`.
5. Verifica che `init.sh` resti valido (`bash -n init.sh`) e senza CR (fine-riga LF).
