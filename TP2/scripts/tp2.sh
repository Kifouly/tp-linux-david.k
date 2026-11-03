#!/usr/bin/bash
# tp2.sh — deroule le TP2 (comptes, bits speciaux, ACL, sudo) et enregistre les preuves
# Auteur : David.K
# Usage  : sudo -i ; cd /root/tp/TP2 ; ./scripts/tp2.sh <etape>
#   m1       politique d'authentification, groupes, comptes, faillock
#   m2       setgid / sticky / umask / setuid / helios-lastlog
#   m3       ACL POSIX (nominatives, par defaut, masque, sauvegarde)
#   m4       delegation sudo, sudoreplay, evasion via sudo vim puis correction sudoedit
#   bonus    audit (lecture seule)
#   collecte livrables configs/ + criteres
#   montre <fichier>  affiche une capture (pour les captures d'ecran)
set -uo pipefail

TP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$TP_DIR/configs"
CAP="$TP_DIR/captures"
PW='Helios-TP2-2026'          # mot de passe initial impose par l'enonce (comptes de TP)
T=/srv/helios/projets/transport
mkdir -p "$CAP"
[[ $EUID -eq 0 ]] || { echo "A lancer en root (sudo -i)"; exit 1; }

titre() { printf '\n\033[1;36m=== %s ===\033[0m\n' "$*"; }
# run <fichier> <commande> : affiche et enregistre la commande et sa sortie (stdout+stderr)
run() { local f="$CAP/$1"; shift
        { printf '$ %s\n' "$*"; eval "$*" 2>&1; printf '\n'; } | tee -a "$f"; }
# rc <fichier> <attendu> <commande> : idem + code retour
rc()  { local f="$CAP/$1" att="$2"; shift 2
        { printf '$ %s\n' "$*"; eval "$*" 2>&1; printf -- '-> rc=%s (attendu %s)\n\n' "$?" "$att"; } | tee -a "$f"; }

m1() {
  titre "1.1 Politique AVANT creation des comptes"
  : > "$CAP/m1-politique.txt"
  [[ -f /root/login.defs.orig ]] || cp -a /etc/login.defs /root/login.defs.orig
  sed -i -e 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS   90/' -e 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS   1/' \
         -e 's/^PASS_WARN_AGE.*/PASS_WARN_AGE   14/' -e 's/^UMASK.*/UMASK           027/' /etc/login.defs
  run m1-politique.txt "grep -E '^(PASS_|UMASK|USERGROUPS_ENAB|CREATE_HOME)' /etc/login.defs"
  install -m 0644 "$CFG/50-helios.conf" /etc/security/pwquality.conf.d/50-helios.conf
  run m1-politique.txt "cat /etc/security/pwquality.conf.d/50-helios.conf"
  run m1-politique.txt "authselect current"
  authselect enable-feature with-faillock >/dev/null
  sed -i -e 's/^# *deny *=.*/deny = 5/' -e 's/^# *unlock_time *=.*/unlock_time = 600/' \
         -e 's/^# *fail_interval *=.*/fail_interval = 900/' -e 's/^# *audit$/audit/' /etc/security/faillock.conf
  run m1-politique.txt "authselect current | grep -i faillock"
  run m1-politique.txt "grep -Ev '^\s*(#|\$)' /etc/security/faillock.conf"

  titre "1.2 Squelette, groupes, comptes"
  : > "$CAP/m1-comptes.txt"
  grep -q 'socle Helios' /etc/skel/.bashrc || cat >> /etc/skel/.bashrc <<'EOF'
# socle Helios (pas de umask ici : ~/.bashrc est lu APRES /etc/profile.d et ecraserait
# le umask par groupe de la Mission 2 ; le 027 de base vient de login.defs via pam_umask)
export EDITOR=vim HISTSIZE=5000 HISTTIMEFORMAT='%F %T '
EOF
  getent group transport  >/dev/null || groupadd -g 5000 transport
  getent group telemetry  >/dev/null || groupadd -g 5001 telemetry
  getent group helios-ops >/dev/null || groupadd -g 5002 helios-ops
  id julien    &>/dev/null || useradd -u 5100 -g transport -G helios-ops -c "Julien Marty - chef equipe transport" -m julien
  id nadia     &>/dev/null || useradd -u 5101 -g transport -c "Nadia Belkacem - exploitante" -m nadia
  id tarek     &>/dev/null || useradd -u 5102 -g telemetry -G transport -c "Tarek Oualid - analyste telemetrie" -m tarek
  id audit-ext &>/dev/null || useradd -u 5103 -g telemetry -c "Auditeur externe - mandat Q4" -m \
                                -e "$(date -d '+21 days' +%F)" -s /bin/bash audit-ext
  for u in julien nadia tarek audit-ext ; do
    echo "${u}:${PW}" | chpasswd
    chage -M 90 -m 1 -W 14 -I 7 "$u"
  done
  run m1-comptes.txt "chage -l julien"
  run m1-comptes.txt "getent passwd julien nadia tarek audit-ext"
  run m1-comptes.txt "getent group transport telemetry helios-ops"

  titre "1.3 Administrateur de groupe, mot de passe faible, verrouillage"
  gpasswd -A julien transport >/dev/null
  run m1-comptes.txt "grep '^transport' /etc/group /etc/gshadow"
  run m1-comptes.txt "su - julien -c 'gpasswd -a nadia transport ; id nadia'"
  chage -d "$(date -d yesterday +%F)" julien

  : > "$CAP/m1-mdp-faible.txt"
  run m1-mdp-faible.txt "echo helios | pwscore"
  # passwd en tant que julien : PAM lit les reponses sur l'entree standard
  run m1-mdp-faible.txt "printf '%s\n' '$PW' helios helios helios helios helios helios | setsid -w su - julien -c passwd"
  run m1-mdp-faible.txt "chage -l julien | head -1"

  : > "$CAP/m1-faillock.txt"
  faillock --user nadia --reset
  run m1-faillock.txt "su - tarek -c 'for i in \$(seq 1 6); do echo mauvais | su - nadia -c id 2>/dev/null ; done'"
  run m1-faillock.txt "faillock --user nadia"
  rc  m1-faillock.txt "!=0 (compte verrouille)" "echo '$PW' | su - tarek -c 'su - nadia -c id'"
  run m1-faillock.txt "faillock --user nadia --reset ; faillock --user nadia"
  rc  m1-faillock.txt "0 (deverrouille)" "echo '$PW' | su - tarek -c 'su - nadia -c id'"
  run m1-faillock.txt "chage -l audit-ext | grep -i 'Account expires\|Le compte expire'"
}

