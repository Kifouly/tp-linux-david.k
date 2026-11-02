#!/usr/bin/bash
# tp1.sh — deroule le TP1 etape par etape et enregistre les preuves dans TP1/captures/
# Auteur : David.K
# Usage  : sudo -i ; cd <depot>/TP1 ; ./scripts/tp1.sh <etape>
#
# Ordre (srv-core sauf mention) :
#   m1-boot-avant   chiffre le boot, allege, puis demande un reboot
#   m1-boot-apres   rechiffre le boot apres reboot
#   m1-service      service collecteur, kill -9, drop-in, target, priorites
#   m2-edge         (sur srv-edge) IP metier + VLAN 42
#   m2-core         bond0 + VLAN 42 + table de routage transport
#   m2-bascule      ping pendant la coupure du lien (action sur l'hote)
#   m2-verif        apres reboot : persistance reseau
#   m3              script d'archivage, 3 codes retour, timer, cron
#   bonus           path unit sur /srv/helios/inbox
#   collecte        rassemble les livrables + verifie les criteres + remplit RAPPORT.md
set -uo pipefail

TP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$TP_DIR/configs"
CAP="$TP_DIR/captures"
IF1="${IF1:-enp0s9}"     # adaptateur 3 VirtualBox (reseau interne helios-lan)
IF2="${IF2:-enp0s10}"    # adaptateur 4 VirtualBox (reseau interne helios-lan)
EDGE_IF="${EDGE_IF:-enp0s9}"
mkdir -p "$CAP"

titre() { printf '\n\033[1;36m=== %s ===\033[0m\n' "$*"; }
# run <fichier> <commande...> : affiche et enregistre la commande et sa sortie
run() { local f="$CAP/$1"; shift
        { printf '$ %s\n' "$*"; eval "$*" 2>&1; printf '\n'; } | tee -a "$f"; }
pause() { read -r -p "$* [Entree pour continuer] " _; }
[[ $EUID -eq 0 ]] || { echo "A lancer en root (sudo -i)"; exit 1; }

m1_boot_avant() {
  titre "1.1 Boot AVANT allegement"
  : > "$CAP/boot-avant.txt"
  run boot-avant.txt "systemd-analyze"
  run boot-avant.txt "systemd-analyze blame | head -15"
  run boot-avant.txt "systemd-analyze critical-chain"
  systemd-analyze plot > "$CAP/boot-avant.svg"
  cp "$CAP/boot-avant.svg" /root/boot-avant.svg
  titre "Allegement"
  run boot-avant.txt "systemctl disable --now firewalld"   # temporaire, reactive au TP3
  run boot-avant.txt "systemctl mask NetworkManager-wait-online.service"
  echo ">> Redemarre maintenant (systemctl reboot) puis lance : ./scripts/tp1.sh m1-boot-apres"
}

m1_boot_apres() {
  titre "1.1 Boot APRES allegement"
  : > "$CAP/boot-apres.txt"
  run boot-apres.txt "systemd-analyze"
  run boot-apres.txt "systemd-analyze blame | head -15"
  run boot-apres.txt "systemd-analyze critical-chain"
  systemd-analyze plot > "$CAP/boot-apres.svg"
  cp "$CAP/boot-apres.svg" /root/boot-apres.svg
}

