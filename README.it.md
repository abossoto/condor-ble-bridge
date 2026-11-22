# condor-ble-bridge

*English version: [README.md](README.md).*

Fa vedere il simulatore **Condor 3** a **SeeYou Navigator** sull'iPhone come se fosse uno strumento di volo Bluetooth Low Energy (BLE). Il Mac si annuncia come periferica BLE (CoreBluetooth) e invia frasi NMEA: posizione (`$GPRMC`, `$GPGGA`), velocità, quota e variometro (`$LXWP0`).

```
Condor 3 (Wine/MACh9) ──COM1──▶ porta seriale virtuale ──▶ condor-ble-bridge ──BLE──▶ SeeYou Navigator
```

## Uso quotidiano

Dopo la configurazione iniziale (Passo 2, una volta sola):

1. doppio clic su **`Condor.command`** nel Finder (oppure `./Condor.command` da terminale): avvia il ponte e, appena la porta COM1 è pronta, apre MACh9, che fa partire Condor;
2. in Condor parti in volo;
3. in SeeYou Navigator il dispositivo «Condor3» si collega da solo;
4. a fine volo, Ctrl-C nella finestra del ponte (Condor resta aperto).

Il ponte deve partire **prima** di Condor, altrimenti Condor non trova la porta: per questo lo script, se Condor è già aperto, non lo riapre e avvisa di riavviarlo. `./Condor.command --no-mach9` avvia solo il ponte. Lo script ricompila da solo se serve e avvisa se COM1 manca nel registro di Wine. Aperto dal Finder, gira nell'app Terminale, che al primo avvio chiede il permesso Bluetooth.

## Compilazione

Serve Swift: su macOS bastano gli strumenti da riga di comando (`xcode-select --install`).

```bash
./build.sh
```

```bash
./condor-ble-bridge selftest
```

Al primo avvio con il Bluetooth, macOS chiede il permesso per il Terminale. Se lo si è negato: Impostazioni di Sistema > Privacy e sicurezza > Bluetooth.

## Comandi

| Comando | A cosa serve |
|---|---|
| `fake` | NMEA finto (volo verso est a 100 km/h, quota che oscilla). Serve a provare il collegamento con l'app. |
| `serial` | Crea una porta seriale virtuale da dare a Condor come COM1 e inoltra via BLE il suo NMEA. È la modalità completa, con la posizione. |
| `udp` | Riceve l'UDP di Condor e invia solo `$LXWP0` (velocità, quota, vario). Non contiene la posizione. |
| `udp-log` | Stampa i pacchetti UDP così come arrivano (diagnostica, senza BLE). |
| `selftest` | Controlli interni. |

Opzioni utili: `--name Condor3`, `--profile nus|hm10|both|custom` (predefinito `nus`), `-v` (mostra ogni frase), `--no-ble` (stampa a video invece di usare il Bluetooth). Elenco completo: `./condor-ble-bridge --help`.

## Passo 1: collegare l'app con dati finti

```bash
./condor-ble-bridge fake -v
```

Il programma pubblica il servizio **Nordic UART** standard: servizio `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`, TX (notify) `6E400003-…`, RX (scrittura) `6E400002-…`. **Verificato il 22/11/2026: SeeYou Navigator su iPhone si collega e mostra i dati.**

Nel registro, controllare:

- `CONNESSO: … iscritto a 6E400003-…`: l'app si è iscritta e riceve i dati;
- `Iscrizioni attive: 1, pacchetti inviati: N`: ogni 10 secondi, N deve crescere;
- `SCRITTURA dal telefono …`: l'app sta inviando comandi (finora non visto).

Note dalle prove:

- Non usare `--profile both`: con due servizi l'annuncio BLE supera i 31 byte, macOS ne sposta una parte in un'area che le app non vedono e SeeYou non trova più il dispositivo.
- Il primo script (`ble_nmea.swift`) usava `6E400001-B5F3-4936-F8A8-E5B6C3D1F0AE`, che non è l'UUID Nordic UART standard.
- Su iOS una sola app alla volta può tenere il collegamento: chiudere nRF Connect prima di usare SeeYou.

Per provare altri UUID (per esempio quelli di uno strumento reale letti con nRF Connect):

```bash
./condor-ble-bridge fake -v --name PROVA --profile custom --service <UUID-SERVIZIO> --tx <UUID-NOTIFY> --rx <UUID-SCRITTURA>
```

## Passo 2: Condor via porta seriale (Wine)

Sotto Wine le porte COM sono collegamenti a device Unix, quindi non servono HW VSP3 o com0com. Il programma crea uno pseudo-terminale e un collegamento con nome fisso:

```bash
./condor-ble-bridge serial -v --link ~/condor-com1
```

Poi bisogna dire al prefisso Wine di MACh9 che COM1 è `~/condor-com1`. Con MACh9 il prefisso è `~/Library/Application Support/app.mach9/prefix` e Condor gira da `prefix/drive_c/Condor3` (non da `/Applications/Condor3`). Il solo collegamento in `dosdevices` **non basta**: Condor prende l'elenco delle porte da `HKLM\HARDWARE\DEVICEMAP\SERIALCOMM`, che Wine compila all'avvio leggendo `HKLM\Software\Wine\Ports`. Procedura verificata il 22/11/2026 (una volta sola):

