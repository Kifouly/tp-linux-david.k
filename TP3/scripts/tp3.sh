#!/usr/bin/bash
# tp3.sh - deroule le TP3 (firewalld par zone, durcissement sshd, journald/auditd, detection)
# et enregistre les preuves dans captures/.
# Auteur : David.K
# Usage : en root, depuis le depot : ./scripts/tp3.sh <etape>
#
#   ordre    machine    etape  contenu
#   1        srv-core   m0     interface d'administration enp0s8 (profil NM "admin", 192.168.56.10)
#   2        srv-edge   e1     enp0s8 en 192.168.56.11 (netplan), nmap installe, scan AVANT
#   3        srv-core   m1     Mission 1 : zones, regles riches, ipset, nftables
#   4        srv-edge   e2     scan APRES, nc 22/10051, rafale de 12 connexions
#   5        srv-core   m2a    traces SSH-NEW/REJECT + groupe ssh-admins, compte sysops
#   6        srv-edge   e3     cle ed25519 de sysops, ssh-copy-id, test de connexion par cle
#   7        srv-core   m2     Mission 2 : drop-in, SELinux, pare-feu, crypto-policies
#   8        srv-edge   e4     les 7 tests SSH, scan, envoi des captures srv-edge
#   9        srv-core   m3a    traces des 7 tests, journald persistant, regles auditd, bonus -e 2, REBOOT
#   10       srv-core   m3     list-boots, requetes, auditd, script + timer de detection
#   11       srv-edge   e5     attaque simulee (10 x pirate@), constat du blocage
#   12       srv-core   m3b    preuve du blocage, idempotence, rc=2, deblocage
#   13       srv-edge   e6     acces retabli, envoi des captures srv-edge
#   14       srv-core   fin    livrables configs/, bonus aureport / ssh -Q, criteres
#
#   montre <fichier>   affiche une capture (pour les captures d'ecran)
set -uo pipefail

TP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$TP_DIR/configs"
CAP="$TP_DIR/captures"
CORE=192.168.56.10
EDGE=192.168.56.11
ADM_IF="${ADM_IF:-enp0s8}"
PW3='Helios-TP3-2026'            # mot de passe initial du compte de TP sysops (desactive par le durcissement)
PW2='Helios-TP2-2026'            # mot de passe des comptes du TP2 (julien)
EDGE_CAP=/tmp/tp3-edge           # captures produites sur srv-edge, envoyees a srv-core par scp
[[ $EUID -eq 0 ]] || { echo "A lancer en root (sudo -i)"; exit 1; }
mkdir -p "$CAP"