m1_service() {
  titre "1.2 Service de collecte"
  install -d -m 0755 /usr/local/sbin /var/lib/helios /var/log/helios
  install -m 0755 "$CFG/helios-collect.sh" /usr/local/sbin/helios-collect.sh
  id helios &>/dev/null || useradd --system --shell /sbin/nologin --home-dir /var/lib/helios helios
  chown -R helios:helios /var/lib/helios /var/log/helios
  install -m 0644 "$CFG/helios-collect.service" /etc/systemd/system/helios-collect.service
  rm -f /etc/systemd/system/helios-collect.service.d/override.conf   # score « avant » propre
  systemctl daemon-reload && systemctl enable --now helios-collect.service
  : > "$CAP/security-avant.txt"
  run security-avant.txt "systemd-analyze security helios-collect.service --no-pager"

  titre "1.3 Survie a kill -9"
  : > "$CAP/kill9.txt"
  run kill9.txt "systemctl show -p MainPID --value helios-collect.service"
  run kill9.txt 'kill -9 "$(systemctl show -p MainPID --value helios-collect.service)"'
  run kill9.txt "sleep 8 ; systemctl status helios-collect.service --no-pager | head -5"
  run kill9.txt "systemctl show -p MainPID -p NRestarts --value helios-collect.service"
  run kill9.txt "journalctl -u helios-collect.service -n 8 --no-pager"

  titre "1.3 Drop-in (equivalent de systemctl edit)"
  install -d -m 0755 /etc/systemd/system/helios-collect.service.d
  install -m 0644 "$CFG/override.conf" /etc/systemd/system/helios-collect.service.d/override.conf
  systemctl daemon-reload && systemctl restart helios-collect.service
  : > "$CAP/dropin.txt"
  run dropin.txt "systemctl cat helios-collect.service"
  run dropin.txt "systemctl show -p CPUQuotaPerSecUSec -p MemoryMax -p Nice -p IOWeight -p Environment helios-collect.service"
  run dropin.txt "systemctl is-active helios-collect.service"
  run dropin.txt "systemd-cgls --no-pager /system.slice/helios-collect.service"
  run dropin.txt "systemd-cgtop --iterations=3 -b | head -30"
  run dropin.txt "sleep 12 ; tail -3 /var/lib/helios/telemetry.csv"
  : > "$CAP/security-apres.txt"
  run security-apres.txt "systemd-analyze security helios-collect.service --no-pager"

  titre "1.4 Target metier"
  install -m 0644 "$CFG/helios.target" /etc/systemd/system/helios.target
  systemctl daemon-reload
  systemctl add-wants helios.target helios-collect.service
  systemctl enable helios.target
  : > "$CAP/target.txt"
  run target.txt "systemctl list-dependencies helios.target --no-pager"
  run target.txt "systemctl stop helios.target && systemctl start helios.target && systemctl is-active helios-collect.service"

  titre "1.4 Priorites CPU / E-S"
  : > "$CAP/priorites.txt"
  nice -n 19 sha256sum /dev/zero & NPID=$!
  sleep 1
  run priorites.txt "ps -o pid,ni,pri,cls,rtprio,comm -p $NPID"
  run priorites.txt "renice -n 5 -p $NPID"
  run priorites.txt "ionice -c 2 -n 7 -p $NPID ; ionice -p $NPID"
  run priorites.txt "chrt -p $NPID"
  run priorites.txt "ps -o pid,ni,pri,cls,rtprio,comm -p $NPID"
  kill "$NPID"
}

m2_edge() {
  titre "2.1/2.3 srv-edge : IP metier + VLAN 42"
  for c in metier vlan42; do nmcli -t -f NAME con show | grep -qx "$c" && nmcli con del "$c"; done
  nmcli con add type ethernet con-name metier ifname "$EDGE_IF" \
    ipv4.method manual ipv4.addresses 10.42.0.11/24 ipv4.never-default yes ipv6.method disabled
  nmcli con up metier
  nmcli con add type vlan con-name vlan42 ifname "${EDGE_IF}.42" dev "$EDGE_IF" id 42 \
    ipv4.method manual ipv4.addresses 10.42.42.11/24 ipv4.never-default yes ipv6.method disabled
  nmcli con up vlan42
  ip -br addr
}

