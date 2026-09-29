#!/usr/bin/env bash
# Depuis le PC : prépare le VPS et y met le serveur NeoVibe à jour.
#
#   bash server/outils/vps/deployer.sh --installer   installe le socle (une fois ; rejouable)
#   bash server/outils/vps/deployer.sh               applique les migrations, construit, relance
#
# ✏️ 2026-09-29, après la bascule : la base du VPS est LA base de NeoVibe.
# Les gestes qui la reconstruisaient depuis la copie de la dev (`--base`,
# `--fichiers`) sont retirés — rejoués, ils auraient écrasé les vraies
# données, et la dev (Supabase) est en pause. En cas de malheur, on
# RESTAURE une sauvegarde (restaurer.sh). La structure évolue par les
# migrations de server/migrations/, appliquées une fois chacune (table
# `nv.migrations`).
#
# Accès : la clé ~/.ssh/neovibe_vps (jamais de mot de passe). Le serveur se
# construit SUR le VPS, contre sa propre base : sqlx y vérifie chaque
# requête (une colonne disparue casse la construction, pas l'app).
set -euo pipefail
RACINE="$(cd "$(dirname "$0")/../../.." && pwd)"
VPS="root@2.24.162.2"
# Le nom public du serveur : le même que dans le Caddyfile et que
# `--vps` de server/outils/app_d_essai.sh.
HOTE="api.neovibe.fun"
SSH=(ssh -i "$HOME/.ssh/neovibe_vps" -o BatchMode=yes "$VPS")

case "${1:-}" in
--installer)
  "${SSH[@]}" 'rm -rf /root/nv-installer && mkdir -p /root/nv-installer'
  tar -czf - -C "$RACINE/server/outils/vps" . | "${SSH[@]}" 'tar -xzf - --no-same-owner -C /root/nv-installer'
  "${SSH[@]}" 'bash /root/nv-installer/installer.sh'
  ;;
"")
  echo "Envoi des sources du serveur…"
  "${SSH[@]}" 'rm -rf /opt/neovibe/src && mkdir -p /opt/neovibe/src'
  tar -czf - -C "$RACINE/server" --exclude=./target Cargo.toml Cargo.lock crates migrations migrations_en_service \
    outils/ordre_des_migrations.sh \
    | "${SSH[@]}" 'tar -xzf - --no-same-owner -C /opt/neovibe/src'
  echo "Construction sur le VPS (quelques minutes)…"
  # ⚠️ Un arrêt en cours de route doit se VOIR : le 2026-09-29, une
  # recherche sans résultat (grep, code 1) arrêtait ce script en silence
  # avant `systemctl restart` — les déploiements installaient le programme
  # sans jamais le relancer, et rien ne le disait.
  if ! "${SSH[@]}" 'bash -s' <<'EOF'
set -euo pipefail
trap 'echo "🔴 ARRÊT sur le VPS, ligne $LINENO : $BASH_COMMAND"' ERR
set -a; . /etc/neovibe/nv-server.env; set +a
export DATABASE_URL="$NV_DATABASE_URL" CARGO_TARGET_DIR=/opt/neovibe/target
cd /opt/neovibe/src
PSQL=(sudo -u postgres psql -q -v ON_ERROR_STOP=1 -d neovibe)
# Les migrations, chacune UNE fois, dans l'ordre des noms (horodatés), chacune
# dans sa transaction avec sa trace — celles de tout serveur
# (server/migrations/) et celles des seules bases en service
# (server/migrations_en_service/ : le retrait de l'ancien gardien…). AVANT
# la construction : sqlx vérifie les requêtes contre la structure qui sera en
# service. ⚠️ Une migration doit donc laisser l'ancien programme tourner (il
# tourne encore si la construction échoue ensuite) : AJOUTER, pas casser.
# Le registre n'est écrit que par `postgres` (le serveur ne peut ni
# l'effacer ni le truquer), et il garde l'empreinte de chaque fichier : un
# fichier MODIFIÉ après avoir été appliqué arrête le déploiement (il ne
# serait jamais rejoué, et rien ne le dirait).
"${PSQL[@]}" <<'SQL'
create table if not exists nv.migrations (nom text primary key, appliquee_le timestamptz not null default now(), empreinte text);
alter table nv.migrations add column if not exists empreinte text;
revoke all on nv.migrations from nv_server;
SQL
# L'ordre : celui de outils/ordre_des_migrations.sh — le même que pour la
# base du serveur du PC (recette_base.sh).
for f in $(sh outils/ordre_des_migrations.sh migrations migrations_en_service); do
  nom="$(basename "$f")"
  emp="$(sha256sum "$f" | cut -d' ' -f1)"
  deja="$("${PSQL[@]}" -At -v nom="$nom" <<'SQL'
