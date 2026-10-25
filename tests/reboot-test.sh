#!/usr/bin/env bash
#
# reboot-test.sh – prueft WebODM vor/nach einem echten VM-Reboot.
#
# Auf dem Proxmox-Host ausfuehren:
#   bash tests/reboot-test.sh <VMID> [IP] [PORT]
#
set -euo pipefail

VMID="${1:-}"
IP="${2:-}"
PORT="${3:-8000}"
CI_USER="${CI_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-/root/.ssh/webodm_vm_ed25519}"
IP_GIVEN=0
[[ -n "$IP" ]] && IP_GIVEN=1
FAIL=0

if [[ -z "$VMID" ]]; then
  echo "Usage: $0 <VMID> [IP] [PORT]" >&2
  exit 2
fi
[[ "$(id -u)" == "0" ]] || { echo "Bitte als root auf dem Proxmox-Host ausfuehren." >&2; exit 2; }
command -v qm >/dev/null 2>&1 || { echo "qm nicht gefunden – kein Proxmox-Host." >&2; exit 2; }
[[ -f "$SSH_KEY" ]] || { echo "SSH-Key fehlt: $SSH_KEY" >&2; exit 2; }

SSH_OPTS=(
  -i "$SSH_KEY"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=5
  -o BatchMode=yes
  -o ServerAliveInterval=20
  -o ServerAliveCountMax=15
)

ok()  { printf '\033[32m[PASS]\033[0m %s\n' "$*"; }
bad() { printf '\033[31m[FAIL]\033[0m %s\n' "$*"; FAIL=1; }
info(){ printf '\033[34m[INFO]\033[0m %s\n' "$*"; }

detect_ip() {
  local json ip
  json="$(timeout 20 qm guest cmd "$VMID" network-get-interfaces 2>/dev/null || true)"
  [[ -n "$json" ]] || return 1
  ip="$(printf '%s' "$json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for iface in data:
    name = iface.get("name", "")
    if name == "lo" or name.startswith(("docker", "br-", "veth", "virbr", "tun", "tap")):
        continue
    for addr in iface.get("ip-addresses", []):
        if addr.get("ip-address-type") == "ipv4":
            v = addr.get("ip-address", "")
            if v and not v.startswith(("127.", "169.254.")):
                print(v)
                sys.exit(0)
sys.exit(1)
' 2>/dev/null || true)"
  [[ -n "$ip" ]] || return 1
  printf '%s\n' "$ip"
}

ssh_vm() { ssh "${SSH_OPTS[@]}" "${CI_USER}@${IP}" "$@"; }

if [[ -z "$IP" ]]; then
  info "Warte auf Guest Agent / IP ..."
  for _ in $(seq 1 30); do
    IP="$(detect_ip 2>/dev/null || true)"
    [[ -n "$IP" ]] && break
    sleep 3
  done
  [[ -n "$IP" ]] || { echo "Keine IP ermittelbar. Bitte IP als 2. Argument angeben." >&2; exit 2; }
fi

info "VM ${VMID}, IP ${IP}, Port ${PORT}"

check_http() {
  local code
  code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "http://${IP}:${PORT}/" 2>/dev/null || true)"
  case "$code" in
    200|301|302|303|307|308) return 0;;
    *) echo "  HTTP ${code:-000}"; return 1;;
  esac
}
service_active()  { ssh_vm 'systemctl is-active --quiet webodm'; }
service_enabled() { ssh_vm 'systemctl is-enabled --quiet webodm'; }
webapp_running()  { ssh_vm "docker ps --format '{{.Names}}' | grep -qx webapp"; }
db_present()      { ssh_vm 'test -s /opt/webodm-data/db/PG_VERSION'; }
media_present()   { ssh_vm 'test -d /opt/webodm-data/media'; }

check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

info "--- Vor dem Reboot ---"
check "systemd-Unit ist enabled" service_enabled
check "systemd-Unit ist active" service_active
check "webapp-Container laeuft" webapp_running
check "PostgreSQL-Datenverzeichnis vorhanden" db_present
check "Media-Verzeichnis vorhanden" media_present
check "Web-UI antwortet" check_http

if [[ "$FAIL" != "0" ]]; then
  echo ""
  echo "Precheck fehlgeschlagen – Reboot wird nicht ausgefuehrt." >&2
  exit 1
fi

BOOT_BEFORE="$(ssh_vm 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)"
info "Boot-ID vorher: ${BOOT_BEFORE:-unbekannt}"

info "Reboote VM ${VMID} ..."
if ! qm reboot "$VMID"; then
  bad "qm reboot ${VMID} fehlgeschlagen"
  exit 1
fi

info "Warte auf SSH nach dem Reboot ..."
SSH_UP=0
for i in $(seq 1 90); do
  if [[ "$IP_GIVEN" == "0" ]] && (( i % 12 == 0 )); then
    NEW_IP="$(detect_ip 2>/dev/null || true)"
    [[ -n "$NEW_IP" ]] && IP="$NEW_IP"
  fi
  if ssh_vm true >/dev/null 2>&1; then SSH_UP=1; break; fi
  sleep 5
done
if [[ "$SSH_UP" != "1" ]]; then
  bad "SSH nach Reboot nicht erreichbar (IP ${IP})"
  echo "  qm terminal ${VMID}" >&2
  exit 1
fi
ok "SSH nach Reboot erreichbar"

info "Warte auf neuen Boot (boot_id) ..."
BOOT_AFTER=""
for _ in $(seq 1 60); do
  BOOT_AFTER="$(ssh_vm 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)"
  [[ -n "$BOOT_AFTER" && "$BOOT_AFTER" != "$BOOT_BEFORE" ]] && break
  sleep 5
done
if [[ -n "$BOOT_AFTER" && "$BOOT_AFTER" != "$BOOT_BEFORE" ]]; then
  ok "VM hat neu gebootet (${BOOT_AFTER})"
else
  bad "boot_id unveraendert – Reboot fraglich"
fi

info "Warte auf Web-UI (max. 10 Min) ..."
HTTP_OK=0
for _ in $(seq 1 120); do
  if check_http >/dev/null 2>&1; then HTTP_OK=1; break; fi
  sleep 5
done
if [[ "$HTTP_OK" == "1" ]]; then ok "Web-UI antwortet"; else bad "Web-UI antwortet nicht"; fi

info "--- Nach dem Reboot ---"
check "systemd-Unit ist enabled" service_enabled
check "systemd-Unit ist active" service_active
check "webapp-Container laeuft" webapp_running
check "PostgreSQL-Datenverzeichnis vorhanden" db_present
check "Media-Verzeichnis vorhanden" media_present

echo ""
if [[ "$FAIL" == "0" ]]; then
  printf '\033[32mERGEBNIS: PASS\033[0m – WebODM ist reboot-fest.\n'
  exit 0
else
  printf '\033[31mERGEBNIS: FAIL\033[0m – siehe oben.\n' >&2
  exit 1
fi