m2_core() {
  titre "2.1 Agregation active-backup"
  ip -br link
  echo "Interfaces utilisees : IF1=$IF1 (primaire)  IF2=$IF2  (surcharge : IF1=... IF2=... ./scripts/tp1.sh m2-core)"
  # profils existants qui occupent deja ces cartes (ex. socle du README)
  for ifc in "$IF1" "$IF2"; do
    while IFS=: read -r name dev; do
      [[ "$dev" == "$ifc" && "$name" != bond0-p* ]] || continue
      read -r -p "Le profil '$name' occupe $ifc. Le supprimer ? [o/N] " r
      [[ "$r" =~ ^[oOyY]$ ]] && nmcli con del "$name"
    done < <(nmcli -t -f NAME,DEVICE con show)
  done
  for c in bond0.42 bond0-p1 bond0-p2 bond0; do nmcli -t -f NAME con show | grep -qx "$c" && nmcli con del "$c"; done

  nmcli con add type bond con-name bond0 ifname bond0 \
    bond.options "mode=active-backup,miimon=100,primary=${IF1},fail_over_mac=active" \
    ipv4.method manual ipv4.addresses 10.42.0.10/24 ipv4.never-default yes ipv6.method disabled
  nmcli con add type ethernet con-name bond0-p1 ifname "$IF1" master bond0
  nmcli con add type ethernet con-name bond0-p2 ifname "$IF2" master bond0
  nmcli con up bond0 ; nmcli con up bond0-p1 ; nmcli con up bond0-p2
  sleep 2
  : > "$CAP/bond-etat.txt"
  run bond-etat.txt "cat /proc/net/bonding/bond0"
  run bond-etat.txt "ip -d link show bond0"
  run bond-etat.txt "ping -c 3 10.42.0.11"

  titre "2.3 VLAN 42"
  nmcli con add type vlan con-name bond0.42 ifname bond0.42 dev bond0 id 42 \
    ipv4.method manual ipv4.addresses 10.42.42.10/24 ipv4.never-default yes ipv6.method disabled
  nmcli con up bond0.42
  : > "$CAP/vlan42.txt"
  run vlan42.txt "ip -d link show bond0.42 | grep -A1 vlan"
  rpm -q tcpdump &>/dev/null || dnf -y install tcpdump
  : > "$CAP/tcpdump-vlan42.txt"
  tcpdump -nei bond0 -c 5 'vlan 42' > "$CAP/tcpdump-vlan42.txt" 2>&1 & TPID=$!
  sleep 1 ; ping -c 5 10.42.42.11 | tee -a "$CAP/vlan42.txt" ; wait "$TPID"
  cat "$CAP/tcpdump-vlan42.txt"

  titre "2.4 Table de routage transport + regle"
  grep -qs '^142' /etc/iproute2/rt_tables || echo '142 transport' >> /etc/iproute2/rt_tables
  nmcli con mod bond0.42 \
    +ipv4.routes "0.0.0.0/0 10.42.42.11 table=142" \
    +ipv4.routing-rules "priority 100 from 10.42.42.10/32 table 142"
  nmcli con up bond0.42
  : > "$CAP/routage.txt"
  run routage.txt "ip rule show"
  run routage.txt "ip route show table transport"
  run routage.txt "ip route get 8.8.8.8 from 10.42.42.10"
  run routage.txt "ip route get 8.8.8.8"
  echo ">> Lance maintenant : ./scripts/tp1.sh m2-bascule"
}

m2_bascule() {
  titre "2.2 Bascule du bond"
  : > "$CAP/bascule-bond.txt"
  run bascule-bond.txt "grep -E 'Currently Active Slave|Slave Interface|MII Status' /proc/net/bonding/bond0"
  ping -i 0.5 -c 80 10.42.0.11 > "$CAP/bascule-ping.txt" 2>&1 & PPID_=$!
  echo "Sur le PORTABLE HOTE lance :  VBoxManage controlvm srv-core setlinkstate3 off"
  pause "Lien coupe ?"
  sleep 2
  echo "--- PENDANT LA COUPURE ---" >> "$CAP/bascule-bond.txt"
  run bascule-bond.txt "grep -E 'Currently Active Slave|Slave Interface|MII Status' /proc/net/bonding/bond0"
  run bascule-bond.txt "cat /proc/net/bonding/bond0"
  run bascule-bond.txt "journalctl -k -n 20 --no-pager | grep -i bond"
  echo "Sur l'hote lance maintenant :  VBoxManage controlvm srv-core setlinkstate3 on"
  pause "Lien retabli ?"
  wait "$PPID_"
  echo "--- APRES RETABLISSEMENT ---" >> "$CAP/bascule-bond.txt"
  run bascule-bond.txt "grep -E 'Currently Active Slave|Slave Interface|MII Status' /proc/net/bonding/bond0"
  echo "--- PING PENDANT LE TEST ---" >> "$CAP/bascule-bond.txt"
  tail -4 "$CAP/bascule-ping.txt" | tee -a "$CAP/bascule-bond.txt"
  echo ">> Ensuite : systemctl reboot, puis ./scripts/tp1.sh m2-verif"
}

