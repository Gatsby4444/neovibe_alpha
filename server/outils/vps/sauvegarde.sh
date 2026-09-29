#!/usr/bin/env bash
# Sauvegarde quotidienne de la base NeoVibe (nv-sauvegarde.timer), tournée
# par l'utilisateur postgres. Garde 14 jours. Deux fichiers par passage :
# - `neovibe-<date>.dump` : la base (structure, données, et ses réglages) ;
# - `roles-<date>.sql` : les RÔLES du serveur de base. Ils n'appartiennent
#   à aucune base, pg_dump ne les emporte donc pas ; sans eux, la base ne se
#   restaure pas sur une machine neuve (ses droits les nomment).
#
# Ces fichiers contiennent les empreintes de mots de passe : lisibles par
# postgres seulement.
#
# ⚠️ Ils sont sur le MÊME disque que la base : ils protègent d'une erreur
# (une suppression, une migration ratée), pas de la perte du VPS. La copie
# hors de la machine est à brancher (docs/serveur-rust.md, étape 12).
set -euo pipefail
umask 077
DOSSIER=/var/backups/neovibe
DATE="$(date -u +%Y-%m-%d_%H%M)"
pg_dumpall --roles-only -f "$DOSSIER/roles-$DATE.sql.partiel"
pg_dump -Fc -d neovibe -f "$DOSSIER/neovibe-$DATE.dump.partiel"
mv "$DOSSIER/roles-$DATE.sql.partiel" "$DOSSIER/roles-$DATE.sql"
mv "$DOSSIER/neovibe-$DATE.dump.partiel" "$DOSSIER/neovibe-$DATE.dump"
find "$DOSSIER" \( -name 'neovibe-*.dump' -o -name 'roles-*.sql' \) -mtime +14 -delete
echo "sauvegarde : neovibe-$DATE.dump ($(du -h "$DOSSIER/neovibe-$DATE.dump" | cut -f1)) + roles-$DATE.sql"
