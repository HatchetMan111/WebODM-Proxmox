#!/usr/bin/env bash
#
# webodm.sh – Proxmox-VE-Installer fuer WebODM (drohnenbasierte Fotogrammetrie)
#
# Erstellt eine Ubuntu-Cloud-Init-VM, installiert Docker + WebODM und
# registriert einen reboot-festen systemd-Dienst.
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/WebODM-Proxmox/main/install/webodm.sh)"
#
# Testdefault: 2 vCPU, 6 GB RAM, 32 GB Disk, Port 8000, naechste freie VMID.
# Fuer produktive Fotogrammetrie per --cores/--ram/--disk vergroessern.
# Das Script ist idempotent: mit --vmid <ID> wird eine bestehende VM aktualisiert.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
APP="WebODM"
APP_ID="webodm"
VMID=""
VM_HOSTNAME="webodm"
CORES=2
RAM_MB=6144
DISK_GB=32
BRIDGE="vmbr0"
STORAGE=""
APP_PORT=8000
WO_REF="master"
OS_VERSION="24.04"
CI_USER="ubuntu"
IP_OVERRIDE=""
SSH_KEY_PATH="/root/.ssh/webodm_vm_ed25519"
FORCE=0
DEBUG=0

INSTALLER_REPO="${INSTALLER_REPO:-https://github.com/HatchetMan111/WebODM-Proxmox}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/HatchetMan111/WebODM-Proxmox/main}"
LOG_FILE="/var/log/webodm-proxmox-install.log"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd || true)"
SSH_KEYS_TMP=""
INNER_TMP=""

# ---------------------------------------------------------------------------
# Farben / Logging
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' \
  C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m'
else
  C_RESET="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE=""
fi

msg_info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
msg_ok()    { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
msg_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
msg_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }
die()       { msg_error "$*"; exit 1; }

usage() {
  cat <<EOF
${APP} – Proxmox VE Installer

Usage:
  bash webodm.sh [OPTIONEN]

Optionen:
  --vmid ID             VMID (Default: naechste freie ab 100). Existiert die VM,
                        wird sie aktualisiert statt neu erstellt.
  --hostname NAME       VM-Hostname (Default: ${VM_HOSTNAME})
  --cores N             vCPUs (Default: ${CORES})
  --ram MB              RAM in MiB (Default: ${RAM_MB}; Empfehlung: 16384)
  --disk GB             Disk in GiB (Default: ${DISK_GB})
  --storage NAME        Proxmox-Storage fuer die VM-Disk (Default: auto)
  --bridge NAME         Linux-Bridge (Default: ${BRIDGE})
  --port N              Web-UI-Port (Default: ${APP_PORT})
  --ref REF             WebODM-Branch/Tag (Default: ${WO_REF})
  --os 24.04|22.04      Ubuntu-Cloud-Image (Default: ${OS_VERSION})
  --ip IP               IP fuer Update/SSH erzwingen (sonst Guest-Agent/ARP)
  --ssh-key PATH        Privater SSH-Key (Default: ${SSH_KEY_PATH})
  --force               Update-Modus auch ohne WebODM-Erkennung erzwingen
  --debug               bash -x + erweiterte Diagnose
  -h, --help            diese Hilfe
EOF
}

# ---------------------------------------------------------------------------
# Argumente
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vmid) VMID="$2"; shift 2;;
    --hostname) VM_HOSTNAME="$2"; shift 2;;
    --cores) CORES="$2"; shift 2;;
    --ram|--memory) RAM_MB="$2"; shift 2;;
    --disk) DISK_GB="$2"; shift 2;;
    --storage) STORAGE="$2"; shift 2;;
    --bridge) BRIDGE="$2"; shift 2;;
    --port) APP_PORT="$2"; shift 2;;
    --ref) WO_REF="$2"; shift 2;;
    --os) OS_VERSION="$2"; shift 2;;
    --ip) IP_OVERRIDE="$2"; shift 2;;
    --ssh-key) SSH_KEY_PATH="$2"; shift 2;;
    --force) FORCE=1; shift;;
    --debug) DEBUG=1; shift;;
    -h|--help) usage; exit 0;;
    *) msg_error "Unbekannte Option: $1"; usage; exit 1;;
  esac
done