m2_verif() {
  titre "Persistance apres reboot"
  : > "$CAP/reseau-apres-reboot.txt"
  run reseau-apres-reboot.txt "ip -br addr"
  run reseau-apres-reboot.txt "grep -E 'Bonding Mode|Currently Active Slave|Slave Interface|MII Status' /proc/net/bonding/bond0"
  run reseau-apres-reboot.txt "ip rule show"
  run reseau-apres-reboot.txt "ip route show table transport"
  run reseau-apres-reboot.txt "ip route get 8.8.8.8 from 10.42.42.10"
  run reseau-apres-reboot.txt "ip route get 8.8.8.8"
  run reseau-apres-reboot.txt "ping -c 2 10.42.0.11 ; ping -c 2 10.42.42.11"
}

m3() {
  titre "3.1 Script d'archivage"
  install -m 0750 "$CFG/helios-archive.sh" /usr/local/sbin/helios-archive.sh
  : > "$CAP/archive-rc.txt"
  /usr/local/sbin/helios-archive.sh ; rc0=$?
  echo "rc_ok=$rc0   (attendu 0)" | tee -a "$CAP/archive-rc.txt"
  ( exec 9>/run/lock/helios-archive.lock ; flock 9 ; sleep 20 ) &
  sleep 1 ; /usr/local/sbin/helios-archive.sh ; rc2=$? ; wait
  echo "rc_verrou=$rc2   (attendu 2)" | tee -a "$CAP/archive-rc.txt"
  mv /var/lib/helios/telemetry.csv /tmp/t.csv
  /usr/local/sbin/helios-archive.sh ; rc3=$?
  mv /tmp/t.csv /var/lib/helios/telemetry.csv
  echo "rc_source_absente=$rc3   (attendu 3)" | tee -a "$CAP/archive-rc.txt"
  run archive-rc.txt "journalctl -t helios-archive -n 15 --no-pager"
  run archive-rc.txt "ls -l /var/lib/helios/archives"

  titre "3.2 Timer systemd"
  install -m 0644 "$CFG/helios-archive.service" /etc/systemd/system/
  install -m 0644 "$CFG/helios-archive.timer"   /etc/systemd/system/
  systemctl daemon-reload && systemctl enable --now helios-archive.timer
  : > "$CAP/timer.txt"
  run timer.txt "systemd-analyze calendar '*-*-* 02:30:00' --iterations=3"
  run timer.txt "systemctl list-timers helios-archive.timer --all --no-pager"
  run timer.txt "systemctl start helios-archive.service && systemctl status helios-archive.service --no-pager"
  run timer.txt "systemctl show -p Nice -p IOSchedulingClass helios-archive.service"
  run timer.txt "systemctl list-dependencies --reverse helios-archive.service --no-pager"

  titre "3.2 Equivalent cron (pour comparaison), puis retrait"
  : > "$CAP/cron.txt"
  rpm -q cronie &>/dev/null || dnf -y install cronie
  systemctl enable --now crond
  printf 'MAILTO=""\n30 2 * * * root /usr/local/sbin/helios-archive.sh\n' > /etc/cron.d/helios-legacy
  run cron.txt "cat /etc/cron.d/helios-legacy"
  run cron.txt "systemctl restart crond ; journalctl -u crond -n 10 --no-pager"
  run cron.txt "grep -i anacron /etc/cron.d/0hourly /etc/anacrontab 2>/dev/null"
  rm -f /etc/cron.d/helios-legacy && systemctl restart crond
  run cron.txt "ls /etc/cron.d/"
}

bonus() {
  titre "Bonus : path unit"
  install -d -m 0775 -o helios -g helios /srv/helios/inbox
  install -m 0644 "$CFG/helios-inbox.path" /etc/systemd/system/
  systemctl daemon-reload && systemctl enable --now helios-inbox.path
  : > "$CAP/bonus-path.txt"
  run bonus-path.txt "touch /srv/helios/inbox/test-\$(date +%s).csv ; sleep 3 ; journalctl -t helios-archive -n 5 --no-pager"
  run bonus-path.txt "systemctl status helios-inbox.path --no-pager | head -6"
}

