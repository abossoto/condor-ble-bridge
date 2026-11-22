#!/bin/sh
# Avvio di condor-ble-bridge: Condor 3 (MACh9, COM1) -> Bluetooth -> SeeYou Navigator.
# Avvia il ponte, aspetta che la porta COM1 sia pronta e poi apre MACh9 (gioco predefinito: condor3).
# Si può aprire con un doppio clic dal Finder oppure da terminale: ./Condor.command
# Opzioni: --no-mach9 avvia solo il ponte; le altre vanno al programma (es. -v).
set -e
cd "$(dirname "$0")"

LINK="$HOME/condor-com1"
PREFIX="$HOME/Library/Application Support/app.mach9/prefix"
APRI_MACH9=1
if [ "$1" = "--no-mach9" ]; then APRI_MACH9=0; shift; fi

# Ricompila se il programma manca o se un sorgente è più recente.
if [ ! -x ./condor-ble-bridge ] || [ -n "$(find src -name '*.swift' -newer ./condor-ble-bridge)" ]; then
    echo "Compilazione in corso…"
    ./build.sh
fi

# Controlli sul prefisso Wine di MACh9 (solo avvisi, non bloccano l'avvio).
if [ ! -d "$PREFIX" ]; then
    echo "ATTENZIONE: prefisso MACh9 non trovato in $PREFIX"
elif ! grep -q '"COM1"="[^"]*condor-com1"' "$PREFIX/system.reg" 2>/dev/null; then
    echo "ATTENZIONE: COM1 non risulta nel registro di Wine (Wine\\Ports): Condor non vedrà la porta."
    echo "            Procedura nel README, sezione «Passo 2»."
fi

# Collegamento rimasto da un'esecuzione interrotta male: lo togliamo, il ponte lo ricrea.
[ -L "$LINK" ] && rm -f "$LINK"

if [ "$APRI_MACH9" = 1 ]; then
    if pgrep -qf 'Condor.exe'; then
        echo "ATTENZIONE: Condor è già aperto, non lo riapro. Chiudilo e riaprilo da MACh9 perché veda la nuova porta."
    else
        # In parallelo: appena il ponte ha creato la porta, apre MACh9.
        (
            i=0
            while [ ! -L "$LINK" ] && [ $i -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
            if [ -L "$LINK" ]; then
                echo ">>> Porta pronta: apro MACh9 (Condor)"
                open -a Mach9
            else
                echo ">>> ERRORE: la porta non è stata creata, MACh9 non aperto"
            fi
        ) &
    fi
fi

echo "Avvio del ponte. Ctrl-C per chiudere (Condor resta aperto)."
echo
# --geoide 0: Condor lascia vuoto il campo geoide e SeeYou toglieva circa 43 m alla quota (verificato il 22/11/2026).
exec ./condor-ble-bridge serial --link "$LINK" --geoide 0 "$@"
