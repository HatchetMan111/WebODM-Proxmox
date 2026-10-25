# WebODM auf Proxmox VE

Ein Einzeiler-Installer im Stil der Proxmox Community Scripts: Erstellt eine
Ubuntu-Cloud-Init-VM, installiert Docker und [WebODM](https://github.com/WebODM/WebODM)
und richtet einen reboot-festen `systemd`-Dienst ein.

WebODM ist eine kostenlose, quelloffene Plattform für Drohnen-Fotogrammetrie:
Bilder hochladen, Punktwolken, Orthophotos, DSM/DTM und 3D-Modelle erzeugen.

## Was wird installiert?

| Komponente | Detail |
|---|---|
| VM | Ubuntu 24.04 LTS (Cloud Image), KVM, QEMU Guest Agent |
| Ressourcen | **Testdefault:** 2 vCPU, 6 GB RAM, 32 GB Disk (per Flags vergrößerbar) |
| App | WebODM aus `github.com/WebODM/WebODM` (`master`) |
| Stack | `webapp`, `db` (PostgreSQL), `broker` (Redis), `worker`, `node-odx-1` |
| Dienst | `webodm.service`, `Restart=always`, Start nach `network-online.target` und `docker.service` |
| Daten | `/opt/webodm-data/{media,db,node}` (persistent) |
| Web-UI | `http://<VM-IP>:8000/` |

Es gibt **kein Default-Passwort**. Beim ersten Aufruf leitet WebODM auf
`/welcome/` und du legst dort das Admin-Konto an.

## Voraussetzungen

- Proxmox VE 8.x (7.x sollte funktionieren)
- Root-SSH auf dem Proxmox-Host
- Internetzugang des Hosts (Cloud-Image, Docker Hub, GitHub)
- Eine Linux-Bridge, standardmäßig `vmbr0`
- Storage für VM-Disks, standardmäßig automatisch (`local-lvm` → `local`)
- **Testdefault:** 2 vCPU, 6 GB RAM, 32 GB Disk – reicht für Installation und
  einen kleinen Test-Datensatz.
- **Produktiv:** mindestens 16 GB RAM und 100 GB Disk für sinnvolle
  Fotogrammetrie; größere Datensätze entsprechend mehr.

## Schnellstart

Auf dem **Proxmox-Host** als root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/WebODM-Proxmox/main/install/webodm.sh)"
```

Das Script fragt nichts ab, wählt die nächste freie VMID ab 100, erstellt die VM
und installiert WebODM. Der Erststart dauert typischerweise 10–25 Minuten
(Docker-Images ziehen, Datenbank-Migration).

Danach:

```text
http://<VM-IP>:8000/welcome/
```

Lokale Variante:

```bash
git clone https://github.com/HatchetMan111/WebODM-Proxmox.git
cd WebODM-Proxmox
sudo bash install/webodm.sh
```

## Optionen

```text
--vmid ID             VMID (Default: nächste freie ab 100)
--hostname NAME       VM-Hostname (Default: webodm)
--cores N             vCPUs (Default: 2)
--ram MB              RAM in MiB (Default: 6144)
--disk GB             Disk in GiB (Default: 32)
--storage NAME        Proxmox-Storage (Default: automatisch)
--bridge NAME         Linux-Bridge (Default: vmbr0)
--port N              Web-UI-Port (Default: 8000)
--ref REF             WebODM-Branch/Tag (Default: master)
--os 24.04|22.04      Ubuntu-Version (Default: 24.04)
--ip IP               IP für Update/SSH erzwingen
--ssh-key PATH        Privater SSH-Key (Default: /root/.ssh/webodm_vm_ed25519)
--force               Update-Modus ohne WebODM-Erkennung erzwingen
--debug               bash -x + erweiterte Diagnose
```

Beispiele:

```bash
# Eigene Ressourcen und Storage
bash install/webodm.sh --vmid 210 --cores 8 --ram 32768 --disk 250 --storage local-lvm

# Anderer Port und WebODM-Tag
bash install/webodm.sh --port 8080 --ref v3.3.1

# Bestehende VM aktualisieren (gleiche VMID)
bash install/webodm.sh --vmid 210
```

## Nach der Installation

1. `http://<VM-IP>:8000/` öffnen.
2. Auf `/welcome/` das Admin-Konto anlegen.
3. Erst danach die Instanz in einem größeren Netz freigeben.

Das Script zeigt am Ende IP, VMID, SSH-Befehl und Update-Befehl an.

### Ressourcen

Die Defaults sind bewusst klein gehalten, damit der erste Test auf einem
knappen Host durchläuft. Für mittlere Datensätze (100–500 Bilder) sind
16 GB RAM und 100 GB Disk ein guter Start. Für größere Projekte:

```bash
bash install/webodm.sh --vmid 210 --cores 8 --ram 32768 --disk 500
```

Der `worker` läuft mit erhöhtem `oom_score_adj`, damit bei Speicherdruck eher
der Worker als Datenbank/Web-UI beendet wird. Trotzdem gilt: zu wenig RAM
führt zu OOM und fehlgeschlagenen Tasks.

### Update

