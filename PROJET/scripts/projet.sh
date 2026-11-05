#!/usr/bin/bash
# projet.sh - deploiement du portail de suivi (projet BTC2) et collecte des preuves
# Auteur : David.K
# En root sur srv-core, depuis /root/tp/PROJET :  ./scripts/projet.sh <etape>
#   p0      controle des prerequis (fin du TP3)
#   e8a     depot Zabbix 7.0 + zabbix-agent2, zabbix-get, sysstat (a faire en premier)
#   base    E1 comptes + E2 repertoire publie (setgid, ACL), index.html depose par lea
#   e34     E3 script de publication + E4 units (portail durci, timer)
#   e5      E5 delegation sudo
#   e6      E6 pare-feu (8080 en internal)          -> puis "edge" sur srv-edge
#   e78     E7 non-regression + E8 sondes Zabbix
#   e9      E9 sauvegarde, rotation, restauration
#   charge  mesure sous charge (sar, CPUUsageNSec)
#   audit   E10 : audit conforme, puis deux pannes detectees
#   fin     copie des configs deployees dans configs/
# Sur srv-edge (root, depuis /root/tp/PROJET) : ./scripts/projet.sh edge
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$DIR/configs"
PRV="$DIR/preuves"
WWW=/srv/helios/suivi/www
PW_LEA='Helios-Suivi-2026'      # mot de passe de lab impose par la fiche projet
mkdir -p "$PRV"
[[ $EUID -eq 0 ]] || { echo "a lancer en root"; exit 1; }

titre() { printf '\n\033[1;36m=== %s ===\033[0m\n' "$*"; }
run() { local f="$PRV/$1"; shift
        { printf '$ %s\n' "$*"; eval "$*" 2>&1; printf '\n'; } | tee -a "$f"; }
rc()  { local f="$PRV/$1" att="$2"; shift 2
        { printf '$ %s\n' "$*"; eval "$*" 2>&1; printf -- '-> rc=%s (attendu %s)\n\n' "$?" "$att"; } | tee -a "$f"; }

# duree <commande...> : lance la commande et affiche le temps ecoule
duree() { local t0 t1 ; t0=$(date +%s.%N) ; "$@" ; local r=$? ; t1=$(date +%s.%N)
          awk -v a="$t0" -v b="$t1" 'BEGIN { printf "duree : %.2f s\n", b - a }' ; return $r ; }

# kill -9 du portail et temps de retour a l'etat active (nouveau PID)
kill9_portail() {
  local avant apres t0 t1
  avant=$(systemctl show -p MainPID --value helios-suivi.service)
  echo "PID avant : $avant" ; kill -9 "$avant" ; t0=$(date +%s.%N)
  for _ in $(seq 100); do
    apres=$(systemctl show -p MainPID --value helios-suivi.service)
    if systemctl is-active -q helios-suivi.service && [[ "$apres" != 0 && "$apres" != "$avant" ]]; then break; fi
    sleep 0.2
  done
  t1=$(date +%s.%N)
  awk -v a="$t0" -v b="$t1" -v p="$apres" 'BEGIN { printf "de nouveau active en %.1f s, PID apres : %s\n", b - a, p }'
}

p0() {
  titre "Prerequis (etat de fin du TP3)"
  : > "$PRV/00-prerequis.txt"
  run 00-prerequis.txt "systemctl is-active helios-collect.service ; wc -l /var/lib/helios/telemetry.csv ; sleep 6 ; wc -l /var/lib/helios/telemetry.csv"
  run 00-prerequis.txt "systemctl cat helios.target | head -8"
  run 00-prerequis.txt "firewall-cmd --get-default-zone ; firewall-cmd --get-active-zones"
  run 00-prerequis.txt "sshd -T | grep -E '^(port|allowgroups|passwordauthentication) '"
  run 00-prerequis.txt "systemctl is-active helios-watch-auth.timer"
  run 00-prerequis.txt "ls -ld /var/lib/helios /var/lib/helios/telemetry.csv /srv/helios ; getenforce"
}

