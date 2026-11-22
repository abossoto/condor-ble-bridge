# condor-ble-bridge

*Versione italiana: [README.it.md](README.it.md).*

Lets **SeeYou Navigator** on an iPhone see the **Condor 3** soaring simulator, running on a Mac with MACh9 (Wine), as if it were a real Bluetooth Low Energy flight instrument. No dongle or extra hardware: the Mac's own Bluetooth is used.

```
Condor 3 (MACh9/Wine) ──COM1──▶ virtual serial port ──▶ condor-ble-bridge ──BLE──▶ SeeYou Navigator
```

Condor writes NMEA to COM1. Under Wine, COM1 can point to a Unix device, so the program creates a pseudo-terminal, reads Condor's sentences and sends them unchanged over BLE (standard Nordic UART service), advertising the Mac as `Condor3`.

Tested on a Mac mini M4 Pro, macOS, Condor 3.1.0 in MACh9, SeeYou Navigator on iPhone: position, altitude, speed, vario and wind show up in the app. Not tested: Android, other apps (XCSoar, LK8000…), Intel Macs, CrossOver or other Wine wrappers.

The program's messages and options are in Italian (the author is Italian); this README explains what they mean.

## Build

Requires Apple's command-line developer tools (`xcode-select --install`).

```bash
./build.sh
./condor-ble-bridge selftest
```

## One-time setup

### 1. Register COM1 in Wine

Adding a `com1` link in the prefix's `dosdevices` folder is **not** enough: Condor reads its port list from `HKLM\HARDWARE\DEVICEMAP\SERIALCOMM`, which Wine fills at start-up from `HKLM\Software\Wine\Ports`. With Condor closed:

```bash
WINEPREFIX="$HOME/Library/Application Support/app.mach9/prefix" /Applications/Mach9.app/Contents/Resources/wine/bin/wine reg add 'HKLM\Software\Wine\Ports' /v COM1 /t REG_SZ /d "$HOME/condor-com1" /f
```

`~/condor-com1` is a link that the bridge creates each time it starts, pointing to its virtual serial port.

### 2. Enable NMEA in Condor

Start the bridge first (below), then Condor. Setup > Options > NMEA output: tick Enable, port COM1. If COM1 is missing, Condor (or Wine) was started before the bridge: close Condor completely and start it again.

### 3. Pair in SeeYou Navigator

Add the device `Condor3`. The first time, macOS asks for Bluetooth permission for Terminal: allow it (System Settings > Privacy & Security > Bluetooth if you denied it).

## Every flight

Double-click **`Condor.command`** in Finder (or run `./Condor.command`). It rebuilds if needed, starts the bridge, waits for the virtual port and then opens MACh9, which starts Condor (if Condor is the launcher's default game). Fly, and SeeYou Navigator connects by itself. Ctrl-C in the Terminal window stops the bridge.

- `./Condor.command --no-mach9` starts only the bridge.
- If Condor is already open, the script doesn't reopen it and warns you to restart it.
- Extra options are passed to the program, e.g. `./Condor.command -v` to print every sentence.

## Commands

| Command | Purpose |
|---|---|
| `serial` | Virtual serial port for Condor (COM1) → BLE. The full mode, with position. |
| `fake` | Fake NMEA (flying east at 100 km/h, altitude oscillating), to test the link with the app. |
| `udp` | Condor's UDP output → `$LXWP0` only (no position). Not needed in practice. |
| `udp-log` | Prints Condor's UDP packets (diagnostics, no BLE). |
| `selftest` | Internal checks. |

Options: `--link PATH` (symlink to the virtual port), `--geoide METRES` (fill the GPGGA geoid separation field, see below), `--name NAME` (default `Condor3`), `--profile nus|hm10|both|custom` (default `nus`), `--service/--tx/--rx UUID` (with `custom`), `-v` (print every sentence), `--no-ble` (print instead of using Bluetooth), `--no-checksum`. Full list: `./condor-ble-bridge --help`.

Log lines worth knowing: `CONNESSO … iscritto a 6E400003-…` = the phone subscribed; `Iscrizioni attive: 1, pacchetti inviati: N` = packets sent; `Nuovo tipo di frase da Condor: $GPGGA` = Condor's NMEA is arriving; `scartate` = sentences dropped for a bad checksum.

## What Condor 3.1.0 sends

Three sentences per second:

```
$GPGGA,123322.104,4522.7145,N,00732.1565,E,1,12,10,1899.6,M,,,,,0000*31
$GPRMC,123321.101,A,4522.7186,N,00732.1332,E,61.13,95.51,,,,*2E
$LXWP0,Y,121.1,1900.1,0.31,,,,,,97,039,16.1*70
```

- `$GPGGA` / `$GPRMC`: position, altitude, ground speed (knots), track. Empty date and geoid separation; HDOP fixed at 10.
- `$LXWP0`: indicated airspeed (km/h), altitude (m), vario (m/s), heading, wind direction and speed (km/h). The wind starts at 0 and settles in about a minute, so it looks like an estimate.
- Not sent: QNH, MacCready, ballast, task, FLARM traffic.

## Pitfalls found while testing

- **One BLE service only.** With two serial services (Nordic UART + HM-10 `FFE0`) SeeYou Navigator no longer found the device; probably the advertisement exceeds 31 bytes and macOS moves part of it where apps can't see it. Hence the default `--profile nus`.
- **Exact Nordic UART UUIDs**: service `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`, TX (notify) `6E400003-…`, RX (write) `6E400002-…`. A test with slightly wrong UUIDs appeared in the app but never connected.
- **Altitude 43 m too low.** Condor's NMEA altitude matches its altimeter, but SeeYou Navigator showed a constant ~43 m less: with the geoid field empty it seems to apply its own geoid correction (about 45-50 m in northern Italy). `--geoide 0` fills the field and fixes it; `Condor.command` always uses it.
- **One app at a time** can hold the BLE connection on iOS: close nRF Connect before opening SeeYou.

## Files

```
Condor.command       everyday launcher (double-click)
build.sh             build script
src/main.swift       arguments, selftest, start-up
src/BLE.swift        CoreBluetooth peripheral
src/Sources.swift    sources: fake, virtual serial port, UDP
src/NMEA.swift       checksums and sentences
src/CondorUDP.swift  UDP packet parser
src/Log.swift        readable log
config/              example UDP.ini
```

## Licence

MIT, see [LICENSE](LICENSE). Not affiliated with Condor or Naviter; Naviter sells an official Bluetooth dongle for Condor.
