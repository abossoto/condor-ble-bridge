#!/bin/sh
# Compila condor-ble-bridge (su macOS serve solo: xcode-select --install)
set -e
cd "$(dirname "$0")"
swiftc -O -swift-version 5 src/*.swift -o condor-ble-bridge
echo "Compilato: ./condor-ble-bridge  (prova: ./condor-ble-bridge selftest)"
