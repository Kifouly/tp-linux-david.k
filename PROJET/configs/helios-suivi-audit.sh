#!/usr/bin/bash
# helios-suivi-audit.sh - controle de conformite du portail de suivi (E1 a E9)
# Lecture seule : ne modifie rien. Une ligne [OK]/[KO] par exigence puis "Bilan : n/9".
# Code retour 0 seulement si les 9 exigences sont conformes.
# Un controle qui ne peut pas s'executer compte comme KO (pas de faux OK).
set -uo pipefail
cherche() { [ -n "$(grep "$@")" ]; }
export LC_ALL=C

WWW=/srv/helios/suivi/www
ARCH=/srv/helios/archives/suivi
total=0
ok=0
raisons=()

ko() { raisons+=("$1"); }

# resultat <exigence> <libelle> : affiche OK si aucune raison n'a ete ajoutee depuis le debut du test
resultat() {
  total=$((total + 1))
  if [[ ${#raisons[@]} -eq 0 ]]; then
    ok=$((ok + 1))
    printf '[OK] %s %s\n' "$1" "$2"
  else
    local IFS=';'
    printf '[KO] %s %s : %s\n' "$1" "$2" "${raisons[*]}"
  fi
  raisons=()
}

if [[ $EUID -ne 0 ]]; then
  echo "[KO] audit a lancer en root" ; echo "Bilan : 0/9" ; exit 1
fi

# ---------------------------------------------------------------- E1
g=$(getent group suivi) || ko "groupe suivi absent"
[[ "${g:-}" == suivi:*:5003:* ]] || ko "gid de suivi different de 5003"
p=$(getent passwd lea) || ko "compte lea absent"
IFS=: read -r _ _ uid gid gecos _ _ <<< "${p:-}"
[[ "${uid:-}" == 5104 ]] || ko "uid de lea different de 5104"
[[ "${gid:-}" == 5003 ]] || ko "suivi n'est pas le groupe primaire de lea"
[[ "${gecos:-}" == "Lea Fabre - responsable suivi des tournees" ]] || ko "commentaire de lea"
if ch=$(chage -l lea 2>/dev/null); then
  grep -qE 'Maximum.*: 90$' <<< "$ch" || ko "max 90 j"
  grep -qE 'Minimum.*: 1$' <<< "$ch" || ko "min 1 j"
  grep -qE 'warning.*: 14$' <<< "$ch" || ko "alerte 14 j"
  [[ $(getent shadow lea | cut -d: -f7) == 7 ]] || ko "inactivite 7 j"
else
  ko "chage -l lea impossible"
fi
groupes=$(id -nG lea 2>/dev/null) || ko "id lea impossible"
grep -qwE 'wheel|ssh-admins' <<< "${groupes:-}" && ko "lea dans wheel ou ssh-admins"
s=$(getent passwd helios-suivi) || ko "compte helios-suivi absent"
IFS=: read -r _ _ suid _ _ shome sshell <<< "${s:-}"
[[ -n "${suid:-}" && "${suid}" -lt 1000 ]] || ko "helios-suivi n'est pas un compte systeme"
[[ "${shome:-}" == /srv/helios/suivi ]] || ko "home de helios-suivi"
[[ "${sshell:-}" == */nologin || "${sshell:-}" == */false ]] || ko "helios-suivi a un shell"
[[ -e /home/helios-suivi ]] && ko "/home/helios-suivi existe"
resultat E1 "comptes lea / helios-suivi et groupe suivi"

# ---------------------------------------------------------------- E2
[[ $(stat -c '%U:%G %a' "$WWW" 2>/dev/null) == "root:suivi 2770" ]] || ko "www n'est pas root:suivi 2770"
acl=$(getfacl -p "$WWW" 2>/dev/null) || ko "getfacl www impossible"
grep -qx 'user:helios-suivi:rwx' <<< "${acl:-}" || ko "ACL helios-suivi rwx"
grep -qx 'user:zabbix:--x' <<< "${acl:-}" || ko "ACL zabbix --x"
grep -qx 'other::---' <<< "${acl:-}" || ko "other a des droits"
grep -qx 'default:group::rwx' <<< "${acl:-}" || ko "ACL par defaut du groupe"
grep -qE '^default:user:helios-suivi:r' <<< "${acl:-}" || ko "ACL par defaut helios-suivi"
grep -qx 'default:other::---' <<< "${acl:-}" || ko "ACL par defaut other"
runuser -u zabbix -- stat "$WWW/etat.json" >/dev/null 2>&1 || ko "zabbix ne peut pas faire stat"
runuser -u zabbix -- ls "$WWW" >/dev/null 2>&1 && ko "zabbix peut lister www"
[[ $(stat -c '%U:%G' "$WWW/index.html" 2>/dev/null) == "lea:suivi" ]] || ko "index.html absent ou pas a lea:suivi"
runuser -u helios-suivi -- cat "$WWW/index.html" >/dev/null 2>&1 || ko "helios-suivi ne lit pas index.html"
runuser -u nadia -- cat "$WWW/index.html" >/dev/null 2>&1 && ko "nadia lit index.html"
resultat E2 "repertoire publie (setgid, ACL)"

# ---------------------------------------------------------------- E3
[[ -x /usr/local/sbin/helios-suivi-publish.sh ]] || ko "script de publication absent"
if json=$(python3 -m json.tool "$WWW/etat.json" 2>/dev/null); then
  for champ in genere hote derniere_mesure charge_1min mem_dispo_ko mesures; do
    grep -q "\"$champ\"" <<< "$json" || ko "champ $champ absent"
  done
else
  ko "etat.json absent ou JSON invalide"
fi
age=$(( $(date +%s) - $(stat -c %Y "$WWW/etat.json" 2>/dev/null || echo 0) ))
[[ $age -lt 300 ]] || ko "etat.json vieux de ${age}s"
journalctl -t helios-suivi-publish --since '-10min' -q --no-pager 2>/dev/null | cherche 'publie' \
  || ko "aucune publication journalisee depuis 10 min"
resultat E3 "publication de etat.json"

# ---------------------------------------------------------------- E4
systemctl is-active -q helios-suivi.service || ko "portail arrete"
systemctl is-enabled -q helios-suivi.service || ko "portail non active au boot"
systemctl list-dependencies helios.target --plain 2>/dev/null | cherche 'helios-suivi.service' \
  || ko "portail non rattache a helios.target"
[[ $(systemctl show -p User --value helios-suivi.service) == helios-suivi ]] || ko "User different de helios-suivi"
[[ $(systemctl show -p MemoryMax --value helios-suivi.service) == 134217728 ]] || ko "MemoryMax"
[[ $(systemctl show -p CPUQuotaPerSecUSec --value helios-suivi.service) == 500ms ]] || ko "CPUQuota"
[[ $(systemctl show -p Restart --value helios-suivi.service) =~ ^(always|on-failure|on-abnormal)$ ]] || ko "pas de redemarrage auto"
score=$(systemd-analyze security helios-suivi.service 2>/dev/null | awk '/Overall exposure level/ {for (i=NF;i;i--) if ($i+0 == $i) print $i}')
if [[ -n "$score" ]]; then
  awk -v s="$score" 'BEGIN { exit !(s <= 4.0) }' || ko "exposition $score > 4.0"
else
  ko "systemd-analyze security impossible"
fi
for u in / /etat.json; do
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:8080$u")
  [[ "$c" == 200 ]] || ko "HTTP $c sur $u"
done
systemctl is-active -q helios-suivi-publish.timer || ko "timer de publication inactif"
[[ $(systemctl show -p User --value helios-suivi-publish.service) == helios-suivi ]] || ko "publication pas en helios-suivi"
resultat E4 "units systemd (portail durci, publication)"

# ---------------------------------------------------------------- E5
F=/etc/sudoers.d/92-helios-suivi
if [[ -f $F ]]; then
  [[ $(stat -c '%U:%G %a' "$F") == "root:root 440" ]] || ko "92-helios-suivi pas en 0440 root:root"
  visudo -cf "$F" >/dev/null 2>&1 || ko "syntaxe sudoers invalide"
  grep -q 'NOPASSWD' "$F" && ko "NOPASSWD present"
  grep -v '^[[:space:]]*#' "$F" | cherche '\*' && ko "joker * dans les regles"
  sudo -l -U lea /usr/bin/systemctl restart helios-suivi.service >/dev/null 2>&1 || ko "lea ne peut pas redemarrer le portail"
  sudo -l -U lea /usr/bin/systemctl start helios-suivi-publish.service >/dev/null 2>&1 || ko "lea ne peut pas publier"
  sudo -l -U lea /usr/bin/journalctl -u helios-suivi.service -n 100 >/dev/null 2>&1 || ko "lea ne lit pas le journal"
  sudo -l -U lea /usr/bin/systemctl restart sshd >/dev/null 2>&1 && ko "lea peut redemarrer sshd"
  sudo -l -U lea /usr/bin/journalctl --vacuum-time=1s >/dev/null 2>&1 && ko "lea peut vider les journaux"
  sudo -l -U lea /usr/bin/bash >/dev/null 2>&1 && ko "lea peut lancer un shell root"
else
  ko "$F absent"
fi
resultat E5 "delegation sudo"

# ---------------------------------------------------------------- E6
if firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd -q --zone=internal --query-port=8080/tcp || ko "8080 absent de internal (runtime)"
  firewall-cmd -q --permanent --zone=internal --query-port=8080/tcp || ko "8080 absent de internal (permanent)"
  for z in $(firewall-cmd --get-zones); do
    [[ $z == internal ]] && continue
    firewall-cmd --zone="$z" --list-all 2>/dev/null | cherche 8080 && ko "8080 dans la zone $z"
  done
  [[ $(firewall-cmd --get-default-zone) == drop ]] || ko "zone par defaut differente de drop"
else
  ko "firewalld arrete"
fi
resultat E6 "pare-feu (8080 seulement en internal)"

# ---------------------------------------------------------------- E7
t=$(sshd -T 2>/dev/null) || ko "sshd -T impossible"
grep -qx 'port 2242' <<< "${t:-}" || ko "port ssh"
grep -qx 'permitrootlogin no' <<< "${t:-}" || ko "permitrootlogin"
grep -qx 'passwordauthentication no' <<< "${t:-}" || ko "passwordauthentication"
grep -qx 'allowgroups ssh-admins' <<< "${t:-}" || ko "allowgroups"
systemctl is-active -q sshd || ko "sshd arrete"
systemctl is-active -q helios-watch-auth.timer || ko "helios-watch-auth.timer inactif"
[[ -d /var/log/journal/$(cat /etc/machine-id) ]] || ko "journald non persistant"
[[ $(getenforce 2>/dev/null) == Enforcing ]] || ko "SELinux pas en enforcing"
systemctl is-active -q helios-collect.service || ko "collecteur TP1 arrete"
resultat E7 "non-regression securite (TP1 a TP3)"

# ---------------------------------------------------------------- E8
systemctl is-active -q zabbix-agent2 || ko "zabbix-agent2 arrete"
systemctl is-enabled -q zabbix-agent2 2>/dev/null || ko "zabbix-agent2 non active au boot"
systemctl is-active -q sysstat-collect.timer || ko "sysstat-collect.timer inactif"
if command -v zabbix_get >/dev/null; then
  h=$(zabbix_get -s 127.0.0.1 -k helios.suivi.http 2>&1)
  [[ "$h" == 200 ]] || ko "helios.suivi.http=$h"
  a=$(zabbix_get -s 127.0.0.1 -k helios.suivi.age 2>&1)
  [[ "$a" =~ ^[0-9]+$ && $a -lt 300 ]] || ko "helios.suivi.age=$a"
else
  ko "zabbix_get absent"
fi
resultat E8 "supervision Zabbix"

# ---------------------------------------------------------------- E9
[[ $(stat -c '%U:%G %a' /srv/helios/archives 2>/dev/null) == "helios:helios 750" ]] || ko "/srv/helios/archives pas helios:helios 0750"
derniere=$(ls -1t "$ARCH"/suivi-*.tar.gz 2>/dev/null | head -1)
if [[ -n "$derniere" ]]; then
  ( cd "$ARCH" && sha256sum -c --quiet "$(basename "$derniere").sha256" >/dev/null 2>&1 ) || ko "empreinte invalide pour $(basename "$derniere")"
  tar -tzf "$derniere" 2>/dev/null | cherche 'srv/helios/suivi/www/index.html' || ko "index.html absent de l'archive"
  n=$(ls -1 "$ARCH"/suivi-*.tar.gz | wc -l)
  [[ $n -le 7 ]] || ko "$n archives (7 max)"
  [[ $(( $(date +%s) - $(stat -c %Y "$derniere") )) -lt 93600 ]] || ko "derniere archive de plus de 26 h"
else
  ko "aucune archive"
fi
systemctl is-active -q helios-suivi-backup.timer || ko "timer de sauvegarde inactif"
[[ $(systemctl show -p Persistent --value helios-suivi-backup.timer) == yes ]] || ko "timer non persistant"
resultat E9 "sauvegarde"

echo "Bilan : $ok/$total"
[[ $ok -eq $total ]]