collecte() {
  titre "Livrables"
  nmcli -f all con show bond0 > "$CFG/bond0.txt"
  # on verifie que les fichiers du depot sont bien ceux qui tournent
  for f in helios-collect.service helios.target helios-archive.service helios-archive.timer helios-inbox.path; do
    [[ -f /etc/systemd/system/$f ]] && { diff -q "$CFG/$f" "/etc/systemd/system/$f" >/dev/null || echo "!! $f differe du deploye"; }
  done
  diff -q "$CFG/override.conf" /etc/systemd/system/helios-collect.service.d/override.conf || true

  titre "Criteres de reussite"
  : > "$CAP/criteres.txt"
  run criteres.txt "systemctl is-enabled helios-collect.service"
  run criteres.txt "systemctl show -p MemoryMax helios-collect.service"
  run criteres.txt "systemctl list-dependencies helios.target --no-pager | grep helios-collect"
  run criteres.txt "grep -E 'Currently Active Slave|MII Status' /proc/net/bonding/bond0"
  run criteres.txt "ip route get 8.8.8.8 from 10.42.42.10"
  run criteres.txt "ip route get 8.8.8.8"
  run criteres.txt "cat $CAP/archive-rc.txt | grep rc_"
  run criteres.txt "systemctl list-timers helios-archive.timer --no-pager"

  titre "Remplissage de RAPPORT.md"
  python3 - "$TP_DIR" <<'PY'
import pathlib, re, sys
tp = pathlib.Path(sys.argv[1]); cap = tp / "captures"
def rd(n):
    p = cap / n
    return p.read_text(errors="replace") if p.exists() else ""
def first(pat, txt, d="_(non mesure)_"):
    m = re.search(pat, txt, re.M); return m.group(1).strip() if m else d
def blame(txt):
    m = re.search(r"\$ systemd-analyze blame \| head -15\n(.*?)\n\n", txt, re.S)
    return m.group(1).rstrip() if m else "(non mesure)"
ba, bp = rd("boot-avant.txt"), rd("boot-apres.txt")
sa, sp = rd("security-avant.txt"), rd("security-apres.txt")
rc, pg = rd("archive-rc.txt"), rd("bascule-ping.txt")
vals = {
 "BOOT_AVANT": first(r"^(Startup finished in .*)$", ba),
 "BOOT_APRES": first(r"^(Startup finished in .*)$", bp),
 "BLAME_AVANT": blame(ba), "BLAME_APRES": blame(bp),
 "SEC_AVANT": first(r"Overall exposure level for \S+: (.*)$", sa),
 "SEC_APRES": first(r"Overall exposure level for \S+: (.*)$", sp),
 "RC_OK": first(r"rc_ok=(\d+)", rc), "RC_VERROU": first(r"rc_verrou=(\d+)", rc),
 "RC_ABSENT": first(r"rc_source_absente=(\d+)", rc),
 "PING_BASCULE": first(r"^(\d+ packets transmitted.*)$", pg),
}
f = tp / "RAPPORT.md"; t = f.read_text()
for k, v in vals.items():
    t = t.replace("{{" + k + "}}", v)
f.write_text(t)
for k, v in vals.items(): print(f"{k:14} {v.splitlines()[0] if v else v}")
PY
  echo
  echo ">> Relis RAPPORT.md puis : git add -A && git commit -m 'TP1 : preuves et rapport' && git push"
}

case "${1:-}" in
  m1-boot-avant) m1_boot_avant ;;  m1-boot-apres) m1_boot_apres ;;
  m1-service)    m1_service ;;
  m2-edge)       m2_edge ;;        m2-core)  m2_core ;;
  m2-bascule)    m2_bascule ;;     m2-verif) m2_verif ;;
  m3)            m3 ;;             bonus)    bonus ;;
  collecte)      collecte ;;
  *) sed -n '2,20p' "$0" ; exit 1 ;;
esac
