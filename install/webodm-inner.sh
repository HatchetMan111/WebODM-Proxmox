#!/usr/bin/env bash
#
# webodm-inner.sh – laeuft IN der WebODM-VM (Ubuntu 22.04/24.04) als root bzw. via sudo.
#
# Wird vom Host-Installer (install/webodm.sh) per SSH in die VM kopiert und
# dort ausgefuehrt. Kann aber auch direkt in einer Ubuntu-VM laufen:
#
#   sudo bash webodm-inner.sh
#   sudo bash webodm-inner.sh --port 8000 --data-dir /opt/webodm-data --ref master --debug
#
# Aufgaben:
#   1. Docker CE + Compose-Plugin installieren
#   2. WebODM (https://github.com/WebODM/WebODM) nach /opt/webodm klonen/aktualisieren
#   3. Datenverzeichnisse /opt/webodm-data/{media,db,node} anlegen
#   4. systemd-Unit webodm.service installieren (Restart=always, After=network-online.target)
#   5. Docker-Images ziehen, Dienst starten, Web-UI auf localhost:PORT verifizieren
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Variablen (oben, Community-Scripts-konform – alles hier anpassbar)
# ---------------------------------------------------------------------------
APP="webodm"
APP_DIR="/opt/webodm"
DATA_DIR="/opt/webodm-data"
APP_PORT="8000"
WO_REF="master"

UPSTREAM_REPO="https://github.com/WebODM/WebODM"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/HatchetMan111/WebODM-Proxmox/main}"
SERVICE_URL="${SERVICE_URL:-$RAW_BASE/systemd/webodm.service}"

DEBUG="${DEBUG:-0}"
LOG_FILE="${LOG_FILE:-/var/log/webodm-install.log}"
HTTP_OK=0
VERSION="unknown"

# ---------------------------------------------------------------------------
# Logging / Farben (Community-Scripts-Stil)
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

usage() {
  cat <<EOF
${APP} Innen-Installer (laeuft in der Ubuntu-VM)

Usage:
  sudo bash webodm-inner.sh [OPTIONEN]

Optionen:
  --port N             Web-UI-Port im Host (Default: ${APP_PORT})
  --app-dir PATH       Installationsverzeichnis (Default: ${APP_DIR})
  --data-dir PATH      Datenverzeichnis media/db/node (Default: ${DATA_DIR})
  --ref REF            WebODM-Branch/Tag (Default: ${WO_REF})
  --debug              bash -x + maximale Fehlermeldungskette
  -h, --help           diese Hilfe
EOF
}

# ---------------------------------------------------------------------------
# Argumente
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) APP_PORT="$2"; shift 2;;
    --app-dir) APP_DIR="$2"; shift 2;;
    --data-dir) DATA_DIR="$2"; shift 2;;
    --ref) WO_REF="$2"; shift 2;;
    --debug) DEBUG="1"; shift;;
    -h|--help) usage; exit 0;;
    *) msg_error "Unbekannte Option: $1"; usage; exit 1;;
  esac
done

