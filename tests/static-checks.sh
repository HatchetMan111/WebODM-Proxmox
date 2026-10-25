#!/usr/bin/env bash
#
# static-checks.sh – Syntax-/Strukturpruefung ohne Proxmox-Host.
#
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
ok()  { printf '\033[32m[PASS]\033[0m %s\n' "$*"; }
bad() { printf '\033[31m[FAIL]\033[0m %s\n' "$*"; FAIL=1; }
check(){ local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

cd "$ROOT"

echo "== Syntax =="
for f in install/webodm.sh install/webodm-inner.sh tests/reboot-test.sh tests/static-checks.sh; do
  check "bash -n ${f}" bash -n "$f"
done

if command -v shellcheck >/dev/null 2>&1; then
  echo "== ShellCheck =="
  check "shellcheck (warning)" shellcheck -S warning \
    install/webodm.sh install/webodm-inner.sh tests/reboot-test.sh tests/static-checks.sh
else
  echo "== ShellCheck: nicht installiert, uebersprungen =="
fi

echo "== Dateien / Rechte =="
for f in install/webodm.sh install/webodm-inner.sh tests/reboot-test.sh tests/static-checks.sh; do
  check "${f} ist ausfuehrbar" test -x "$f"
done
check "systemd/webodm.service vorhanden" test -s systemd/webodm.service
check "README.md vorhanden" test -s README.md

echo "== systemd-Unit =="
check "Restart=always" grep -q '^Restart=always$' systemd/webodm.service
check "WantedBy=multi-user.target" grep -q '^WantedBy=multi-user.target$' systemd/webodm.service
check "After=network-online.target" grep -q '^After=network-online.target docker.service$' systemd/webodm.service
check "Requires=docker.service" grep -q '^Requires=docker.service$' systemd/webodm.service
check "User=webodm" grep -q '^User=webodm$' systemd/webodm.service
check "Platzhalter @APP_PORT@" grep -q '@APP_PORT@' systemd/webodm.service
check "Platzhalter @APP_DIR@" grep -q '@APP_DIR@' systemd/webodm.service
check "Platzhalter @DATA_DIR@" grep -q '@DATA_DIR@' systemd/webodm.service

UNIT_TMP="$(mktemp)"
sed -e 's|@APP_PORT@|8000|g' -e 's|@APP_DIR@|/opt/webodm|g' -e 's|@DATA_DIR@|/opt/webodm-data|g' \
  systemd/webodm.service > "$UNIT_TMP"
check "keine Platzhalter nach Substitution" bash -c "! grep -q '@[A-Z_]*@' '$UNIT_TMP'"
rm -f "$UNIT_TMP"

echo "== Host-Installer =="
check "qm create" grep -q 'qm create' install/webodm.sh
check "qm importdisk" grep -q 'qm importdisk' install/webodm.sh
check "Cloud-Init ciuser" grep -q -- '--ciuser' install/webodm.sh
check "Cloud-Init sshkeys" grep -q -- '--sshkeys' install/webodm.sh
check "onboot" grep -q -- '--onboot 1' install/webodm.sh
check "qm start" grep -q 'qm start' install/webodm.sh
check "Update-Modus via --vmid" grep -q 'Update-Modus' install/webodm.sh
check "IPv4-Erkennung via Guest Agent" grep -q 'network-get-interfaces' install/webodm.sh

echo "== Innen-Installer =="
check "Docker-CE-Repo" grep -q 'download.docker.com/linux/ubuntu' install/webodm-inner.sh
check "Compose-Plugin" grep -q 'docker-compose-plugin' install/webodm-inner.sh
check "webodm.sh start" grep -q 'webodm.sh start' install/webodm-inner.sh
check "Datenverzeichnis" grep -q '/opt/webodm-data' install/webodm-inner.sh
check "Erster Login /welcome/" grep -q '/welcome/' install/webodm-inner.sh
check "HTTP-Healthcheck" grep -q 'curl -s -o /dev/null' install/webodm-inner.sh

echo "== README =="
check "Einzeiler-URL" grep -q 'raw.githubusercontent.com/HatchetMan111/WebODM-Proxmox/main/install/webodm.sh' README.md
check "kein Default-Passwort dokumentiert" grep -qi 'kein Default-Passwort' README.md
check "Update dokumentiert" grep -qi '## Update' README.md
check "Reboot-Test dokumentiert" grep -qi 'reboot-test.sh' README.md

echo "== Hilfe =="
check "webodm.sh --help" bash install/webodm.sh --help
check "webodm-inner.sh --help" bash install/webodm-inner.sh --help

echo "== Reste =="
check "kein CHANGEME" bash -c "! grep -R -n 'CHANGEME' install systemd README.md"
check "kein TODO" bash -c "! grep -R -n 'TODO' install systemd README.md"

echo ""
if [[ "$FAIL" == "0" ]]; then
  printf '\033[32mERGEBNIS: PASS\033[0m – statische Pruefungen OK.\n'
  exit 0
else
  printf '\033[31mERGEBNIS: FAIL\033[0m – siehe oben.\n' >&2
  exit 1
fi