# ---------------------------------------------------------------------------
# Validierung
# ---------------------------------------------------------------------------
[[ "$(id -u)" == "0" ]] || die "Bitte als root auf dem Proxmox-Host ausfuehren."
command -v qm >/dev/null 2>&1 || die "qm nicht gefunden – das Script muss auf einem Proxmox-VE-Host laufen."
command -v pvesm >/dev/null 2>&1 || die "pvesm nicht gefunden – kein Proxmox-VE-Host?"
[[ -d /etc/pve ]] || die "/etc/pve fehlt – kein Proxmox-VE-Host?"

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
is_uint "$CORES" && (( CORES >= 1 && CORES <= 128 )) || die "--cores muss 1..128 sein."
is_uint "$RAM_MB" && (( RAM_MB >= 4096 )) || die "--ram muss >= 4096 MiB sein (WebODM-Empfehlung: 16384)."
is_uint "$DISK_GB" && (( DISK_GB >= 32 )) || die "--disk muss >= 32 GiB sein."
is_uint "$APP_PORT" && (( APP_PORT >= 1 && APP_PORT <= 65535 )) || die "--port muss 1..65535 sein."
[[ "$VM_HOSTNAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "--hostname ist kein gueltiger DNS-Name."
[[ "$WO_REF" =~ ^[A-Za-z0-9._/-]+$ ]] || die "--ref enthaelt ungueltige Zeichen."
if [[ -n "$VMID" ]]; then
  is_uint "$VMID" && (( VMID >= 100 )) || die "--vmid muss eine Zahl >= 100 sein."
fi
(( RAM_MB >= 6144 )) || msg_warn "Weniger als 6 GB RAM: WebODM kann bei echten Datensaetzen OOM gehen."

ip link show "$BRIDGE" >/dev/null 2>&1 || die "Bridge ${BRIDGE} existiert nicht (ip link)."

case "$OS_VERSION" in
  24.04|noble) CODENAME="noble";;
  22.04|jammy) CODENAME="jammy";;
  *) die "--os unterstuetzt nur 24.04 oder 22.04.";;
esac

# ---------------------------------------------------------------------------
# Logging / Cleanup / Fehlerdiagnose
# ---------------------------------------------------------------------------
umask 077
mkdir -p "$(dirname "$LOG_FILE")"
: > "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -i "$LOG_FILE") 2>&1
msg_info "Host-Log: $LOG_FILE"
if [[ "$DEBUG" == "1" ]]; then echo "--- DEBUG: set -x aktiv ---"; set -x; fi

vm_exists() { qm status "$1" >/dev/null 2>&1; }
ct_exists() { pct status "$1" >/dev/null 2>&1; }

cleanup() {
  [[ -n "$SSH_KEYS_TMP" && -f "$SSH_KEYS_TMP" ]] && rm -f "$SSH_KEYS_TMP"
  [[ -n "$INNER_TMP" && -f "$INNER_TMP" ]] && rm -f "$INNER_TMP"
  return 0
}
trap cleanup EXIT

on_error() {
  local ec=$?
  trap - ERR
  msg_error "FEHLER: »${BASH_COMMAND}« (Exit ${ec})."
  msg_error "Host-Log: ${LOG_FILE}"
  if [[ -n "${VMID:-}" ]] && vm_exists "$VMID"; then
    echo ""
    echo "VM ${VMID} bleibt zur Diagnose erhalten:"
    echo "  qm status ${VMID}"
    echo "  qm terminal ${VMID}          # Serial-Konsole"
    echo "  qm config ${VMID}"
    echo "  Entfernen: qm stop ${VMID}; qm destroy ${VMID} --purge"
  fi
  exit "$ec"
}
trap on_error ERR

