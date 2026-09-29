#!/usr/bin/env bash
# Lance le serveur Rust POUR LE TÉLÉPHONE — l'app d'essai « NeoVibe (Rust) »
# (docs/serveur-rust.md, étape 11, « L'app d'essai »).
#
#   bash server/outils/serveur_telephone.sh
#
# Ce qui change par rapport au serveur de développement :
# - il écoute sur le RÉSEAU LOCAL (0.0.0.0), pas seulement sur le PC ;
# - les liens de fichiers qu'il signe portent l'adresse du PC que le
#   téléphone peut joindre (sinon ils diraient 127.0.0.1 : le téléphone
#   lui-même) ;
# - il travaille sur SA base (`nv_serveur`), jamais sur la référence de la
#   preuve (outils/base_locale.py).
#
# ⚠️ Le pare-feu de Windows doit laisser entrer, depuis le réseau local, les
# ports 8787 (le serveur) et 8333 (l'entrepôt de fichiers) — une seule fois,
# commande dans docs/serveur-rust.md.
set -euo pipefail
RACINE="$(cd "$(dirname "$0")/../.." && pwd)"

# L'adresse du PC sur le réseau local : celle de la carte qui mène à
# Internet (aucun paquet n'est envoyé).
IP="$(python -c "import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(('8.8.8.8', 80)); print(s.getsockname()[0])")"

GRAVEE="$RACINE/build/essai_rust/adresse.txt"
if [ -f "$GRAVEE" ] && [ "$(cat "$GRAVEE")" != "$IP" ]; then
  echo "⚠️  L'app d'essai a été construite pour $(cat "$GRAVEE"), mais le PC est maintenant à $IP."
  echo "    Elle ne trouvera pas ce serveur : reconstruis-la (bash server/outils/app_d_essai.sh)."
fi

# La base et l'entrepôt de fichiers doivent tourner.
docker start nv_rust_db nv_s3 > /dev/null
# Un conteneur qui vient de démarrer n'accepte pas encore de connexion :
# sans cette attente, la vérification ci-dessous concluait à tort que la
# base n'existait pas (constaté le 2026-09-28, juste après Docker Desktop).
PRETE=non
for _ in $(seq 1 30); do
  docker exec nv_rust_db pg_isready -U postgres -q && { PRETE=oui; break; }
  sleep 1
done
if [ "$PRETE" != oui ]; then
  echo "La base ne répond pas après 30 s (Docker Desktop démarré ? docker logs nv_rust_db)."
  exit 1
fi
if ! docker exec nv_rust_db psql -U postgres -d nv_serveur -Atc "select 1" > /dev/null 2>&1; then
  echo "La base du serveur (nv_serveur) n'existe pas : python server/outils/base_locale.py --serveur"
  exit 1
fi

# Une clé de badge qui survit aux redémarrages : sinon chaque redémarrage du
# serveur oblige le téléphone à renouveler sa session, et les services
# natifs (présence en soirée, balise du ping) s'arrêtent jusqu'à ce que
# l'app soit rouverte. Rangée hors dépôt, avec les accès de l'entrepôt.
ENV_LOCAL="$RACINE/docdev/serveur_local.env"
if ! grep -q '^NV_BADGE_CLE=' "$ENV_LOCAL"; then
  CLE="$(bash "$RACINE/server/outils/cargo.sh" run -q -p nv-server -- nouvelle-cle)"
  echo "NV_BADGE_CLE=$CLE" >> "$ENV_LOCAL"
  echo "Clé de badge créée (docdev/serveur_local.env)."
fi

# (La base du serveur a reçu les migrations « en service » à sa création,
# base_locale.py --serveur : sans l'ancien gardien, sinon le serveur refuse
# de démarrer — nv_app::ancien_gardien.)

echo "Serveur pour le téléphone : http://$IP:8787 — fichiers : http://$IP:8333"
echo "(Ctrl+C pour l'arrêter)"
NV_DATABASE_URL="postgres://postgres:neovibe@localhost:54329/nv_serveur" \
  NV_ADRESSE="0.0.0.0:8787" \
  NV_S3_PUBLIQUE="http://$IP:8333" \
  exec bash "$RACINE/server/outils/cargo.sh" run -q -p nv-server
