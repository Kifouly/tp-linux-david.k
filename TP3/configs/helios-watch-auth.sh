#!/usr/bin/bash
# helios-watch-auth.sh - compte les echecs d'authentification SSH par adresse source sur une
# fenetre glissante et ajoute a l'ipset firewalld "helios-blacklist" toute source au-dela du seuil.
# Auteur : David.K - TP3 BTC2
# Codes retour : 0 nominal ; 2 une autre instance tourne deja ; 1 erreur (firewalld absent...)
set -euo pipefail
IFS=$'\n\t'

readonly TAG="helios-watch-auth"
readonly LOCK="/run/helios-watch-auth.lock"
readonly IPSET="helios-blacklist"
readonly SEUIL="${SEUIL:-5}"            # bloque au-dela de 5 echecs
readonly FENETRE="${FENETRE:-10min}"    # fenetre glissante
readonly ETAT="/var/lib/helios/blocked.txt"
readonly LISTE_BLANCHE=("192.168.56.1" "127.0.0.1")   # 192.168.56.1 : poste du formateur
# evenements d'echec ecrits par sshd (LogLevel VERBOSE)
readonly MOTIF='Invalid user|Failed (password|publickey|none|keyboard-interactive)|Connection closed by (invalid|authenticating) user|Disconnected from (invalid|authenticating) user|maximum authentication attempts|not allowed because'

log() { logger -t "$TAG" -p "authpriv.${2:-info}" -- "$1"; }

exec 9>"$LOCK"
if ! flock -n 9; then
  log "une autre instance tient le verrou $LOCK : abandon" notice
  exit 2
fi
trap 'log "erreur ligne $LINENO (rc=$?)" err' ERR

command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1 \
  || { log "firewalld indisponible : rien n'est bloque" err; exit 1; }
mkdir -p "$(dirname "$ETAT")" ; touch "$ETAT" ; chmod 0640 "$ETAT"

en_liste_blanche() { local w; for w in "${LISTE_BLANCHE[@]}"; do [[ "$1" == "$w" ]] && return 0; done; return 1; }

# "<nombre> <ip>" pour chaque source ayant des echecs dans la fenetre
mapfile -t COMPTES < <(
  journalctl -u sshd.service --since "-${FENETRE}" -o cat --no-pager 2>/dev/null \
    | grep -E "$MOTIF" \
    | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
    | sort | uniq -c | awk '{print $1" "$2}' || true )

nb_bloques=0
for ligne in "${COMPTES[@]}"; do
  [[ -n "$ligne" ]] || continue
  n="${ligne%% *}" ; ip="${ligne#* }"
  (( n > SEUIL )) || continue
  if en_liste_blanche "$ip"; then
    log "$ip : $n echecs en ${FENETRE} mais en liste blanche, ignoree" notice
    continue
  fi
  if firewall-cmd --ipset="$IPSET" --query-entry="$ip" >/dev/null 2>&1; then
    continue                                    # deja bloquee : pas de seconde alerte
  fi
  if grep -q "^${ip} " "$ETAT"; then            # connue mais absente apres un reload : on la remet
    firewall-cmd --ipset="$IPSET" --add-entry="$ip" >/dev/null
    log "$ip : deja connue, remise dans $IPSET (sans nouvelle alerte)"
    continue
  fi
  firewall-cmd --ipset="$IPSET" --add-entry="$ip" >/dev/null
  printf '%s %s %s\n' "$ip" "$(date --iso-8601=seconds)" "$n" >> "$ETAT"
  log "ALERTE : $ip bloquee ($n echecs SSH en ${FENETRE}, seuil ${SEUIL})" warning
  nb_bloques=$((nb_bloques + 1))
done

log "analyse terminee : ${#COMPTES[@]} source(s) en echec, ${nb_bloques} nouveau(x) blocage(s)"
exit 0