select coalesce(empreinte, '-') from nv.migrations where nom = :'nom';
SQL
)"
  if [ -z "$deja" ]; then
    { cat "$f"; echo; echo "insert into nv.migrations (nom, empreinte) values (:'nom', :'emp');"; } \
      | "${PSQL[@]}" -1 -v nom="$nom" -v emp="$emp"
    echo "migration appliquée : $nom"
  elif [ "$deja" = "-" ]; then
    # Inscrite avant qu'on garde les empreintes : on retient celle d'aujourd'hui.
    "${PSQL[@]}" -v nom="$nom" -v emp="$emp" <<'SQL'
update nv.migrations set empreinte = :'emp' where nom = :'nom';
SQL
  elif [ "$deja" != "$emp" ]; then
    echo "🔴 La migration $nom a été MODIFIÉE après avoir été appliquée : on ne réécrit pas une migration passée, on en ajoute une nouvelle."
    exit 1
  fi
done
/root/.cargo/bin/cargo build --release -q -p nv-server
/root/.cargo/bin/cargo test --release -q -p nv-server
install -m 755 /opt/neovibe/target/release/nv-server /opt/neovibe/bin/nv-server
# La clé des badges : tirée une fois, jamais remplacée (la changer
# déconnecte tout le monde — c'est le geste de la purge, RAPPELS #176 ⑥).
if grep -q '^NV_BADGE_CLE=$' /etc/neovibe/nv-server.env; then
  CLE="$(/opt/neovibe/bin/nv-server nouvelle-cle)"
  sed -i "s#^NV_BADGE_CLE=\$#NV_BADGE_CLE=$CLE#" /etc/neovibe/nv-server.env
  echo "Clé des badges tirée."
fi
# Un réglage vide vaut « absent », et le serveur retomberait alors sur les
# valeurs du PC (l'entrepôt local 127.0.0.1:8333) : sur le VPS, chacun est
# exigé.
# (Aucun vide trouvé = grep rend 1 : ce n'est pas un échec.)
MANQUE="$( { grep -oE '^NV_S3_(INTERNE|PUBLIQUE|REGION|CLE|SECRET)=$' /etc/neovibe/nv-server.env || true; } | tr -d '=' | tr '\n' ' ')"
if [ -n "$MANQUE" ]; then
  echo "⚠️  Réglages de l'entrepôt de fichiers vides dans /etc/neovibe/nv-server.env : $MANQUE— le serveur n'est pas relancé."
  exit 0
fi
AVANT="$(systemctl show nv-server -p ActiveEnterTimestampMonotonic --value)"
systemctl restart nv-server
sleep 3
APRES="$(systemctl show nv-server -p ActiveEnterTimestampMonotonic --value)"
# Relancé ET en marche, vérifié — pas seulement demandé.
[ "$(systemctl is-active nv-server)" = active ] && [ "$APRES" != "$AVANT" ]
echo "Serveur relancé à $(systemctl show nv-server -p ActiveEnterTimestamp --value), programme du $(date -r /opt/neovibe/bin/nv-server '+%Y-%m-%d %H:%M:%S %Z')."
EOF
  then
    echo "🔴 Le déploiement a échoué sur le VPS (voir la ligne « ARRÊT » ci-dessus) : le serveur n'a PAS été relancé avec la nouvelle version."
    exit 1
  fi
  echo "Santé : $(curl -s -m 10 "https://$HOTE/v1/sante" || echo 'pas de réponse')"
  ;;
*)
  echo "Usage : deployer.sh [--installer]"; exit 1 ;;
esac