[[ "$(id -u)" == "0" ]] || { msg_error "Bitte als root bzw. mit sudo ausfuehren."; exit 1; }
command -v apt-get >/dev/null || { msg_error "apt-get nicht gefunden – ist das Ubuntu/Debian?"; exit 1; }
[[ "$APP_PORT" =~ ^[0-9]+$ ]] && (( APP_PORT >= 1 && APP_PORT <= 65535 )) || { msg_error "--port muss 1..65535 sein."; exit 1; }
[[ "$APP_DIR" == /* && "$APP_DIR" != *[[:space:]]* ]] || { msg_error "--app-dir muss ein absoluter Pfad ohne Leerzeichen sein."; exit 1; }
[[ "$DATA_DIR" == /* && "$DATA_DIR" != *[[:space:]]* ]] || { msg_error "--data-dir muss ein absoluter Pfad ohne Leerzeichen sein."; exit 1; }
[[ "$WO_REF" =~ ^[A-Za-z0-9._/-]+$ ]] || { msg_error "--ref enthaelt ungueltige Zeichen."; exit 1; }

umask 077
mkdir -p "$(dirname "$LOG_FILE")"
: > "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -i "$LOG_FILE") 2>&1
msg_info "Logdatei: $LOG_FILE"
[[ "$DEBUG" == "1" ]] && { echo "--- DEBUG: set -x aktiv ---"; set -x; }

compose() {
  ( cd "$APP_DIR" && sudo -u "$APP" -H env \
      WO_PORT="$APP_PORT" \
      WO_MEDIA_DIR="$DATA_DIR/media" \
      WO_DB_DIR="$DATA_DIR/db" \
      WO_NODE_DIR="$DATA_DIR/node" \
      WO_DEFAULT_NODES=1 \
      docker compose -f docker-compose.yml -f docker-compose.nodeodm.yml "$@" )
}

# Vollstaendige Fehlerkette: Befehl, Zeile, Exit-Code, Service-/Container-Logs.
dump_diagnostics() {
  trap - ERR
  set +e
  echo ""
  echo "════════════════ DIAGNOSE ════════════════"
  echo "--- systemctl status ${APP} ---"
  systemctl status "$APP" --no-pager -l 2>&1 | tail -n 120
  echo "--- journalctl -u ${APP} (letzte 250 Zeilen) ---"
  journalctl -u "$APP" --no-pager -n 250 2>&1
  echo "--- systemctl status docker ---"
  systemctl status docker --no-pager -l 2>&1 | tail -n 80
  echo "--- journalctl -u docker (letzte 120 Zeilen) ---"
  journalctl -u docker --no-pager -n 120 2>&1
  echo "--- docker ps -a ---"
  docker ps -a 2>&1
  echo "--- docker compose ps ---"
  compose ps 2>&1
  echo "--- docker compose logs (letzte 250 Zeilen) ---"
  compose logs --tail=250 2>&1
  echo "--- Ports ---"
  ss -tlnp 2>&1 | grep -E ":${APP_PORT}|:8000" || true
  echo "--- Speicher / Disk ---"
  free -h 2>&1
  df -h 2>&1
  echo "--- Installationslog (letzte 250 Zeilen) ---"
  tail -n 250 "$LOG_FILE" 2>&1
  echo "════════════════ ENDE DIAGNOSE ════════════════"
}
on_error() {
  local ec=$?
  trap - ERR
  msg_error "FEHLER: Befehl »${BASH_COMMAND}« scheiterte in Zeile ${LINENO} (Exit ${ec})."
  msg_error "Vollstaendiges Log: ${LOG_FILE} – bei Bedarf erneut mit --debug laufen lassen."
  dump_diagnostics
  exit "$ec"
}
trap on_error ERR

# ---------------------------------------------------------------------------
# 1. Systempakete
# ---------------------------------------------------------------------------
msg_info "Installiere Systempakete (idempotent) ..."
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg git sudo iproute2 procps qemu-guest-agent
systemctl enable --now qemu-guest-agent >/dev/null 2>&1 || msg_warn "qemu-guest-agent konnte nicht gestartet werden (nicht kritisch)."
msg_ok "Systempakete installiert."

# Test-VMs mit wenig RAM bekommen Swap, damit WebODM beim Erststart nicht OOM geht.
MEM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
if (( MEM_MB < 8192 )) && ! swapon --show 2>/dev/null | grep -q .; then
  msg_info "Wenig RAM (${MEM_MB} MiB) – lege 4 GiB Swap an ..."
  if fallocate -l 4G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=4096 status=none 2>/dev/null; then
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    msg_ok "4 GiB Swap aktiv."
  else
    rm -f /swapfile
    msg_warn "Swap konnte nicht angelegt werden – fahre ohne Swap fort."
  fi
fi

# ---------------------------------------------------------------------------
# 2. Docker CE + Compose-Plugin (offizielles Docker-Repo)
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  msg_info "Installiere Docker CE + Compose-Plugin ..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  # shellcheck disable=SC1091
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y --no-install-recommends \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
  msg_ok "Docker + Compose-Plugin bereits vorhanden."
fi
systemctl enable --now docker

msg_info "Warte auf Docker-Daemon ..."
DOCKER_OK=0
for _ in $(seq 1 24); do
  if docker info >/dev/null 2>&1; then DOCKER_OK=1; break; fi
  sleep 5
done
if [[ "$DOCKER_OK" != "1" ]]; then
  msg_error "Docker-Daemon antwortet nicht (docker info)."
  dump_diagnostics
  exit 1
fi
msg_ok "Docker laeuft: $(docker --version)"
msg_ok "Compose: $(docker compose version --short 2>/dev/null || docker compose version)"

# ---------------------------------------------------------------------------
# 3. Benutzer + Verzeichnisse
# ---------------------------------------------------------------------------
msg_info "Lege Benutzer ${APP} und Datenverzeichnisse an ..."
id "$APP" >/dev/null 2>&1 || useradd -m -s /bin/bash "$APP"
usermod -aG docker "$APP"
install -d -m 0755 -o "$APP" -g "$APP" \
  "$APP_DIR" \
  "$DATA_DIR" "$DATA_DIR/media" "$DATA_DIR/db" \
  "$DATA_DIR/node" "$DATA_DIR/node/data" "$DATA_DIR/node/tmp"
msg_ok "Benutzer ${APP}, Verzeichnisse ${APP_DIR} und ${DATA_DIR} bereit."

# ---------------------------------------------------------------------------
# 4. WebODM-Quellcode (GitHub-first)
# ---------------------------------------------------------------------------
msg_info "Hole WebODM (${WO_REF}) von ${UPSTREAM_REPO} ..."
if [[ -d "$APP_DIR/.git" ]]; then
  sudo -u "$APP" -H git -C "$APP_DIR" remote set-url origin "$UPSTREAM_REPO"
  sudo -u "$APP" -H git -C "$APP_DIR" fetch --depth 1 origin "$WO_REF"
  sudo -u "$APP" -H git -C "$APP_DIR" reset --hard FETCH_HEAD
else
  rm -rf "$APP_DIR"
  install -d -m 0755 -o "$APP" -g "$APP" "$APP_DIR"
  sudo -u "$APP" -H git clone --depth 1 --branch "$WO_REF" "$UPSTREAM_REPO" "$APP_DIR"
fi
chown -R "$APP:$APP" "$APP_DIR"
VERSION="$(sudo -u "$APP" -H git -C "$APP_DIR" describe --tags --always 2>/dev/null || true)"
[[ -n "$VERSION" ]] || VERSION="$(sudo -u "$APP" -H git -C "$APP_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
msg_ok "WebODM-Quellcode bereit: ${VERSION}"

# Secret Key persistent halten (wird von webodm.sh gelesen/erzeugt)
if [[ ! -s "$APP_DIR/.secret_key" ]]; then
  head -c50 /dev/urandom | base64 | tr -d '\n' > "$APP_DIR/.secret_key"
fi
chown "$APP:$APP" "$APP_DIR/.secret_key"
chmod 600 "$APP_DIR/.secret_key"

# ---------------------------------------------------------------------------
# 5. systemd-Unit
# ---------------------------------------------------------------------------
msg_info "Installiere systemd-Unit ${APP}.service ..."
if [[ -s "$APP_DIR/webodm.sh" ]]; then
  :
else
  msg_error "webodm.sh fehlt in ${APP_DIR} – Klon unvollstaendig."
  exit 1
fi
chmod +x "$APP_DIR/webodm.sh"

UNIT_TMP="$(mktemp)"
if curl -fsSL --max-time 30 -o "$UNIT_TMP" "$SERVICE_URL" 2>/dev/null && [[ -s "$UNIT_TMP" ]]; then
  sed -e "s|@APP_PORT@|${APP_PORT}|g" \
      -e "s|@APP_DIR@|${APP_DIR}|g" \
      -e "s|@DATA_DIR@|${DATA_DIR}|g" \
      "$UNIT_TMP" > "/etc/systemd/system/${APP}.service"
  msg_ok "${APP}.service aus Repo uebernommen."
else
  msg_warn "Service-URL nicht erreichbar – schreibe Inline-Unit."
  cat > "/etc/systemd/system/${APP}.service" <<UNIT
[Unit]
Description=WebODM – lokale Drohnen-Fotogrammetrie (Web-UI :${APP_PORT})
Documentation=https://github.com/WebODM/WebODM
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service
StartLimitIntervalSec=0

[Service]
Type=simple
User=${APP}
Group=${APP}
WorkingDirectory=${APP_DIR}
Environment=HOME=/home/${APP}
Environment=PYTHONUNBUFFERED=1
Environment=WO_PORT=${APP_PORT}
ExecStart=${APP_DIR}/webodm.sh start --port ${APP_PORT} --media-dir ${DATA_DIR}/media --db-dir ${DATA_DIR}/db --node-dir ${DATA_DIR}/node --default-nodes 1
ExecStop=-${APP_DIR}/webodm.sh stop
Restart=always
RestartSec=15
TimeoutStartSec=0
TimeoutStopSec=180
KillMode=process

[Install]
WantedBy=multi-user.target
UNIT
fi
rm -f "$UNIT_TMP"
systemctl daemon-reload
systemctl enable "$APP"

# Laufende Instanz sauber stoppen, damit Update/Neustart deterministisch ist.
systemctl stop "$APP" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 6. Images ziehen (frueh scheitern statt im systemd-Neustart-Loop)
# ---------------------------------------------------------------------------
msg_info "Ziehe WebODM-Docker-Images (kann beim ersten Mal 10–20 Min dauern) ..."
compose pull
msg_ok "Docker-Images bereit."

# ---------------------------------------------------------------------------
# 7. Start + Verifikation
# ---------------------------------------------------------------------------
msg_info "Starte ${APP}.service ..."
systemctl restart "$APP"

msg_info "Warte auf die Web-UI auf localhost:${APP_PORT} (max. 30 Min, Migration/Erststart) ..."
for i in $(seq 1 120); do
  CODE="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "http://localhost:${APP_PORT}/" 2>/dev/null || true)"
  case "$CODE" in
    200|301|302|303|307|308) HTTP_OK=1; break;;
  esac
  if (( i % 4 == 0 )); then
    msg_info "  ... ${i}/120 (HTTP ${CODE:-000}, Service: $(systemctl is-active "$APP" 2>/dev/null || echo unknown))"
  fi
  sleep 15
done

if [[ "$HTTP_OK" != "1" ]]; then
  msg_error "Web-UI antwortet nicht auf http://localhost:${APP_PORT}/ (HTTP ${CODE:-000})."
  exit 1
fi
msg_ok "Web-UI antwortet (HTTP ${CODE} auf localhost:${APP_PORT})."

if ss -tln 2>/dev/null | grep -q ":${APP_PORT} "; then
  msg_ok "Port ${APP_PORT} lauscht (0.0.0.0)."
else
  msg_warn "Port ${APP_PORT} in 'ss -tln' nicht sichtbar – bitte docker ps pruefen."
fi

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "${APP_PORT}/tcp" || msg_warn "ufw-Regel fuer ${APP_PORT}/tcp konnte nicht gesetzt werden."
  msg_ok "ufw: Port ${APP_PORT}/tcp freigegeben."
fi

echo ""
echo "--- Laufende Container ---"
docker ps --format '{{.Names}}\t{{.Status}}' | grep -E 'webapp|db|broker|worker|node-odx-1' || true

VM_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo ""
echo "════════════════ WEBODM IN DER VM BEREIT ════════════════"
echo "  App          : WebODM ${VERSION}"
echo "  Web UI       : http://${VM_IP:-<VM-IP>}:${APP_PORT}/"
echo "  Erster Login : Admin-Konto unter /welcome/ anlegen (kein Default-Passwort)"
echo "  Service      : systemctl status ${APP}"
echo "  Daten        : ${DATA_DIR} (media, db, node)"
echo "  Update       : Host-Installer erneut ausfuehren (idempotent)"
echo "  Log          : ${LOG_FILE}"
echo "═════════════════════════════════════════════════════════"