```bash
WINEPREFIX="$HOME/Library/Application Support/app.mach9/prefix" /Applications/Mach9.app/Contents/Resources/wine/bin/wine reg add 'HKLM\Software\Wine\Ports' /v COM1 /t REG_SZ /d "$HOME/condor-com1" /f
```

Poi chiudere Condor del tutto e riavviarlo da MACh9 **con `serial` già in esecuzione**: COM1 compare in Setup > Options > NMEA Output.

In Condor: Setup > Options > NMEA Output, porta COM1. Nel profilo pilota corrisponde a `NMEAEnable` e `NMEAPort=COM1` in `Pilots/<pilota>/setup.ini`. Il registro del programma mostra `Nuovo tipo di frase da Condor: $GPGGA` (e simili) appena arrivano i dati, e ogni 10 secondi il conteggio delle frasi valide e scartate.

## Passo 3 (facoltativo): UDP

L'`UDP.ini` di Condor è in `prefix/drive_c/Condor3/Settings/UDP.ini`: sezioni e chiavi coincidono con `config/UDP.ini.esempio` (verificato sul file installato). Basta mettere `Enabled=1`, poi:

```bash
./condor-ble-bridge udp-log --dump udp-dump.txt
```

Il programma ascolta su tutte le interfacce, quindi riceve anche il traffico che Wine invia a 127.0.0.1. Va confrontato con il file `UDPlog.txt` scritto da Condor con `LogToFile=1`. Secondo la documentazione disponibile, l'UDP **non contiene latitudine e longitudine**: per la mappa di SeeYou serve la modalità `serial`.

## Cosa è verificato e cosa no

| Cosa | Stato |
|---|---|
| Checksum e formato di `$GPRMC`, `$GPGGA`, `$LXWP0` | testato (`selftest`, su macOS) |
| Modalità `fake` e `serial` (pty e collegamento) con `--no-ble` | eseguito su macOS con dati di prova |
| Parte BLE (`src/BLE.swift`) | compilata ed eseguita su Mac mini M4 Pro |
| SeeYou Navigator con Nordic UART e NMEA finto | **verificato**: si collega e mostra i dati |
| SeeYou Navigator con FFE0 / due servizi insieme | non funziona (annuncio troppo lungo) |
| Condor 3 sotto MACh9 scrive sulla pty (COM1 via `Wine\Ports`) | **verificato**: `$GPGGA`, `$GPRMC`, `$LXWP0` a 1 Hz, checksum validi |
| Catena completa Condor → BLE → SeeYou Navigator | **verificato**: posizione, quota, velocità, vario e vento in app |
| Formato UDP di Condor 3.1.0 | non verificato; non serve, perché la seriale porta già anche `$LXWP0` |
| UUID del dongle Naviter per Condor | DATI NON TROVATI |

## Cosa manda Condor (registro del 22/11/2026)

Solo tre frasi, una volta al secondo, che il ponte inoltra senza modifiche:

```
$GPGGA,123322.104,4522.7145,N,00732.1565,E,1,12,10,1899.6,M,,,,,0000*31
$GPRMC,123321.101,A,4522.7186,N,00732.1332,E,61.13,95.51,,,,*2E
$LXWP0,Y,121.1,1900.1,0.31,,,,,,97,039,16.1*70
```

- `$GPGGA`: ora, posizione, quota; campo geoide vuoto, HDOP fisso a 10.
- `$GPRMC`: posizione, velocità al suolo (nodi), rotta; data vuota.
- `$LXWP0`: velocità indicata (km/h), quota (m), vario (m/s), prua, direzione e forza del vento (km/h). Il vento parte da 0 e si assesta in circa un minuto: sembra una stima, non il vento del meteo.
- Non arrivano QNH, MacCready, zavorra, task né traffico FLARM.

**Quota.** La quota NMEA è identica in `$GPGGA` e `$LXWP0` e coincide con l'altimetro di Condor. Senza correzione SeeYou Navigator mostrava circa **43 m in meno**, in modo costante (tre confronti: 1951/1908, 1828/1785, 1995/1953): vedendo vuoto il campo geoide, SeeYou corregge la quota con un geoide proprio (in Piemonte circa 45-50 m). Con `--geoide 0` (campo riempito con `0,M`) la differenza sparisce (prova del 22/11/2026). `Condor.command` usa `--geoide 0` sempre; con il programma lanciato a mano va aggiunto.

## Struttura

```
Condor.command        avvio quotidiano (doppio clic)
src/main.swift       argomenti, selftest, avvio
src/BLE.swift        periferica CoreBluetooth (solo macOS)
src/Sources.swift    sorgenti: finta, porta seriale virtuale, UDP
src/NMEA.swift       checksum e costruzione frasi
src/CondorUDP.swift  parser del pacchetto UDP
src/Log.swift        registro leggibile
```