titre() { printf '\n\033[1;36m=== %s ===\033[0m\n' "$*"; }
# run <fichier> <commande> : affiche et enregistre la commande et sa sortie
run() { local f="$1"; shift; [[ "$f" == /* ]] || f="$CAP/$f"
        { printf '$ %s\n' "$*"; eval "$*" 2>&1; printf '\n'; } | tee -a "$f"; }
# rc <fichier> <attendu> <commande> : idem + code retour
rc()  { local f="$1" att="$2"; shift 2; [[ "$f" == /* ]] || f="$CAP/$f"
        { printf '$ %s\n' "$*"; eval "$*" 2>&1; printf -- '-> rc=%s (attendu %s)\n\n' "$?" "$att"; } | tee -a "$f"; }

########################################################################## srv-core

m0() {
  titre "0. Interface d'administration $ADM_IF"
  : > "$CAP/m0-admin.txt"
  ip link show "$ADM_IF" >/dev/null 2>&1 || { echo "$ADM_IF absente : ajouter l'adaptateur 2 (reseau prive hote) a la VM"; exit 1; }
  # profils automatiques ("Wired connection 2"...) qui occuperaient la carte
  while IFS=: read -r name dev; do
    [[ "$dev" == "$ADM_IF" && "$name" != admin ]] && nmcli con del "$name"
  done < <(nmcli -t -f NAME,DEVICE con show)
  nmcli -t -f NAME con show | grep -qx admin || \
    nmcli con add type ethernet con-name admin ifname "$ADM_IF" \
      ipv4.method manual ipv4.addresses "$CORE/24" ipv4.never-default yes ipv6.method disabled >/dev/null
  nmcli con up admin >/dev/null
  run m0-admin.txt "ip -br addr"
  run m0-admin.txt "ping -c 2 -W 2 192.168.56.1"
}

m1() {
  titre "1.1 Remise en service et etat des lieux"
  : > "$CAP/m1-pare-feu.txt"
  systemctl unmask firewalld 2>/dev/null ; systemctl enable --now firewalld
  run m1-pare-feu.txt "firewall-cmd --state ; firewall-cmd --get-default-zone ; firewall-cmd --get-active-zones"
  run m1-pare-feu.txt "nmcli -g NAME con show | while read -r c ; do printf '%s : %s\n' \"\$c\" \"\$(nmcli -g connection.zone con show \"\$c\")\" ; done"

  titre "1.2 Une zone par interface (dans le profil NetworkManager)"
  NATCON=$(nmcli -t -f NAME,DEVICE con show --active | awk -F: '$2=="enp0s3"{print $1}')
  echo "Connexion NAT : $NATCON" | tee -a "$CAP/m1-pare-feu.txt"
  nmcli con mod "$NATCON" connection.zone drop
  nmcli con mod admin connection.zone work
  nmcli con mod bond0 connection.zone internal
  nmcli con mod bond0.42 connection.zone internal
  for c in "$NATCON" admin bond0 bond0.42 ; do nmcli con up "$c" >/dev/null ; done
  for c in bond0-p1 bond0-p2 ; do nmcli con up "$c" >/dev/null 2>&1 ; done   # ports du bond (TP1)
  firewall-cmd --set-default-zone=drop
  run m1-pare-feu.txt "firewall-cmd --get-default-zone ; firewall-cmd --get-active-zones"

  titre "1.3 Le strict necessaire par zone"
  firewall-cmd --permanent --zone=work --remove-service=dhcpv6-client >/dev/null 2>&1
  firewall-cmd --permanent --zone=work --remove-service=cockpit >/dev/null 2>&1
  firewall-cmd --permanent --zone=work --add-service=ssh
  firewall-cmd --permanent --zone=work --add-source=192.168.56.0/24
  for s in mdns samba-client cockpit dhcpv6-client ; do
    firewall-cmd --permanent --zone=internal --remove-service=$s >/dev/null 2>&1
  done
  firewall-cmd --permanent --zone=internal --add-service=ssh
  firewall-cmd --permanent --zone=internal --add-port=10051/tcp
  firewall-cmd --reload

  titre "1.4 Regles riches, ipset, journalisation des refus"
  firewall-cmd --permanent --zone=work --remove-service=ssh
  firewall-cmd --permanent --zone=work --add-rich-rule='rule service name="ssh" log prefix="SSH-NEW " level="info" limit value="3/m" accept limit value="6/m"'
  firewall-cmd --permanent --zone=work --add-rich-rule='rule port port="10051" protocol="tcp" reject'
  firewall-cmd --permanent --get-ipsets | grep -qw helios-blacklist || \
    firewall-cmd --permanent --new-ipset=helios-blacklist --type=hash:ip \
                 --option=family=inet --option=hashsize=4096 --option=maxelem=65536
  firewall-cmd --permanent --zone=work     --add-rich-rule='rule source ipset="helios-blacklist" drop'
  firewall-cmd --permanent --zone=internal --add-rich-rule='rule source ipset="helios-blacklist" drop'
  firewall-cmd --set-log-denied=unicast
  run m1-pare-feu.txt "firewall-cmd --check-config && firewall-cmd --reload"
  run m1-pare-feu.txt "firewall-cmd --get-ipsets ; firewall-cmd --zone=work --list-rich-rules"
  run m1-pare-feu.txt "firewall-cmd --zone=work --list-all ; firewall-cmd --zone=internal --list-all"

  titre "1.5 Ce que firewalld a reellement ecrit"
  : > "$CAP/m1-nftables.txt"
  run m1-nftables.txt "nft list tables"
  run m1-nftables.txt "nft list chain inet firewalld filter_IN_work"
  run m1-nftables.txt "nft list set inet firewalld helios-blacklist"
  run m1-nftables.txt "iptables -S | head -5"
  echo ">> srv-edge : ./scripts/tp3.sh e2"
}

m2a() {
  titre "1.5 Traces du noyau apres les tests de srv-edge"
  : > "$CAP/m1-traces.txt"
  run m1-traces.txt "journalctl -k -g 'SSH-NEW' -n 20 --no-pager"
  run m1-traces.txt "journalctl -k -g 'REJECT|DROP' -n 20 --no-pager"

  titre "2.1 Groupe ssh-admins et compte sysops"
  : > "$CAP/m2-prep.txt"
  getent group ssh-admins >/dev/null || groupadd -r ssh-admins
  id sysops &>/dev/null || useradd -m -c "Administration systeme (TP3)" sysops
  echo "sysops:$PW3" | chpasswd
  usermod -aG ssh-admins sysops ; usermod -aG ssh-admins julien
  run m2-prep.txt "getent group ssh-admins ; id sysops"
  run m2-prep.txt "for k in /etc/ssh/ssh_host_*_key.pub ; do ssh-keygen -lf \"\$k\" ; done"
  echo ">> srv-edge : ./scripts/tp3.sh e3"
}

m2() {
  titre "2.1 Fichier de cles de sysops"
  : > "$CAP/m2-sshd.txt"
  rc m2-sshd.txt "0600 sysops:sysops" "ls -l /home/sysops/.ssh/authorized_keys"
  [[ -s /home/sysops/.ssh/authorized_keys ]] || { echo "Pas de cle pour sysops : lancer e3 sur srv-edge d'abord"; exit 1; }

  titre "2.2 Drop-in de durcissement"
  install -m 0600 "$CFG/10-helios-hardening.conf" /etc/ssh/sshd_config.d/10-helios-hardening.conf
  install -m 0644 "$CFG/issue.net" /etc/issue.net
  run m2-sshd.txt "head -3 /etc/ssh/sshd_config.d/10-helios-hardening.conf ; ls /etc/ssh/sshd_config.d/"
  rc  m2-sshd.txt "0" "sshd -t && echo 'syntaxe OK'"

  titre "2.4 (avant 2.3) Consequence SELinux du changement de port"
  : > "$CAP/m2-selinux.txt"
  rc  m2-selinux.txt "!=0 (port 2242 non etiquete ssh_port_t)" "systemctl restart sshd"
  run m2-selinux.txt "journalctl -u sshd -n 4 --no-pager -o cat"
  run m2-selinux.txt "ausearch -m AVC -ts recent -i 2>/dev/null | grep -m2 name_bind"
  command -v semanage >/dev/null || dnf -y -q install policycoreutils-python-utils
  semanage port -l | grep -qE '^ssh_port_t.*\b2242\b' || semanage port -a -t ssh_port_t -p tcp 2242
  run m2-selinux.txt "semanage port -l | grep '^ssh_port_t'"

  titre "2.4 Consequence pare-feu"
  firewall-cmd --permanent --zone=work --add-rich-rule='rule port port="2242" protocol="tcp" log prefix="SSH-NEW " level="info" limit value="3/m" accept limit value="6/m"'
  firewall-cmd --permanent --zone=work --remove-rich-rule='rule service name="ssh" log prefix="SSH-NEW " level="info" limit value="3/m" accept limit value="6/m"'
  firewall-cmd --permanent --zone=internal --add-port=2242/tcp
  firewall-cmd --permanent --zone=internal --remove-service=ssh
  firewall-cmd --reload
  run m2-selinux.txt "firewall-cmd --zone=work --list-rich-rules ; firewall-cmd --zone=internal --list-ports"
  rc  m2-selinux.txt "0" "systemctl restart sshd"
  run m2-selinux.txt "ss -ltnp | grep sshd"

  titre "2.3 Algorithmes : crypto-policies"
  : > "$CAP/m2-crypto.txt"
  run m2-crypto.txt "update-crypto-policies --show ; head -6 /etc/ssh/sshd_config.d/50-redhat.conf"
  run m2-crypto.txt "sshd -T | grep -iE '^(kexalgorithms|macs)' | tr ',' '\n' | grep -ci sha1"
  update-crypto-policies --set DEFAULT:NO-SHA1 >/dev/null
  systemctl restart sshd
  run m2-crypto.txt "update-crypto-policies --show ; sshd -T | grep -iE '^(ciphers|kexalgorithms|macs|hostkeyalgorithms)' | tr ',' '\n' | head -20"
  install -m 0600 "$CFG/05-helios-crypto.conf" /etc/ssh/sshd_config.d/05-helios-crypto.conf
  rc  m2-crypto.txt "0" "sshd -t && systemctl restart sshd"
  run m2-crypto.txt "sshd -T | grep -iE '^(ciphers|kexalgorithms|macs|hostkeyalgorithms)'"
  run m2-crypto.txt "ss -ltnp | grep sshd ; journalctl -u sshd -n 6 --no-pager -o short-iso"
  echo ">> srv-edge : ./scripts/tp3.sh e4"
}

m3a() {
  titre "2.5 Traces des 7 tests (cote srv-core)"
  : > "$CAP/m2-traces.txt"
  run m2-traces.txt "journalctl -u sshd --since '-20min' -o short-iso --no-pager | grep -vE 'Server listening|Received signal|Starting|Started|Stopping|Stopped|Deactivated' | tail -40"
  run m2-traces.txt "sshd -T | grep -iE 'permitrootlogin|passwordauthentication|allowgroups|maxauthtries|^port |loglevel|authenticationmethods'"
  recup_edge

  titre "3.1 journald persistant"
  : > "$CAP/m3-journald.txt"
  run m3-journald.txt "journalctl --list-boots --no-pager"
  mkdir -p /etc/systemd/journald.conf.d
  install -m 0644 "$CFG/50-helios.conf" /etc/systemd/journald.conf.d/50-helios.conf
  systemctl restart systemd-journald ; journalctl --flush
  # Seal=yes n'agit qu'avec une cle FSS : la cle de verification est gardee hors du depot
  [[ -f /root/journald-fss-verification.key ]] || \
    journalctl --setup-keys --interval=1h > /root/journald-fss-verification.key 2>/dev/null
  chmod 600 /root/journald-fss-verification.key
  run m3-journald.txt "ls -ld /var/log/journal/\$(cat /etc/machine-id) ; ls /var/log/journal/\$(cat /etc/machine-id) | head"
  run m3-journald.txt "journalctl --disk-usage ; journalctl --verify 2>&1 | tail -5"

  titre "3.3 Regles auditd (chargees avant le redemarrage)"
  : > "$CAP/bonus-immuable.txt"
  systemctl enable --now auditd >/dev/null 2>&1
  sed '/^-e /d' "$CFG/90-helios.rules" > /etc/audit/rules.d/90-helios.rules
  echo '-e 2' >> /etc/audit/rules.d/90-helios.rules
  run bonus-immuable.txt "tail -2 /etc/audit/rules.d/90-helios.rules ; augenrules --load >/dev/null ; auditctl -s | grep -E '^enabled'"
  rc  bonus-immuable.txt "!=0 (regles immuables)" "auditctl -D"
  rc  bonus-immuable.txt "!=0 (regles immuables)" "auditctl -w /tmp -p w -k essai"
  install -m 0640 "$CFG/90-helios.rules" /etc/audit/rules.d/90-helios.rules     # -e 1 : actif au prochain boot
  run bonus-immuable.txt "tail -1 /etc/audit/rules.d/90-helios.rules ; auditctl -s | grep -E '^enabled'"
  echo
  echo ">> Redemarrage dans 10 s (Ctrl+C pour annuler). Ensuite : ./scripts/tp3.sh m3"
  sleep 10 ; systemctl reboot
}

m3() {
  titre "3.1 Apres redemarrage"
  run m3-journald.txt "journalctl --list-boots --no-pager"

  titre "3.2 Requetes d'investigation"
  : > "$CAP/m3-requetes.txt"
  run m3-requetes.txt "journalctl -u sshd.service --since '-2h' -p warning -o short-iso --no-pager | tail -15"
  run m3-requetes.txt "journalctl _SYSTEMD_UNIT=sshd.service -g 'Invalid user|Failed|Accepted' --no-pager | tail -20"
  run m3-requetes.txt "journalctl --facility=authpriv --since today --no-pager | tail -20"
  run m3-requetes.txt "journalctl _UID=5101 --since today --no-pager | tail"
  run m3-requetes.txt "journalctl -t sudo --since today -o json-pretty | head -40"
  run m3-requetes.txt "journalctl -b -1 -p err --no-pager | tail -15"
  run m3-requetes.txt "lastb -n 15 ; last -F -n 10"
  run m3-requetes.txt "lslogins -u --output=USER,PWD-CHANGE,PWD-EXPIR,LAST-LOGIN,FAILED-LOGIN"

  titre "3.3 auditd"
  : > "$CAP/m3-auditd.txt"
  run m3-auditd.txt "auditctl -l ; auditctl -l | wc -l ; auditctl -s | head -5"
  touch /etc/sudoers.d/test-audit && rm -f /etc/sudoers.d/test-audit
  su - julien -c '/usr/local/bin/helios-lastlog >/dev/null'
  echo "$PW2" | su - julien -c 'sudo -S systemctl status helios-collect.service >/dev/null' 2>/dev/null
  sleep 1
  run m3-auditd.txt "ausearch -k sudoers -i | tail -20"
  run m3-auditd.txt "ausearch -k helios-setgid -i | tail -10"
  run m3-auditd.txt "ausearch -k privesc -i --start today | grep -E '^type=(SYSCALL|EXECVE)' | tail -20"
  run m3-auditd.txt "ausearch -m USER_LOGIN,USER_AUTH --start today -i | tail -20"
  run m3-auditd.txt "aureport --auth --summary -i ; aureport --failed --summary -i ; aureport -k --summary -i"

  titre "3.4 Script de detection + timer"
  : > "$CAP/m3-detection.txt"
  install -m 0750 "$CFG/helios-watch-auth.sh" /usr/local/sbin/helios-watch-auth.sh
  install -m 0644 "$CFG/helios-watch-auth.service" "$CFG/helios-watch-auth.timer" /etc/systemd/system/
  install -d -m 0750 /var/lib/helios
  systemctl daemon-reload
  systemctl enable --now helios-watch-auth.timer >/dev/null 2>&1
  run m3-detection.txt "systemd-analyze verify helios-watch-auth.service helios-watch-auth.timer && echo 'units OK'"
  run m3-detection.txt "systemctl list-timers helios-watch-auth.timer --no-pager"
  echo ">> srv-edge : ./scripts/tp3.sh e5   (attaque simulee)"
}

m3b() {
  titre "3.4 Preuve du blocage"
  : > "$CAP/m3-blocage.txt"
  run m3-blocage.txt "journalctl -u sshd --since '-10min' -g 'Invalid user' --no-pager | tail"
  run m3-blocage.txt "systemctl start helios-watch-auth.service ; journalctl -t helios-watch-auth -n 10 --no-pager"
  run m3-blocage.txt "firewall-cmd --ipset=helios-blacklist --get-entries ; cat /var/lib/helios/blocked.txt"
  run m3-blocage.txt "nft list set inet firewalld helios-blacklist"
  run m3-blocage.txt "journalctl -k -g 'DROP|REJECT' --since '-10min' --no-pager | tail -5"

  titre "3.4 Idempotence et verrou"
  rc  m3-blocage.txt "0" "/usr/local/sbin/helios-watch-auth.sh"
  run m3-blocage.txt "journalctl -t helios-watch-auth -n 3 --no-pager -o cat ; grep -c 'ALERTE' <(journalctl -t helios-watch-auth --since '-15min' -o cat)"
  flock /run/helios-watch-auth.lock sleep 4 &
  sleep 1
  rc  m3-blocage.txt "2 (une instance tient le verrou)" "/usr/local/sbin/helios-watch-auth.sh"
  wait

  titre "3.4 Deblocage de srv-edge"
  systemctl stop helios-watch-auth.timer
  firewall-cmd --ipset=helios-blacklist --remove-entry=$EDGE >/dev/null
  sed -i "/$EDGE/d" /var/lib/helios/blocked.txt
  systemd-run --on-active=11min --timer-property=RemainAfterElapse=no systemctl start helios-watch-auth.timer
  run m3-blocage.txt "firewall-cmd --ipset=helios-blacklist --get-entries ; systemctl is-active helios-watch-auth.timer ; systemctl list-timers --all --no-pager | grep -E 'run-|helios-watch'"
  echo ">> srv-edge : ./scripts/tp3.sh e6"
}

recup_edge() {   # captures envoyees par srv-edge (scp vers sysops)
  local f
  for f in /home/sysops/edge-*.txt ; do
    [[ -f "$f" ]] && cp "$f" "$CAP/" && echo "recupere : $(basename "$f")"
  done
}

fin() {
  titre "Livrables"
  recup_edge
  firewall-cmd --list-all-zones > "$CFG/zones.txt"
  diff -q /etc/ssh/sshd_config.d/10-helios-hardening.conf "$CFG/10-helios-hardening.conf"
  : > "$CAP/bonus-revue.txt"
  run bonus-revue.txt "auditctl -s | grep -E '^enabled' ; tail -1 /etc/audit/rules.d/90-helios.rules"
  run bonus-revue.txt "aureport --start this-week --summary -i"
  run bonus-revue.txt "aureport --executable --summary -i | head -15"
  run bonus-revue.txt "ssh -Q cipher | tr '\n' ' ' ; echo ; ssh -Q kex | tr '\n' ' ' ; echo"
  run bonus-revue.txt "sshd -T | grep -iE '^(ciphers|kexalgorithms|macs|authenticationmethods)'"

  : > "$CAP/criteres.txt"
  run criteres.txt "firewall-cmd --get-default-zone ; firewall-cmd --get-active-zones"
  run criteres.txt "grep -E '^\\$|rc=|attendu' $CAP/edge-e4-tests.txt 2>/dev/null | head -30"
  run criteres.txt "sshd -T | grep -E '^(passwordauthentication|allowgroups|port|permitrootlogin) '"
  run criteres.txt "semanage port -l | grep ssh_port_t"
  run criteres.txt "journalctl -k -g SSH-NEW --no-pager | wc -l"
  run criteres.txt "journalctl --list-boots --no-pager | wc -l"
  run criteres.txt "auditctl -l | wc -l ; ausearch -k sudoers -i 2>/dev/null | grep -c '^type=SYSCALL'"
  run criteres.txt "grep -h 'ALERTE' $CAP/m3-blocage.txt | head -2"
  run criteres.txt "systemctl list-timers --all helios-watch-auth.timer --no-pager"
  ls -l "$CFG" "$CAP"
  echo ">> git add -A && git commit -m 'TP3 : preuves collectees' && git push"
}

########################################################################## srv-edge

edge_init() { mkdir -p "$EDGE_CAP" ; chmod 755 "$EDGE_CAP" ; }
# envoie les captures de srv-edge dans le home de sysops sur srv-core (port 2242 apres la Mission 2)
envoie() {
  chmod 644 "$EDGE_CAP"/*.txt
  su - sysops -c "scp -q -P ${1:-2242} -o BatchMode=yes -o StrictHostKeyChecking=accept-new $EDGE_CAP/*.txt sysops@$CORE:" \
    && echo "captures srv-edge envoyees a srv-core" || echo "envoi impossible (refait a l'etape suivante)"
}

e1() {
  edge_init ; local f="$EDGE_CAP/edge-e1-avant.txt" ; : > "$f"
  titre "srv-edge : $ADM_IF en $EDGE"
  netplan set "ethernets.$ADM_IF.dhcp4=false"
  netplan set "ethernets.$ADM_IF.addresses=[$EDGE/24]"
  netplan apply ; sleep 3
  command -v nmap >/dev/null || { apt-get -qq update ; DEBIAN_FRONTEND=noninteractive apt-get -qq -y install nmap ; }
  run "$f" "ip -br addr show $ADM_IF ; ping -c 2 -W 2 $CORE"
  titre "Scan AVANT la Mission 1"
  run "$f" "nmap -Pn -p 22,80,111,9090,10051 $CORE"
  echo ">> srv-core : ./scripts/tp3.sh m1"
}

e2() {
  edge_init ; local f="$EDGE_CAP/edge-e2-apres.txt" ; : > "$f"
  titre "Scan APRES la Mission 1"
  run "$f" "nmap -Pn -p 22,80,111,9090,10051 $CORE"
  rc  "$f" "0" "nc -zv -w2 $CORE 22"
  rc  "$f" "!=0 (reject)" "nc -zv -w 2 $CORE 10051"
  sleep 10
  run "$f" "for i in \$(seq 1 12); do nc -zv -w1 $CORE 22 2>&1 | sed 's/^/'\$i' : /' ; done"
  echo ">> srv-core : ./scripts/tp3.sh m2a"
}

e3() {
  edge_init ; local f="$EDGE_CAP/edge-e3-cle.txt" ; : > "$f"
  titre "2.1 Cle ed25519 de sysops et depot sur srv-core"
  id sysops &>/dev/null || useradd -m -s /bin/bash -c "Administration systeme (TP3)" sysops
  su - sysops -c "test -f ~/.ssh/id_ed25519 || ssh-keygen -q -t ed25519 -a 100 -C 'sysops@srv-edge' -f ~/.ssh/id_ed25519 -N ''"
  run "$f" "su - sysops -c 'ssh-keygen -lf ~/.ssh/id_ed25519.pub'"
  # mot de passe du compte de TP fourni par SSH_ASKPASS, uniquement pour ce depot de cle
  local ask ; ask=$(mktemp /tmp/askpass.XXXXXX) ; printf '#!/bin/sh\necho %s\n' "$PW3" > "$ask"
  chmod 755 "$ask"
  run "$f" "su - sysops -c 'SSH_ASKPASS=$ask SSH_ASKPASS_REQUIRE=force DISPLAY=none setsid -w ssh-copy-id -o StrictHostKeyChecking=accept-new -i ~/.ssh/id_ed25519.pub sysops@$CORE' 2>&1 | grep -v '^$'"
  rm -f "$ask"
  rc  "$f" "0 (par cle, sans mot de passe)" "su - sysops -c \"ssh -o BatchMode=yes sysops@$CORE 'hostname ; id'\""
  echo ">> srv-core : ./scripts/tp3.sh m2"
}

e4() {
  edge_init ; local f="$EDGE_CAP/edge-e4-tests.txt" ; : > "$f"
  local S="su - sysops -c"
  titre "Scan APRES la Mission 2"
  run "$f" "nmap -Pn -p 22,2242,10051 $CORE"
  sleep 12                          # la limite 6/m ne laisse passer que 5 connexions en rafale
  titre "2.5 Les sept tests"
  rc "$f" "!=0 (1. ancien port)"  "nc -zv -w2 $CORE 22"
  rc "$f" "0 (2. sysops par cle)" "$S \"ssh -p 2242 -o BatchMode=yes -o StrictHostKeyChecking=accept-new sysops@$CORE 'hostname; id -nG'\""
  rc "$f" "!=0 (3. root)"         "$S \"ssh -p 2242 -o BatchMode=yes root@$CORE id\""
  rc "$f" "!=0 (4. mot de passe)" "$S \"ssh -p 2242 -o BatchMode=yes -o PubkeyAuthentication=no -o PreferredAuthentications=password sysops@$CORE true\""
  rc "$f" "!=0 (5. nadia hors ssh-admins)" "$S \"ssh -p 2242 -o BatchMode=yes nadia@$CORE true\""
  run "$f" "$S \"ssh -p 2242 -o BatchMode=yes -N -L 9999:localhost:10051 sysops@$CORE & sleep 3 ; nc -zv -w2 127.0.0.1 9999 ; sleep 1 ; kill \\\$! 2>/dev/null\" ; echo '6. tunnel : refus cote serveur (voir journal sshd)'"
  sleep 15
  rc "$f" "!=0 (7. KEX SHA-1)" "$S \"ssh -p 2242 -o BatchMode=yes -o KexAlgorithms=diffie-hellman-group14-sha1 sysops@$CORE true\""
  sleep 12
  envoie
  echo ">> srv-core : ./scripts/tp3.sh m3a"
}

e5() {
  edge_init ; local f="$EDGE_CAP/edge-e5-attaque.txt" ; : > "$f"
  titre "3.4 Attaque simulee : 10 connexions pirate@"
  run "$f" "for i in \$(seq 1 10); do ssh -p 2242 -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=3 pirate@$CORE true 2>/dev/null ; echo \"essai \$i rc=\$?\" ; done"
  echo "Attente du passage du timer (2 min)..." ; sleep 140
  titre "srv-edge est-elle bloquee ?"
  rc "$f" "!=0 (bloquee par l'ipset)" "nc -zv -w3 $CORE 2242"
  rc "$f" "!=0 (bloquee par l'ipset)" "su - sysops -c \"ssh -p 2242 -o BatchMode=yes -o ConnectTimeout=5 sysops@$CORE true\""
  echo ">> srv-core : ./scripts/tp3.sh m3b"
}

e6() {
  edge_init ; local f="$EDGE_CAP/edge-e6-retabli.txt" ; : > "$f"
  titre "Acces retabli apres deblocage"
  rc "$f" "0" "su - sysops -c \"ssh -p 2242 -o BatchMode=yes sysops@$CORE 'hostname; id -nG'\""
  sleep 11
  envoie
  echo ">> srv-core : ./scripts/tp3.sh fin"
}

montre() { clear ; cat "$CAP/$1" 2>/dev/null || cat "$EDGE_CAP/$1" ; }

case "${1:-}" in
  m0|m1|m2a|m2|m3a|m3|m3b|fin|e1|e2|e3|e4|e5|e6) "$1" ;;
  montre) montre "${2:?fichier}" ;;
  *) sed -n '2,25p' "$0" ; exit 1 ;;
esac