m2() {
  titre "2.1 setgid et sticky"
  : > "$CAP/m2-setgid.txt" ; : > "$CAP/m2-sticky.txt"
  install -d -m 0755 /srv/helios/projets
  install -d -m 2770 -o julien -g transport $T
  install -d -m 0770 -o julien -g transport /srv/helios/projets/temoin
  run m2-setgid.txt "ls -ld $T /srv/helios/projets/temoin"
  run m2-setgid.txt "su - nadia -c 'touch $T/tournee-nadia.csv /srv/helios/projets/temoin/x ; ls -l $T/ /srv/helios/projets/temoin/'"
  run m2-setgid.txt "su - tarek -c 'touch $T/tournee-tarek.csv /srv/helios/projets/temoin/y ; ls -l $T/tournee-tarek.csv /srv/helios/projets/temoin/y'"

  install -d -m 1777 /srv/helios/depot
  run m2-sticky.txt "ls -ld /srv/helios/depot"
  run m2-sticky.txt "su - nadia -c 'echo n > /srv/helios/depot/fichier-nadia' ; ls -l /srv/helios/depot"
  rc  m2-sticky.txt "!=0" "su - tarek -c 'rm -f /srv/helios/depot/fichier-nadia'"
  chmod 0777 /srv/helios/depot
  rc  m2-sticky.txt "0 (sans sticky)" "su - tarek -c 'rm -f /srv/helios/depot/fichier-nadia'"
  chmod 1777 /srv/helios/depot
  run m2-sticky.txt "ls -ld /srv/helios/depot"

  titre "2.2 umask"
  : > "$CAP/m2-umask.txt"
  rm -rf /tmp/u1 /tmp/u2 /tmp/u3 /tmp/d1 /tmp/d2
  rm -f /etc/profile.d/helios-umask.sh          # mesure du umask de base (login.defs)
  run m2-umask.txt "su - nadia -c 'umask ; touch /tmp/u1 ; mkdir /tmp/d1 ; ls -ld /tmp/u1 /tmp/d1'"
  run m2-umask.txt "su - nadia -c 'umask 002 ; touch /tmp/u2 ; mkdir /tmp/d2 ; ls -ld /tmp/u2 /tmp/d2'"
  run m2-umask.txt "su - nadia -c 'umask 077 ; touch /tmp/u3 ; ls -l /tmp/u3'"
  install -m 0644 "$CFG/helios-umask.sh" /etc/profile.d/helios-umask.sh
  run m2-umask.txt "su - nadia -c 'umask ; touch $T/partage.txt ; ls -l $T/partage.txt'"
  run m2-umask.txt "su - audit-ext -c 'umask'"

  titre "2.3 setuid"
  : > "$CAP/m2-setuid.txt"
  run m2-setuid.txt "find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -printf '%M %u %g %p\n' 2>/dev/null | sort"
  printf '#!/usr/bin/bash\nid\n' > /usr/local/bin/faux-setuid.sh ; chmod 4755 /usr/local/bin/faux-setuid.sh
  run m2-setuid.txt "ls -l /usr/local/bin/faux-setuid.sh ; su - nadia -c '/usr/local/bin/faux-setuid.sh'"
  rm -f /usr/local/bin/faux-setuid.sh

  : > "$CAP/m2-lastlog.txt"
  rpm -q gcc &>/dev/null || dnf -y -q install gcc
  install -m 0640 -o root -g telemetry /dev/null /var/log/helios/app.log
  for i in $(seq 1 30); do echo "$(date --iso-8601=seconds) INFO trame ${i} ok" >> /var/log/helios/app.log ; done
  cp "$CFG/helios-lastlog.c" /root/helios-lastlog.c
  gcc -O2 -Wall -Wextra -o /usr/local/bin/helios-lastlog /root/helios-lastlog.c
  chown root:telemetry /usr/local/bin/helios-lastlog ; chmod 2755 /usr/local/bin/helios-lastlog
  run m2-lastlog.txt "ls -l /usr/local/bin/helios-lastlog /var/log/helios/app.log"
  rc  m2-lastlog.txt "!=0" "su - julien -c 'tail -n 3 /var/log/helios/app.log'"
  rc  m2-lastlog.txt "0"   "su - julien -c '/usr/local/bin/helios-lastlog'"
}