e8a() {
  titre "E8.1 Depot Zabbix 7.0, agent, zabbix-get, sysstat"
  : > "$PRV/e8-installation.txt"
  if [[ -f /etc/yum.repos.d/epel.repo ]]; then
    grep -q '^excludepkgs=zabbix' /etc/yum.repos.d/epel.repo || sed -i '/^\[epel\]/a excludepkgs=zabbix*' /etc/yum.repos.d/epel.repo
  fi
  rpm -q zabbix-release >/dev/null 2>&1 || \
    rpm -Uvh https://repo.zabbix.com/zabbix/7.0/rocky/9/x86_64/zabbix-release-latest-7.0.el9.noarch.rpm
  dnf clean all >/dev/null
  dnf -y install zabbix-agent2 zabbix-get sysstat
  systemctl enable --now zabbix-agent2 sysstat.service sysstat-collect.timer sysstat-summary.timer
  run e8-installation.txt "grep -A1 '^\[epel\]' /etc/yum.repos.d/epel.repo 2>/dev/null ; rpm -q zabbix-release zabbix-agent2 zabbix-get sysstat"
  run e8-installation.txt "getent passwd zabbix"
  run e8-installation.txt "grep -E '^(Server|ServerActive)=' /etc/zabbix/zabbix_agent2.conf"
  run e8-installation.txt "systemctl is-active zabbix-agent2 ; systemctl is-enabled zabbix-agent2 ; systemctl is-active sysstat-collect.timer ; systemctl is-enabled sysstat-collect.timer"
  run e8-installation.txt "zabbix_get -s 127.0.0.1 -k agent.ping"
}

base() {
  titre "E1 Comptes et groupe"
  : > "$PRV/e1-comptes.txt"
  getent group suivi >/dev/null || groupadd -g 5003 suivi
  id lea &>/dev/null || useradd -u 5104 -g suivi -c "Lea Fabre - responsable suivi des tournees" -m lea
  echo "lea:$PW_LEA" | chpasswd
  chage -M 90 -m 1 -W 14 -I 7 lea
  id helios-suivi &>/dev/null || useradd -r -d /srv/helios/suivi -M -s /usr/sbin/nologin -c "Portail de suivi Helios" helios-suivi
  run e1-comptes.txt "id lea ; getent passwd lea ; getent group suivi"
  run e1-comptes.txt "chage -l lea"
  run e1-comptes.txt "getent shadow lea | cut -d: -f1,4-7"
  run e1-comptes.txt "id -nG lea | tr ' ' '\n' | grep -xE 'wheel|ssh-admins' || echo 'lea : ni wheel ni ssh-admins'"
  run e1-comptes.txt "id helios-suivi ; getent passwd helios-suivi ; ls -d /home/helios-suivi 2>&1"

  titre "E2 Repertoire publie"
  : > "$PRV/e2-acl.txt"
  install -d -m 2750 -o root -g suivi /srv/helios/suivi
  install -d -m 2770 -o root -g suivi "$WWW"
  chmod 2770 "$WWW"
  # le service traverse suivi et lit/ecrit www ; zabbix traverse sans lister
  setfacl -m u:helios-suivi:r-x,u:zabbix:--x /srv/helios/suivi
  setfacl -m u:helios-suivi:rwx,u:zabbix:--x "$WWW"
  # ce qui est cree dans www : groupe suivi rw, helios-suivi r, autres rien (quel que soit l'umask)
  setfacl -d -m u::rwx,g::rwx,u:helios-suivi:rw-,o::--- "$WWW"
  # telemetrie du TP1 lisible par le compte du portail (ACL, l'unit du TP1 n'est pas touchee)
  setfacl -m u:helios-suivi:r /var/lib/helios/telemetry.csv
  setfacl -m u:helios-suivi:x /var/lib/helios
  su - lea -c "printf '<!doctype html>\n<html lang=\"fr\"><meta charset=\"utf-8\"><title>Suivi des tournees</title>\n<h1>Portail de suivi des tournees Helios</h1>\n<p>Etat du collecteur : <a href=\"etat.json\">etat.json</a> (mis a jour toutes les 2 minutes).</p>\n</html>\n' > $WWW/index.html"
  run e2-acl.txt "ls -ld /srv/helios /srv/helios/suivi $WWW"
  run e2-acl.txt "getfacl -p $WWW"
  run e2-acl.txt "getfacl -p /var/lib/helios/telemetry.csv | grep helios-suivi"
  run e2-acl.txt "su - lea -c 'umask 077 ; echo essai > $WWW/essai-lea.txt' ; ls -l $WWW/ ; getfacl -p $WWW/essai-lea.txt"
  rc  e2-acl.txt "0" "runuser -u helios-suivi -- cat $WWW/essai-lea.txt"
  rc  e2-acl.txt "!=0" "runuser -u nadia -- cat $WWW/essai-lea.txt"
  rc  e2-acl.txt "!=0 (pas de r sur www)" "runuser -u zabbix -- ls $WWW"
  rm -f "$WWW/essai-lea.txt"
  run e2-acl.txt "ls -l $WWW/index.html ; getfacl -p $WWW/index.html"
}

