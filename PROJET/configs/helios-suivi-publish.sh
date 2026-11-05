#!/usr/bin/bash
# helios-suivi-publish.sh
# Publie /srv/helios/suivi/www/etat.json a partir de la derniere ligne de telemetry.csv.
# Lance par helios-suivi-publish.service (compte helios-suivi) toutes les 2 minutes.
# Codes retour : 0 ok / 1 erreur interne (ligne invalide...) / 2 deja en cours / 3 prerequis manquant
set -euo pipefail

TAG=helios-suivi-publish
SRC=/var/lib/helios/telemetry.csv
WWW=/srv/helios/suivi/www
DEST=$WWW/etat.json
TMP=""

log() { logger -t "$TAG" -p "user.${2:-info}" -- "$1"; }

nettoyage() {
  local rc=$?
  if [[ -n "$TMP" && -e "$TMP" ]]; then rm -f -- "$TMP"; fi
  exit "$rc"
}
trap nettoyage EXIT

# Verrou : flock sur le script lui-meme ouvert en lecture.
# Pas besoin d'ecrire un fichier de verrou (l'unit est en ProtectSystem=strict).
exec 9<"$0"
if ! flock -n 9; then
  log "une autre publication est deja en cours, abandon" notice
  exit 2
fi

if [[ ! -r "$SRC" ]]; then
  log "telemetrie illisible : $SRC" err
  exit 3
fi
if [[ ! -d "$WWW" || ! -w "$WWW" ]]; then
  log "$WWW absent ou non inscriptible pour $(id -un)" err
  exit 3
fi

ligne=$(tail -n 1 "$SRC")
IFS=, read -r horodatage charge mem <<< "$ligne"

# on ne publie pas n'importe quoi : format attendu "2026-11-05T10:00:00+01:00,0.31,540460"
if ! [[ "$horodatage" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}$ ]] \
   || ! [[ "$charge" =~ ^[0-9]+(\.[0-9]+)?$ ]] || ! [[ "$mem" =~ ^[0-9]+$ ]]; then
  log "derniere ligne de telemetrie invalide : $ligne" err
  exit 1
fi

nb=$(wc -l < "$SRC")

# ecriture dans un fichier temporaire du meme repertoire puis rename :
# un lecteur voit l'ancien ou le nouveau etat.json, jamais un fichier a moitie ecrit
TMP=$(mktemp "$WWW/.etat.json.XXXXXX")
printf '{\n  "genere": "%s",\n  "hote": "%s",\n  "derniere_mesure": "%s",\n  "charge_1min": %s,\n  "mem_dispo_ko": %s,\n  "mesures": %s\n}\n' \
  "$(date --iso-8601=seconds)" "$(uname -n)" "$horodatage" "$charge" "$mem" "$nb" > "$TMP"
chmod 0640 "$TMP"
mv -f -- "$TMP" "$DEST"
TMP=""

log "etat.json publie : $nb mesures, derniere a $horodatage"
exit 0