m3() {
  titre "3.1 ACL nominative"
  : > "$CAP/m3-acl.txt" ; : > "$CAP/m3-masque.txt" ; : > "$CAP/m3-sauvegarde.txt"
  run m3-acl.txt "mount | grep ' / ' ; xfs_info / | head -2"
  run m3-acl.txt "getfacl $T"
  setfacl -R -m u:audit-ext:rX $T
  run m3-acl.txt "getfacl $T ; ls -ld $T"
  run m3-acl.txt "su - audit-ext -c 'ls -l $T/ ; cat $T/tournee-nadia.csv'"
  rc  m3-acl.txt "!=0" "su - audit-ext -c 'touch $T/interdit'"

  titre "3.2 ACL par defaut"
  run m3-acl.txt "su - nadia -c 'touch $T/nouvelle.csv ; ls -l $T/nouvelle.csv' ; getfacl $T/nouvelle.csv"
  rc  m3-acl.txt "constat" "su - audit-ext -c 'cat $T/nouvelle.csv'"
  setfacl -d -m u:audit-ext:r   $T
  setfacl -d -m g:transport:rwx $T
  setfacl -d -m o::---          $T
  run m3-acl.txt "getfacl $T"
  run m3-acl.txt "su - nadia -c 'touch $T/tournee-j2.csv ; mkdir -p $T/semaine-41'"
  run m3-acl.txt "getfacl $T/tournee-j2.csv ; getfacl $T/semaine-41"
  rc  m3-acl.txt "0" "su - audit-ext -c 'cat $T/tournee-j2.csv'"

  titre "3.3 Masque effectif"
  setfacl -m u:tarek:rwx $T/tournee-j2.csv
  run m3-masque.txt "getfacl $T/tournee-j2.csv"
  chmod g-w $T/tournee-j2.csv
  run m3-masque.txt "chmod g-w $T/tournee-j2.csv ; getfacl $T/tournee-j2.csv"
  rc  m3-masque.txt "!=0" "su - tarek -c 'echo x >> $T/tournee-j2.csv'"
  setfacl -m m::rwx $T/tournee-j2.csv
  run m3-masque.txt "setfacl -m m::rwx $T/tournee-j2.csv ; getfacl $T/tournee-j2.csv | grep -E 'tarek|mask'"
  rc  m3-masque.txt "0" "su - tarek -c 'echo x >> $T/tournee-j2.csv'"

  titre "3.4 Sauvegarde / restauration"
  ( cd /srv/helios/projets
    ACLF=/root/acl-transport-$(date +%F).txt
    getfacl -R transport > "$ACLF"
    run m3-sauvegarde.txt "wc -l $ACLF"
    run m3-sauvegarde.txt "setfacl -R -b transport ; getfacl transport | head"
    run m3-sauvegarde.txt "setfacl --restore=$ACLF ; getfacl transport | head -12"
    rm -rf transport-copie transport-copie2
    run m3-sauvegarde.txt "cp -a transport transport-copie && getfacl transport-copie | head -8"
    run m3-sauvegarde.txt "cp -r transport transport-copie2 && getfacl transport-copie2 | head -8"
    run m3-sauvegarde.txt "tar --acls --xattrs -czf /root/transport.tgz transport ; tar --acls --xattrs -tvf /root/transport.tgz | head -3"
    rm -rf transport-copie transport-copie2
    cp "$ACLF" "$CFG/" )
}