e34() {
  titre "E3 Script de publication"
  : > "$PRV/e3-publication.txt" ; : > "$PRV/e4-units.txt"
  install -m 0755 "$CFG/helios-suivi-publish.sh" /usr/local/sbin/helios-suivi-publish.sh
  install -m 0644 "$CFG/helios-suivi.service" "$CFG/helios-suivi-publish.service" "$CFG/helios-suivi-publish.timer" /etc/systemd/system/
  systemctl daemon-reload
  rc  e3-publication.txt "0" "runuser -u helios-suivi -- /usr/local/sbin/helios-suivi-publish.sh"
  run e3-publication.txt "python3 -m json.tool $WWW/etat.json ; ls -l $WWW/etat.json"
  flock /usr/local/sbin/helios-suivi-publish.sh sleep 4 &
  sleep 1
  rc  e3-publication.txt "2 (verrou tenu)" "runuser -u helios-suivi -- /usr/local/sbin/helios-suivi-publish.sh"
  wait
  rc  e3-publication.txt "3 (lea ne lit pas la telemetrie)" "runuser -u lea -- /usr/local/sbin/helios-suivi-publish.sh"
  rc  e3-publication.txt "3 (helios lit la telemetrie mais n'ecrit pas dans www)" "runuser -u helios -- /usr/local/sbin/helios-suivi-publish.sh"
  run e3-publication.txt "journalctl -t helios-suivi-publish -n 6 --no-pager"
  rc  e3-publication.txt "0 (meme script via son unit durcie)" "systemctl start helios-suivi-publish.service"
  run e3-publication.txt "systemctl status helios-suivi-publish.service --no-pager | head -12"
  rc  e3-publication.txt "0 (stat sans pouvoir lister)" "runuser -u zabbix -- stat -c '%n %s octets %y' $WWW/etat.json"

  titre "E4 Units"
  systemctl enable --now helios-suivi.service helios-suivi-publish.timer
  sleep 3
  run e4-units.txt "systemctl status helios-suivi.service --no-pager | head -14"
  run e4-units.txt "systemctl show -p User -p MemoryMax -p CPUQuotaPerSecUSec -p Restart -p RestartUSec -p PartOf -p WantedBy helios-suivi.service"
  run e4-units.txt "systemctl list-dependencies helios.target --plain --no-pager | grep helios"
  run e4-units.txt "systemd-analyze security helios-suivi.service --no-pager | tail -4"
  run e4-units.txt "curl -s -o /dev/null -w 'GET / -> %{http_code}\n' http://127.0.0.1:8080/ ; curl -s -o /dev/null -w 'GET /etat.json -> %{http_code}\n' http://127.0.0.1:8080/etat.json ; curl -s http://127.0.0.1:8080/etat.json"
  run e4-units.txt "kill9_portail"
  run e4-units.txt "journalctl -u helios-suivi.service -n 6 --no-pager"
  run e4-units.txt "systemctl show -p User -p ReadWritePaths -p ProtectSystem helios-suivi-publish.service ; systemctl list-timers helios-suivi-publish.timer --no-pager"
  run e4-units.txt "systemd-analyze security helios-suivi-publish.service --no-pager | tail -1"
}