# ---------------------------------------------------------------------------
# Storage ermitteln
# ---------------------------------------------------------------------------
if [[ -z "$STORAGE" ]]; then
  mapfile -t CANDIDATES < <(pvesm status --content images 2>/dev/null | awk 'NR>1 && $3 == "active" && $6+0 > 0 {print $1}')
  if (( ${#CANDIDATES[@]} == 0 )); then
    mapfile -t CANDIDATES < <(pvesm status 2>/dev/null | awk 'NR>1 && $3 == "active" {print $1}')
  fi
  if (( ${#CANDIDATES[@]} > 0 )); then
    for s in local-lvm local; do
      for c in "${CANDIDATES[@]}"; do
        if [[ "$c" == "$s" ]]; then
          STORAGE="$s"
          break 2
        fi
      done
    done
    [[ -n "$STORAGE" ]] || STORAGE="${CANDIDATES[0]}"
  fi
fi
[[ -n "$STORAGE" ]] || die "Kein Storage fuer VM-Images gefunden. Bitte --storage angeben (pvesm status)."
pvesm status --storage "$STORAGE" >/dev/null 2>&1 || die "Storage ${STORAGE} existiert nicht (pvesm status)."
msg_ok "Storage: ${STORAGE}"

# ---------------------------------------------------------------------------
# Cloud-Image
# ---------------------------------------------------------------------------
ARCH="amd64"
[[ "$(uname -m)" == "aarch64" ]] && ARCH="arm64"
IMAGE_NAME="${CODENAME}-server-cloudimg-${ARCH}.img"
IMAGE_URL="https://cloud-images.ubuntu.com/${CODENAME}/current/${IMAGE_NAME}"
IMAGE_DIR="/var/lib/vz/template/iso"
IMAGE="${IMAGE_DIR}/${IMAGE_NAME}"

mkdir -p "$IMAGE_DIR"
if [[ ! -s "$IMAGE" ]]; then
  msg_info "Lade Ubuntu ${OS_VERSION} Cloud-Image (${IMAGE_NAME}) ..."
  rm -f "${IMAGE}.part"
  curl -fL --retry 3 --retry-delay 5 --connect-timeout 20 --progress-bar -o "${IMAGE}.part" "$IMAGE_URL"
  mv "${IMAGE}.part" "$IMAGE"
else
  msg_ok "Cloud-Image bereits vorhanden: ${IMAGE}"
fi
qemu-img info "$IMAGE" >/dev/null 2>&1 || die "Cloud-Image ${IMAGE} ist ungueltig/kaputt."
msg_ok "Cloud-Image bereit."

# ---------------------------------------------------------------------------
# SSH-Key
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$SSH_KEY_PATH")"
if [[ ! -f "$SSH_KEY_PATH" ]]; then
  msg_info "Erzeuge SSH-Key ${SSH_KEY_PATH} ..."
  ssh-keygen -q -t ed25519 -N "" -C "${APP_ID}-proxmox" -f "$SSH_KEY_PATH"
fi
grep -q '^ssh-' "$SSH_KEY_PATH" 2>/dev/null && die "--ssh-key erwartet einen PRIVATEN Key, keinen Public Key."
chmod 600 "$SSH_KEY_PATH"
if [[ -f "${SSH_KEY_PATH}.pub" ]]; then
  SSH_PUB="$(cat "${SSH_KEY_PATH}.pub")"
else
  SSH_PUB="$(ssh-keygen -y -P "" -f "$SSH_KEY_PATH" </dev/null)"
fi
[[ "$SSH_PUB" == ssh-* ]] || die "Konnte keinen Public Key aus ${SSH_KEY_PATH} lesen."
msg_ok "SSH-Key: ${SSH_KEY_PATH}"

SSH_OPTS=(
  -i "$SSH_KEY_PATH"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=5
  -o BatchMode=yes
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=20
)

# ---------------------------------------------------------------------------
# VMID / Update-Modus
# ---------------------------------------------------------------------------
if [[ -z "$VMID" ]]; then
  VMID=100
  while vm_exists "$VMID" || ct_exists "$VMID"; do VMID=$((VMID + 1)); done
fi

if ct_exists "$VMID"; then
  die "VMID ${VMID} ist ein LXC-Container. Bitte eine andere --vmid waehlen."
fi

VM_EXISTS=0
if vm_exists "$VMID"; then
  VM_EXISTS=1
  if [[ "$FORCE" != "1" ]]; then
    if ! qm config "$VMID" | grep -qi 'webodm'; then
      die "VM ${VMID} existiert, sieht aber nicht nach WebODM aus. Mit --force erzwingen."
    fi
  fi
  msg_info "VM ${VMID} existiert – Update-Modus (Disk/Cloud-Init bleiben unveraendert)."
else
  [[ -n "$STORAGE" ]] || die "Storage fehlt."
fi

# ---------------------------------------------------------------------------
# VM erstellen
# ---------------------------------------------------------------------------
if [[ "$VM_EXISTS" == "0" ]]; then
  if qm list 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "$VM_HOSTNAME"; then
    msg_warn "VM-Name ${VM_HOSTNAME} ist bereits vergeben – nutze ${VM_HOSTNAME}-${VMID}."
    VM_HOSTNAME="${VM_HOSTNAME}-${VMID}"
  fi
  msg_info "Erstelle VM ${VMID} (${VM_HOSTNAME}) ..."
  qm create "$VMID" \
    --name "$VM_HOSTNAME" \
    --ostype l26 \
    --cpu host \
    --sockets 1 --cores "$CORES" \
    --memory "$RAM_MB" --balloon 0 \
    --scsihw virtio-scsi-pci \
    --net0 "virtio,bridge=${BRIDGE},firewall=0" \
    --agent enabled=1 \
    --serial0 socket \
    --vga std \
    --onboot 1 \
    --description "${APP} – installiert von ${INSTALLER_REPO}"
  msg_ok "VM-Grundgeruest erstellt."

  msg_info "Importiere Cloud-Image nach ${STORAGE} ..."
  IMPORT_OUT="$(qm importdisk "$VMID" "$IMAGE" "$STORAGE" 2>&1)"
  printf '%s\n' "$IMPORT_OUT"
  DISK="$(qm config "$VMID" | awk -F': ' '/^unused0:/ {print $2}')"
  if [[ -z "$DISK" ]]; then
    DISK="$(printf '%s\n' "$IMPORT_OUT" | sed -n "s/.*as '\([^']*\)'.*/\1/p" | tail -n1 | sed -E 's/^unused[0-9]+://')"
  fi
  [[ -n "$DISK" ]] || die "Importierte Disk konnte nicht ermittelt werden."
  msg_ok "Disk importiert: ${DISK}"

  qm set "$VMID" --scsi0 "${DISK},discard=on,ssd=1"
  qm disk resize "$VMID" scsi0 "${DISK_GB}G"
  qm set "$VMID" --boot "order=scsi0"
  qm set "$VMID" --ide2 "${STORAGE}:cloudinit"

  SSH_KEYS_TMP="$(mktemp)"
  printf '%s\n' "$SSH_PUB" > "$SSH_KEYS_TMP"
  qm set "$VMID" --ciuser "$CI_USER"
  qm set "$VMID" --sshkeys "$SSH_KEYS_TMP"
  qm set "$VMID" --ipconfig0 "ip=dhcp"
  qm set "$VMID" --nameserver "1.1.1.1 9.9.9.9"
  qm set "$VMID" --ciupgrade 0
  rm -f "$SSH_KEYS_TMP"; SSH_KEYS_TMP=""

  msg_info "Starte VM ${VMID} ..."
  qm start "$VMID"
  msg_ok "VM gestartet."
else
  STATE="$(qm status "$VMID" 2>/dev/null | awk '{print $2}')"
  if [[ "$STATE" != "running" ]]; then
    msg_info "Starte bestehende VM ${VMID} ..."
    qm start "$VMID"
  fi
fi

# ---------------------------------------------------------------------------
# Gast-Agent / IP
# ---------------------------------------------------------------------------
msg_info "Warte auf den QEMU Guest Agent ..."
AGENT_OK=0
for _ in $(seq 1 60); do
  if timeout 10 qm agent "$VMID" ping >/dev/null 2>&1; then AGENT_OK=1; break; fi
  sleep 3
done
if [[ "$AGENT_OK" == "1" ]]; then
  msg_ok "Guest Agent antwortet."
else
  msg_warn "Guest Agent antwortet noch nicht – nutze ARP/Neighbor-Fallback."
fi

detect_ip() {
  local json ip mac
  if [[ "${AGENT_OK:-0}" == "1" ]]; then
    json="$(timeout 20 qm guest cmd "$VMID" network-get-interfaces 2>/dev/null || true)"
  else
    json=""
  fi
  if [[ -n "$json" ]] && command -v python3 >/dev/null 2>&1; then
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
    [[ -n "$ip" ]] && { printf '%s\n' "$ip"; return 0; }
  fi

  mac="$(qm config "$VMID" 2>/dev/null | grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' | head -n1 || true)"
  if [[ -n "$mac" ]]; then
    ip="$(ip neigh show dev "$BRIDGE" 2>/dev/null | grep -i "$mac" | awk '{print $1}' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | grep -v '^169\.254\.' | head -n1 || true)"
    [[ -n "$ip" ]] && { printf '%s\n' "$ip"; return 0; }
  fi
  return 1
}

sweep_bridge() {
  local subnet i
  subnet="$(ip -4 -o addr show dev "$BRIDGE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | cut -d. -f1-3 || true)"
  [[ "$subnet" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0
  for i in $(seq 1 254); do ping -c1 -W1 "${subnet}.${i}" >/dev/null 2>&1 & done
  wait 2>/dev/null || true
}

IP="$IP_OVERRIDE"
SSH_READY=0
for i in $(seq 1 120); do
  if [[ -z "$IP_OVERRIDE" ]]; then
    if (( i == 1 || i % 12 == 0 )); then sweep_bridge; fi
    NEW_IP="$(detect_ip 2>/dev/null || true)"
    [[ -n "$NEW_IP" ]] && IP="$NEW_IP"
  fi
  if [[ -n "$IP" ]] && ssh "${SSH_OPTS[@]}" "${CI_USER}@${IP}" true >/dev/null 2>&1; then
    SSH_READY=1
    break
  fi
  if (( i % 6 == 0 )); then
    msg_info "  ... warte auf SSH (${i}/120, IP: ${IP:-?})"
  fi
  sleep 5
done

if [[ "$SSH_READY" != "1" ]]; then
  msg_error "Kein SSH-Zugang zur VM."
  echo "  IP: ${IP:-unbekannt}"
  echo "  Konsole: qm terminal ${VMID}"
  echo "  Gast-Agent: qm agent ${VMID} ping"
  echo "  Ggf. --ip <VM-IP> setzen."
  exit 1
fi
msg_ok "SSH erreichbar: ${CI_USER}@${IP}"

# ---------------------------------------------------------------------------
# Innen-Installer uebertragen und ausfuehren
# ---------------------------------------------------------------------------
if [[ -f "${SCRIPT_DIR}/webodm-inner.sh" ]]; then
  INNER="${SCRIPT_DIR}/webodm-inner.sh"
else
  INNER_TMP="$(mktemp)"
  msg_info "Lade Innen-Installer aus ${RAW_BASE} ..."
  curl -fsSL --retry 3 -o "$INNER_TMP" "${RAW_BASE}/install/webodm-inner.sh"
  INNER="$INNER_TMP"
fi
[[ -s "$INNER" ]] || die "Innen-Installer nicht gefunden."

msg_info "Kopiere Innen-Installer in die VM ..."
scp "${SSH_OPTS[@]}" "$INNER" "${CI_USER}@${IP}:/tmp/webodm-inner.sh"

msg_info "Starte Installation in der VM (Docker + WebODM, 10–25 Min beim Erststart) ..."
if ! ssh "${SSH_OPTS[@]}" "${CI_USER}@${IP}" \
  "sudo bash /tmp/webodm-inner.sh --port '${APP_PORT}' --ref '${WO_REF}'"; then
  msg_error "Innen-Installation fehlgeschlagen."
  echo "  Diagnose: ssh -i ${SSH_KEY_PATH} ${CI_USER}@${IP} 'sudo tail -n 250 /var/log/webodm-install.log'"
  echo "  Danach:   qm terminal ${VMID}"
  exit 1
fi
msg_ok "Innen-Installation abgeschlossen."

# ---------------------------------------------------------------------------
# Verifikation vom Proxmox-Host
# ---------------------------------------------------------------------------
HTTP_OK=0
CODE=""
if command -v curl >/dev/null 2>&1; then
  msg_info "Pruefe Web-UI von aussen: http://${IP}:${APP_PORT}/ ..."
  for _ in $(seq 1 24); do
    CODE="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://${IP}:${APP_PORT}/" 2>/dev/null || true)"
    case "$CODE" in
      200|301|302|303|307|308) HTTP_OK=1; break;;
    esac
    sleep 5
  done
fi
if [[ "$HTTP_OK" == "1" ]]; then
  msg_ok "Web-UI erreichbar (HTTP ${CODE})."
else
  msg_warn "Web-UI von aussen nicht erreichbar (HTTP ${CODE:-000}). In der VM wurde localhost bereits geprueft."
  msg_warn "Moegliche Ursache: Firewall/Netz zwischen Proxmox-Host und VM."
fi

echo ""
echo "════════════════ ${APP} VM BEREIT ════════════════"
echo "  VMID        : ${VMID}"
echo "  Hostname    : ${VM_HOSTNAME}"
echo "  Ressourcen  : ${CORES} vCPU / ${RAM_MB} MiB RAM / ${DISK_GB} GiB Disk"
echo "  IP          : ${IP}"
echo "  Web UI      : http://${IP}:${APP_PORT}/"
echo "  Erster Login: Admin-Konto unter http://${IP}:${APP_PORT}/welcome/ anlegen"
echo "                (WebODM hat kein Default-Passwort)"
echo "  SSH         : ssh -i ${SSH_KEY_PATH} ${CI_USER}@${IP}"
echo "  Konsole     : qm terminal ${VMID}"
echo "  Service     : systemctl status ${APP_ID}"
echo "  Update      : dieses Script mit --vmid ${VMID} erneut ausfuehren"
echo "  Reboot-Test : bash tests/reboot-test.sh ${VMID} ${IP} ${APP_PORT}"
echo "  Entfernen   : qm stop ${VMID}; qm destroy ${VMID} --purge"
echo "═══════════════════════════════════════════════════"