m4() {
  titre "4.1 Regle restreinte helios-ops"
  : > "$CAP/m4-sudo.txt" ; : > "$CAP/m4-evasion.txt" ; : > "$CAP/m4-sudoreplay.txt"
  install -m 0440 "$CFG/90-helios-ops" /etc/sudoers.d/90-helios-ops
  install -d -m 0700 /var/log/sudo-io
  run m4-sudo.txt "visudo -cf /etc/sudoers.d/90-helios-ops"

  titre "4.2 Verifier, tracer, rejouer"
  run m4-sudo.txt "sudo -l -U julien"
  rc  m4-sudo.txt "0"   "echo '$PW' | su - julien -c 'sudo -S systemctl restart helios-collect.service'"
  rc  m4-sudo.txt "!=0" "echo '$PW' | su - julien -c 'sudo -S systemctl restart sshd'"
  run m4-sudo.txt "echo '$PW' | su - julien -c 'sudo -S -u helios cat /var/lib/helios/telemetry.csv' | tail -3"
  run m4-sudo.txt "echo '$PW' | su - julien -c 'sudo -S journalctl -u helios-collect.service -n 5 --no-pager'"
  rc  m4-sudo.txt "!=0 (hors groupe)" "echo '$PW' | su - nadia -c 'sudo -S -l'"
  run m4-sudoreplay.txt "sudoreplay -l"
  run m4-sudoreplay.txt "sudoreplay -l user julien"
  TSID="$(sudoreplay -l user julien | grep 'systemctl restart helios' | tail -1 | sed -n 's/.*TSID=\([^ ;]*\).*/\1/p')"
  run m4-sudoreplay.txt "LC_ALL=C timeout 20 sudoreplay -m 0.2 $TSID"
  run m4-sudoreplay.txt "tail -5 /var/log/sudo-helios.log ; journalctl -t sudo -n 10 --no-pager"

  titre "4.3 Regle laxiste : evasion de shell via sudo vim"
  echo 'nadia ALL=(root) NOPASSWD: /usr/bin/vim /srv/helios/projets/transport/*' > /etc/sudoers.d/99-mauvais-exemple
  chmod 0440 /etc/sudoers.d/99-mauvais-exemple
  run m4-evasion.txt "cat /etc/sudoers.d/99-mauvais-exemple ; visudo -c"
  rm -f /tmp/evasion-id.txt
  # equivalent non interactif de « :!/usr/bin/id » tape dans vim ; le * de la regle accepte n'importe quels arguments
  run m4-evasion.txt "su - nadia -c \"sudo -n /usr/bin/vim $T/tournee-nadia.csv -E -s -c '!/usr/bin/id > /tmp/evasion-id.txt' -c 'q!'\""
  run m4-evasion.txt "cat /tmp/evasion-id.txt"
  run m4-evasion.txt "su - nadia -c \"sudo -n /usr/bin/vim $T/tournee-nadia.csv -E -s -c '!(whoami; head -1 /etc/shadow) > /tmp/evasion-id.txt' -c 'q!'\" ; cat /tmp/evasion-id.txt"
  rm -f /tmp/evasion-id.txt /etc/sudoers.d/99-mauvais-exemple

  titre "4.3 Correction : sudoedit"
  install -m 0440 "$CFG/91-nadia-edition" /etc/sudoers.d/91-nadia-edition
  install -m 0755 "$CFG/tp2-editeur-demo.sh" /usr/local/bin/tp2-editeur-demo
  run m4-evasion.txt "cat /etc/sudoers.d/91-nadia-edition ; visudo -c"
  rc  m4-evasion.txt "!=0 (vim n'est plus autorise)" "su - nadia -c 'sudo -n /usr/bin/vim $T/tournee-nadia.csv'"
  rc  m4-evasion.txt "0" "echo '$PW' | su - nadia -c 'SUDO_EDITOR=/usr/local/bin/tp2-editeur-demo sudoedit -S $T/tournee-nadia.csv'"
  run m4-evasion.txt "tail -2 $T/tournee-nadia.csv ; ls -l $T/tournee-nadia.csv"
}