e5() {
  titre "E5 Delegation sudo"
  : > "$PRV/e5-sudo.txt"
  run e5-sudo.txt "visudo -cf $CFG/92-helios-suivi"
  install -m 0440 -o root -g root "$CFG/92-helios-suivi" /etc/sudoers.d/92-helios-suivi
  run e5-sudo.txt "ls -l /etc/sudoers.d/ ; visudo -c"
  run e5-sudo.txt "sudo -l -U lea"
  rc  e5-sudo.txt "0" "sudo -l -U lea /usr/bin/systemctl restart helios-suivi.service"
  rc  e5-sudo.txt "!=0 (rien de liste)" "sudo -l -U lea /usr/bin/systemctl restart sshd"
  rc  e5-sudo.txt "!=0 (option ajoutee)" "sudo -l -U lea /usr/bin/journalctl -u helios-suivi.service -n 100 --vacuum-time=1s"
  rc  e5-sudo.txt "!=0" "sudo -l -U lea /usr/bin/journalctl --vacuum-time=1s"
  rc  e5-sudo.txt "0 (essai reel en lea)" "echo '$PW_LEA' | su - lea -c 'sudo -S systemctl restart helios-suivi.service' 2>&1 | grep -v '^$'"
  rc  e5-sudo.txt "0" "echo '$PW_LEA' | su - lea -c 'sudo -S journalctl -u helios-suivi-publish.service -n 100 --no-pager' 2>&1 | tail -3"
  rc  e5-sudo.txt "!=0 (refuse)" "echo '$PW_LEA' | su - lea -c 'sudo -S systemctl restart sshd' 2>&1 | grep -v '^$'"
  run e5-sudo.txt "systemctl is-active helios-suivi.service ; tail -4 /var/log/sudo-suivi.log"
}

e6() {
  titre "E6 Pare-feu"
  : > "$PRV/e6-pare-feu.txt"
  firewall-cmd -q --zone=internal --add-port=8080/tcp
  firewall-cmd -q --permanent --zone=internal --add-port=8080/tcp
  run e6-pare-feu.txt "firewall-cmd --zone=internal --query-port=8080/tcp ; firewall-cmd --permanent --zone=internal --query-port=8080/tcp"
  run e6-pare-feu.txt "firewall-cmd --zone=internal --list-all"
  run e6-pare-feu.txt "for z in \$(firewall-cmd --get-zones) ; do firewall-cmd --zone=\$z --list-all | grep -q 8080 && echo \"8080 dans \$z\" ; done ; true"
  run e6-pare-feu.txt "nft list ruleset | grep 8080"
  run e6-pare-feu.txt "firewall-cmd --get-default-zone ; firewall-cmd --get-active-zones"
  echo ">> srv-edge : ./scripts/projet.sh edge"
}

edge() {
  local f=/tmp/projet-edge.txt ; : > "$f"
  titre "E6 / E7 depuis srv-edge"
  { echo '$ curl -s -o /dev/null -w "%{http_code}\n" http://10.42.0.10:8080/etat.json'
    curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://10.42.0.10:8080/etat.json ; echo
    echo '$ curl -s http://10.42.0.10:8080/etat.json' ; curl -s --max-time 5 http://10.42.0.10:8080/etat.json ; echo
    echo '$ nc -zv -w2 192.168.56.10 8080' ; nc -zv -w2 192.168.56.10 8080 2>&1 ; echo "-> rc=$? (attendu !=0)" ; echo
    echo '$ ssh -p 2242 -o BatchMode=yes lea@192.168.56.10 true' ; ssh -p 2242 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 lea@192.168.56.10 true 2>&1 ; echo "-> rc=$? (attendu !=0)" ; echo
  } | tee -a "$f"
  chmod 644 "$f"
  sleep 11
  su - sysops -c "scp -q -P 2242 -o BatchMode=yes $f sysops@192.168.56.10:" && echo "preuve envoyee a srv-core"
  echo ">> srv-core : ./scripts/projet.sh e78"
}

