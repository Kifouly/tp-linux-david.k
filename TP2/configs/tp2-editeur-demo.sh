#!/bin/sh
# Editeur non interactif pour la demonstration sudoedit (Mission 4.3).
# sudoedit l'execute EN TANT QUE L'APPELANT sur une copie temporaire du fichier.
echo "# edite via sudoedit par $(id -un) le $(date '+%F %T')" >> "$1"