bonus() {
  titre "Bonus : audit (lecture seule)"
  : > "$CAP/bonus-audit.txt"
  run bonus-audit.txt "awk -F: '\$3>=1000 && \$3<65534 {print \$1, \$3, \$7}' /etc/passwd"
  run bonus-audit.txt "awk -F: '(\$2==\"\"){print \$1\" SANS MOT DE PASSE\"}' /etc/shadow"
  run bonus-audit.txt "find /srv /home -xdev -perm -0002 -not -type l -printf '%M %p\n' 2>/dev/null"
  run bonus-audit.txt "find /srv /home -xdev -type d -perm -2000 -printf '%M %g %p\n' 2>/dev/null"
  run bonus-audit.txt "getfacl -R -s /srv/helios 2>/dev/null | grep -B4 '^user:'"
  run bonus-audit.txt "for u in julien nadia tarek audit-ext ; do sudo -l -U \"\$u\" ; done"
  run bonus-audit.txt "chage -l audit-ext"
  run bonus-audit.txt "ls -l /etc/sudoers.d/ ; ls -ld /home/*"
}

collecte() {
  titre "Livrables"
  diff -u /root/login.defs.orig /etc/login.defs > "$CFG/login.defs.diff"
  cp /etc/security/faillock.conf "$CFG/faillock.conf"
  ls /root/acl-transport-*.txt &>/dev/null && cp /root/acl-transport-*.txt "$CFG/"
  : > "$CAP/criteres.txt"
  run criteres.txt "chage -l julien | grep -E 'Maximum|maximum|warning|avertissement'"
  run criteres.txt "grep -E 'shorter|court|moins de' $CAP/m1-mdp-faible.txt | head -2"
  run criteres.txt "grep -E 'nadia|rc=' $CAP/m1-faillock.txt | head -12"
  run criteres.txt "ls -l $T/tournee-tarek.csv /srv/helios/projets/temoin/y"
  run criteres.txt "grep -E 'rc=' $CAP/m2-sticky.txt"
  run criteres.txt "ls -l /usr/local/bin/helios-lastlog ; grep 'rc=' $CAP/m2-lastlog.txt"
  run criteres.txt "ls -ld $T ; getfacl -p $T | grep default"
  run criteres.txt "su - audit-ext -c 'cat $T/tournee-j2.csv' >/dev/null && echo 'audit-ext lit tournee-j2.csv'"
  run criteres.txt "visudo -c"
  run criteres.txt "sudo -l -U julien | grep -E 'restart|sshd'"
  run criteres.txt "sudoreplay -l user julien | wc -l"
  ls -l "$CFG"
  echo ">> git add -A && git commit -m 'TP2 : preuves collectees sur srv-core' && git push"
}

case "${1:-}" in
  m1) m1 ;; m2) m2 ;; m3) m3 ;; m4) m4 ;; bonus) bonus ;; collecte) collecte ;;
  montre) clear ; cat "$CAP/${2:?fichier}" ;;
  *) sed -n '2,12p' "$0" ; exit 1 ;;
esac