e78() {
  titre "E7 Non-regression"
  : > "$PRV/e7-non-regression.txt" ; : > "$PRV/e8-sondes.txt"
  [[ -f /home/sysops/projet-edge.txt ]] && cp /home/sysops/projet-edge.txt "$PRV/e6-e7-depuis-srv-edge.txt" && echo "preuve srv-edge recuperee"
  run e7-non-regression.txt "sshd -T | grep -E '^(port|permitrootlogin|passwordauthentication|allowgroups) '"
  run e7-non-regression.txt "journalctl -u sshd --since '-30min' --no-pager | grep -E 'lea' | tail -3"
  run e7-non-regression.txt "systemctl is-active helios-watch-auth.timer helios-collect.service helios-archive.timer firewalld sshd ; journalctl --list-boots --no-pager | tail -3 ; grep -h Storage /etc/systemd/journald.conf.d/*.conf"
  run e7-non-regression.txt "getenforce ; firewall-cmd --get-default-zone ; auditctl -l | wc -l"

  titre "E8 Sondes Zabbix"
  install -m 0644 "$CFG/helios-suivi.conf" /etc/zabbix/zabbix_agent2.d/helios-suivi.conf
  systemctl restart zabbix-agent2
  sleep 2
  run e8-sondes.txt "cat /etc/zabbix/zabbix_agent2.d/helios-suivi.conf"
  run e8-sondes.txt "zabbix_get -s 127.0.0.1 -k helios.suivi.http ; zabbix_get -s 127.0.0.1 -k helios.suivi.age"
  run e8-sondes.txt "systemctl is-active zabbix-agent2 sysstat-collect.timer ; systemctl is-enabled zabbix-agent2 sysstat-collect.timer"
  run e8-sondes.txt "ps -o user,label,cmd -C zabbix_agent2 | head -3 ; ausearch -m AVC -ts recent -i 2>&1 | tail -3"
}

e9() {
  titre "E9 Sauvegarde"
  : > "$PRV/e9-sauvegarde.txt" ; : > "$PRV/e9-restauration.txt"
  install -d -m 0750 -o helios -g helios /srv/helios/archives
  install -d -m 0700 -o root -g root /srv/helios/archives/suivi
  install -m 0755 "$CFG/helios-suivi-backup.sh" /usr/local/sbin/helios-suivi-backup.sh
  [[ -f "$CFG/helios-suivi-audit.sh" ]] && install -m 0750 "$CFG/helios-suivi-audit.sh" /usr/local/sbin/helios-suivi-audit.sh
  install -m 0644 "$CFG/helios-suivi-backup.service" "$CFG/helios-suivi-backup.timer" /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable --now helios-suivi-backup.timer
  rc  e9-sauvegarde.txt "0" "systemctl start helios-suivi-backup.service"
  run e9-sauvegarde.txt "ls -ld /srv/helios/archives ; ls -l /srv/helios/archives/suivi"
  run e9-sauvegarde.txt "cd /srv/helios/archives/suivi && sha256sum -c \$(ls -1t *.sha256 | head -1)"
  run e9-sauvegarde.txt "tar -tvzf \$(ls -1t /srv/helios/archives/suivi/*.tar.gz | head -1)"
  for i in 1 2 3 4 5 6 7 8; do sleep 1.1 ; /usr/local/sbin/helios-suivi-backup.sh ; done
  run e9-sauvegarde.txt "ls -1 /srv/helios/archives/suivi | grep -c 'tar.gz\$' ; journalctl -t helios-suivi-backup -n 3 --no-pager"
  flock /usr/local/sbin/helios-suivi-backup.sh sleep 4 &
  sleep 1
  rc  e9-sauvegarde.txt "2 (verrou tenu)" "/usr/local/sbin/helios-suivi-backup.sh"
  wait
  run e9-sauvegarde.txt "systemctl list-timers helios-suivi-backup.timer --no-pager ; systemctl show -p Persistent helios-suivi-backup.timer"

  titre "E9.5 Restauration"
  local A ; A=$(ls -1t /srv/helios/archives/suivi/suivi-*.tar.gz | head -1)
  rm -rf /root/restauration-test
  run e9-restauration.txt "echo \"archive : $A\" ; date +%T"
  run e9-restauration.txt "mkdir /root/restauration-test && tar --acls --xattrs -xzpf $A -C /root/restauration-test && ls -l /root/restauration-test/srv/helios/suivi/www"
  run e9-restauration.txt "diff <(getfacl -p $WWW | grep -v '^# file') <(getfacl -p /root/restauration-test$WWW | grep -v '^# file') && echo 'ACL de www identiques a la production'"
  run e9-restauration.txt "getfacl -p $WWW/index.html > /root/acl-index-avant.txt ; rm -f $WWW/index.html ; curl -s -o /dev/null -w 'index apres suppression : %{http_code}\n' http://127.0.0.1:8080/index.html"
  run e9-restauration.txt "duree tar --acls --xattrs -xzpf $A -C / srv/helios/suivi/www/index.html"
  run e9-restauration.txt "ls -l $WWW/index.html ; diff /root/acl-index-avant.txt <(getfacl -p $WWW/index.html) && echo 'ACL de index.html identiques'"
  run e9-restauration.txt "curl -s -o /dev/null -w 'index restaure : %{http_code}\n' http://127.0.0.1:8080/index.html ; ls -l --time-style=+%T $WWW ; date +%T"
}

