#!/usr/bin/bash
# helios-suivi-backup.sh
# Archive tout ce qu'il faut pour reconstruire le portail de suivi (avec les ACL)
# dans /srv/helios/archives/suivi/suivi-AAAAMMJJ-HHMMSS.tar.gz + .sha256, garde les 7 dernieres.
# Codes retour : 0 ok / 1 erreur (tar, empreinte) / 2 deja en cours / 3 prerequis manquant
set -euo pipefail

TAG=helios-suivi-backup
DEST=/srv/helios/archives/suivi
GARDE=7
SOURCES=(
  /srv/helios/suivi
  /etc/systemd/system/helios-suivi.service
  /etc/systemd/system/helios-suivi-publish.service
  /etc/systemd/system/helios-suivi-publish.timer
  /etc/systemd/system/helios-suivi-backup.service
  /etc/systemd/system/helios-suivi-backup.timer
  /etc/sudoers.d/92-helios-suivi
  /etc/zabbix/zabbix_agent2.d/helios-suivi.conf
  /usr/local/sbin/helios-suivi-publish.sh
  /usr/local/sbin/helios-suivi-backup.sh
)
# le script d'audit (bonus) est sauvegarde s'il est present
[[ -e /usr/local/sbin/helios-suivi-audit.sh ]] && SOURCES+=(/usr/local/sbin/helios-suivi-audit.sh)
TMP=""

log() { logger -t "$TAG" -p "user.${2:-info}" -- "$1"; }

nettoyage() {
  local rc=$?
  if [[ -n "$TMP" && -e "$TMP" ]]; then rm -f -- "$TMP"; fi
  exit "$rc"
}
trap nettoyage EXIT

exec 9<"$0"
if ! flock -n 9; then
  log "une autre sauvegarde est deja en cours, abandon" notice
  exit 2
fi

if [[ $EUID -ne 0 ]]; then
  log "doit etre lance en root" err
  exit 3
fi
if [[ ! -d "$DEST" || ! -w "$DEST" ]]; then
  log "destination $DEST absente ou non inscriptible" err
  exit 3
fi
for s in "${SOURCES[@]}"; do
  if [[ ! -e "$s" ]]; then
    log "source manquante : $s" err
    exit 3
  fi
done

nom="suivi-$(date +%Y%m%d-%H%M%S).tar.gz"
TMP="$DEST/.$nom.part"

# chemins relatifs a / pour pouvoir restaurer avec tar -C /
rel=()
for s in "${SOURCES[@]}"; do rel+=("${s#/}"); done

if ! tar --acls --xattrs --selinux -czpf "$TMP" -C / "${rel[@]}"; then
  log "echec de tar" err
  exit 1
fi
mv -f -- "$TMP" "$DEST/$nom"
TMP=""

( cd "$DEST" && sha256sum "$nom" > "$nom.sha256" && sha256sum -c --quiet "$nom.sha256" ) || {
  log "empreinte invalide pour $nom" err
  exit 1
}

# rotation : on garde les $GARDE archives les plus recentes
supprimees=0
while read -r vieux; do
  [[ -n "$vieux" ]] || continue
  rm -f -- "$vieux" "$vieux.sha256"
  supprimees=$((supprimees + 1))
done < <(ls -1t "$DEST"/suivi-*.tar.gz 2>/dev/null | tail -n +$((GARDE + 1)))

log "archive $nom creee ($(du -h "$DEST/$nom" | cut -f1)), $supprimees ancienne(s) supprimee(s)"
exit 0
