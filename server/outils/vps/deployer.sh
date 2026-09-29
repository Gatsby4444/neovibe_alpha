#!/usr/bin/env bash
# Depuis le PC : prépare le VPS et y met le serveur NeoVibe à jour.
#
#   bash server/outils/vps/deployer.sh --installer   installe le socle (une fois ; rejouable)
#   bash server/outils/vps/deployer.sh --base        monte la base (refuse d'écraser)
#   bash server/outils/vps/deployer.sh --base --remplacer   l'efface et la refait (ordre de Jay)
#   bash server/outils/vps/deployer.sh               construit et relance le serveur
#   bash server/outils/vps/deployer.sh --fichiers    recopie les fichiers de la dev (Supabase) vers R2 (rejouable)
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
--base)
  COPIE="$RACINE/docdev/copie_base_dev"
  [ -d "$COPIE" ] || { echo "Pas de copie des données : python server/outils/copier_base_dev.py"; exit 1; }
  P=/var/tmp/nv-base
  "${SSH[@]}" "rm -rf $P && mkdir -p $P/repetition_vps $P/supabase_migrations $P/server_migrations $P/outils $P/copie"
  tar -czf - -C "$RACINE/server/outils/vps" monter_base.sh | "${SSH[@]}" "tar -xzf - --no-same-owner -C $P"
  tar -czf - -C "$RACINE/server/outils" recette_base.sh importer_copie.sql | "${SSH[@]}" "tar -xzf - --no-same-owner -C $P/outils"
  tar -czf - -C "$RACINE/tool/repetition_vps" bootstrap.sql replay.sh | "${SSH[@]}" "tar -xzf - --no-same-owner -C $P/repetition_vps"
  tar -czf - -C "$RACINE/supabase/migrations" . | "${SSH[@]}" "tar -xzf - --no-same-owner -C $P/supabase_migrations"
  tar -czf - -C "$RACINE/server/migrations" . | "${SSH[@]}" "tar -xzf - --no-same-owner -C $P/server_migrations"
  tar -czf - -C "$COPIE" . | "${SSH[@]}" "tar -xzf - --no-same-owner -C $P/copie"
  "${SSH[@]}" "bash $P/monter_base.sh $P ${2:-}; rm -rf $P"
  ;;
--fichiers)
  # Les fichiers de la dev (Supabase) vers R2, depuis le VPS. La clé de
  # service de Supabase est lue par l'API de gestion (PAT de
  # docdev/PATsupabase.txt) et passe par un tuyau jusqu'au script : elle
  # n'est écrite sur aucun disque ni affichée.
  tar -czf - -C "$RACINE/server/outils/vps" copier_fichiers.py | "${SSH[@]}" 'tar -xzf - --no-same-owner -C /root'
  python - "$RACINE/docdev/PATsupabase.txt" <<'PY' | "${SSH[@]}" 'python3 -u /root/copier_fichiers.py; S=$?; rm -f /root/copier_fichiers.py; exit $S'
import json, sys, urllib.request
PROJET = 'dvixmhvqqjvbrpsckmyi'
tok = open(sys.argv[1]).read().strip()
req = urllib.request.Request(f'https://api.supabase.com/v1/projects/{PROJET}/api-keys?reveal=true',
                             headers={'Authorization': 'Bearer ' + tok, 'User-Agent': 'neovibe-copie'})
cles = json.loads(urllib.request.urlopen(req, timeout=60).read())
service = next(c['api_key'] for c in cles if c.get('name') == 'service_role')
print(f'https://{PROJET}.supabase.co')
print(service)
PY
  ;;
"")
  echo "Envoi des sources du serveur…"
  "${SSH[@]}" 'rm -rf /opt/neovibe/src && mkdir -p /opt/neovibe/src'
  tar -czf - -C "$RACINE/server" --exclude=./target Cargo.toml Cargo.lock crates migrations \
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
/root/.cargo/bin/cargo build --release -q -p nv-server
/root/.cargo/bin/cargo test --release -q -p nv-server
/root/.cargo/bin/cargo test --release -q -p nv-app --lib ancien_gardien
install -m 755 /opt/neovibe/target/release/nv-server /opt/neovibe/bin/nv-server
# L'ancien gardien éteint (le serveur refuse de démarrer sinon) — d'après
# la liste que porte le serveur lui-même. Rejouable.
/opt/neovibe/bin/nv-server eteindre-l-ancien-gardien | sudo -u postgres psql -q -v ON_ERROR_STOP=1 -d neovibe
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
  echo "Usage : deployer.sh [--installer | --base [--remplacer] | --fichiers]"; exit 1 ;;
esac