charge() {
  titre "Mesure sous charge"
  : > "$PRV/charge.txt"
  run charge.txt "nproc ; systemctl show -p CPUUsageNSec -p MemoryCurrent -p CPUQuotaPerSecUSec helios-suivi.service"
  LC_ALL=C sar -u 1 40 > /tmp/sar-charge.txt &
  local sarpid=$!
  sleep 2
  run charge.txt "time (for i in \$(seq 2000); do curl -s -o /dev/null http://127.0.0.1:8080/etat.json; done)"
  run charge.txt "systemctl show -p CPUUsageNSec -p MemoryCurrent -p MemoryPeak helios-suivi.service"
  wait "$sarpid"
  run charge.txt "cat /tmp/sar-charge.txt"
  run charge.txt "journalctl -u helios-suivi.service --since '-3min' --no-pager | grep -ci throttl ; cat /sys/fs/cgroup/system.slice/helios-suivi.service/cpu.stat"
}

audit() {
  titre "E10 Audit"
  install -m 0750 "$CFG/helios-suivi-audit.sh" /usr/local/sbin/helios-suivi-audit.sh
  { /usr/local/sbin/helios-suivi-audit.sh ; echo "-> rc=$?" ; } | tee "$PRV/audit.txt"
  : > "$PRV/audit-pannes.txt"
  run audit-pannes.txt "systemctl stop helios-suivi.service ; /usr/local/sbin/helios-suivi-audit.sh ; echo \"-> rc=\$?\""
  systemctl start helios-suivi.service ; sleep 2
  run audit-pannes.txt "firewall-cmd -q --zone=internal --remove-port=8080/tcp ; /usr/local/sbin/helios-suivi-audit.sh | grep -E 'E6|Bilan'"
  firewall-cmd -q --zone=internal --add-port=8080/tcp
  run audit-pannes.txt "/usr/local/sbin/helios-suivi-audit.sh | tail -1"
}

fin() {
  titre "Livrables"
  getfacl -p "$WWW" > "$CFG/getfacl-www.txt"
  firewall-cmd --zone=internal --list-all > "$CFG/firewall-internal.txt"
  for f in helios-suivi.service helios-suivi-publish.service helios-suivi-publish.timer helios-suivi-backup.service helios-suivi-backup.timer ; do
    diff -q "/etc/systemd/system/$f" "$CFG/$f"
  done
  diff -q /etc/sudoers.d/92-helios-suivi "$CFG/92-helios-suivi"
  diff -q /etc/zabbix/zabbix_agent2.d/helios-suivi.conf "$CFG/helios-suivi.conf"
  for s in publish backup audit ; do diff -q /usr/local/sbin/helios-suivi-$s.sh "$CFG/helios-suivi-$s.sh" ; done
  ls -l "$CFG" "$PRV"
  echo ">> git add -A && git commit -m 'PROJET : preuves' && git push"
}

montre() { clear ; cat "$PRV/$1" ; }

case "${1:-}" in
  p0|e8a|base|e34|e5|e6|edge|e78|e9|charge|audit|fin) "$1" ;;
  montre) montre "${2:?fichier}" ;;
  *) sed -n '2,20p' "$0" ; exit 1 ;;
esac