Erneut mit derselben VMID ausführen:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/WebODM-Proxmox/main/install/webodm.sh)" -- --vmid 210
```

Der Innen-Installer macht `git fetch` + `reset --hard`, zieht neue Images und
startet den Dienst neu. Medien, Datenbank und Node-Daten bleiben erhalten.

Vorher idealerweise einen Snapshot machen:

```bash
qm snapshot 210 pre-webodm-update
```

### Backup

Alles liegt auf der VM-Disk:

- `/opt/webodm-data/db` – PostgreSQL-Daten
- `/opt/webodm-data/media` – Bilder, Projekte, Ergebnisse
- `/opt/webodm-data/node` – NodeODX-Daten

Backup-Optionen:

```bash
# VM-Snapshot (schnell, kein konsistentes DB-Backup für laufende writes)
qm snapshot 210 backup-$(date +%F)

# Proxmox Backup Server / vzdump
vzdump 210 --storage <backup-storage> --mode snapshot
```

Für ein konsistentes DB-Backup den Dienst kurz stoppen:

```bash
ssh -i /root/.ssh/webodm_vm_ed25519 ubuntu@<VM-IP> \
  'sudo systemctl stop webodm && sudo tar czf /root/webodm-data.tgz -C /opt webodm-data && sudo systemctl start webodm'
```

### Reboot-Test

Auf dem Proxmox-Host:

```bash
bash tests/reboot-test.sh 210 <VM-IP> 8000
```

Der Test prüft Dienst, Container, HTTP und Datenverzeichnisse, führt
`qm reboot` aus und verifiziert danach erneut. Ohne IP wird der Guest Agent
bzw. die ARP-Tabelle benutzt.

### Deinstallation

```bash
qm stop 210
qm destroy 210 --purge
```

Damit werden auch alle Daten auf der VM-Disk gelöscht.

## Troubleshooting

**VM startet, aber kein SSH / keine IP erkannt**

```bash
qm terminal 210          # Serial-Konsole, Enter drücken
qm agent 210 ping
qm config 210
```

Cloud-Init braucht 30–60 Sekunden. Bei DHCP-Problemen im Gast:

```bash
qm terminal 210
ip a
```

Falls der Host die VM-IP nicht über Guest Agent/ARP finden kann (z. B. VLAN),
den Installer mit bekannter IP erneut ausführen:

```bash
bash install/webodm.sh --vmid 210 --ip 192.168.1.50
```

**Web-UI nicht erreichbar**

```bash
# in der VM
sudo systemctl status webodm
sudo journalctl -u webodm -n 200 --no-pager
cd /opt/webodm
sudo -u webodm docker compose -f docker-compose.yml -f docker-compose.nodeodm.yml ps
sudo -u webodm docker compose -f docker-compose.yml -f docker-compose.nodeodm.yml logs --tail=200
sudo ss -tlnp | grep 8000
```

**Installation fehlgeschlagen**

Das Host-Script zeigt die VMID und lässt die VM zur Diagnose stehen. In der VM:

```bash
sudo tail -n 250 /var/log/webodm-install.log
```

Erneut mit mehr Details:

```bash
sudo bash /tmp/webodm-inner.sh --port 8000 --debug
```

**OOM / Tasks brechen ab**

RAM erhöhen:

```bash
qm shutdown 210
qm set 210 --memory 32768
qm start 210
```

**Port ändern**

```bash
bash install/webodm.sh --vmid 210 --port 8080
```

Der Innen-Installer schreibt die Unit neu und startet den Dienst.

**SSH-Key vergessen**

Der Key liegt standardmäßig unter `/root/.ssh/webodm_vm_ed25519`. Bei einem
eigenen Key muss dieser beim Erstinstall angegeben werden; ein späterer
Key-Wechsel wird nicht automatisch in Cloud-Init übernommen.

## Sicherheit

- WebODM wird ohne TLS auf Port 8000 ausgeliefert. Nicht direkt ins Internet
  stellen. LAN, VPN oder Reverse Proxy mit TLS davor.
- Nach dem ersten Start sofort das Admin-Konto unter `/welcome/` anlegen.
- Upstream setzt `ALLOWED_HOSTS=['*']`; der Schutz kommt über Netzgrenze und
  Reverse Proxy.
- Docker-Socket-Zugriff hat der Benutzer `webodm` (Docker-Gruppe). Das ist für
  den Betrieb nötig und entspricht dem Upstream-Setup.
- Updates regelmäßig einspielen; vorher Snapshot.

## Projektstruktur

```text
WebODM-Proxmox/
├── install/
│   ├── webodm.sh          # Host-Installer: VM, Cloud-Init, SSH, Aufruf
│   └── webodm-inner.sh    # In-VM: Docker, WebODM, systemd, Healthcheck
├── systemd/
│   └── webodm.service     # Unit mit @APP_PORT@/@APP_DIR@/@DATA_DIR@
├── tests/
│   ├── static-checks.sh   # Syntax/Struktur, ohne Proxmox ausführbar
│   └── reboot-test.sh     # echter Reboot-Test auf dem Proxmox-Host
└── README.md
```

## Hinweise

- Das Script ist idempotent ausgelegt: erneutes Ausführen mit `--vmid`
  aktualisiert die Installation.
- Die VM nutzt DHCP. Für eine feste IP kann `--ip` beim Update genutzt werden;
  die Cloud-Init-Konfiguration bleibt beim Update unverändert.
- Getestet wurde die statische Struktur in einer Sandbox. Der vollständige
  VM-/Reboot-Test muss auf einem echten Proxmox-Host laufen
  (`tests/reboot-test.sh`).

## Credits

- [WebODM](https://github.com/WebODM/WebODM) – BSD-3-Clause
- [OpenDroneMap](https://www.opendronemap.org/)
- Installer-Struktur inspiriert von den Proxmox Community Scripts
