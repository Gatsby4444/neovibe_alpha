#!/usr/bin/env bash
# Construit l'APP D'ESSAI du serveur Rust (docs/serveur-rust.md, étape 11) :
# « NeoVibe (Rust) », un AUTRE paquet (`com.neovibe.neovibe.essairust`) qui
# s'installe À CÔTÉ de l'app habituelle, sans la remplacer ni toucher à ses
# données, et qui parle au serveur Rust du PC (serveur_telephone.sh).
#
#   bash server/outils/app_d_essai.sh                 # l'adresse actuelle du PC
#   bash server/outils/app_d_essai.sh 192.168.1.20    # une adresse donnée
#   bash server/outils/app_d_essai.sh --publier [IP]  # et la déposer sur GitHub
#   bash server/outils/app_d_essai.sh [--publier] --vps  # le VRAI serveur :
#                                       https://api.neovibe.fun (étape 12)
#
# L'adresse du serveur est GRAVÉE dans l'APK : si le PC en change, il faut
# reconstruire (serveur_telephone.sh le signale).
#
# Résultat : build/essai_rust/NeoVibe-Rust.apk (arm64, comme les APK de
# test habituels), et build/essai_rust/adresse.txt. Avec `--publier` : une
# PRÉ-VERSION GitHub `essai-rust-v<version>` — jamais « la dernière
# version », que lit le bouton de mise à jour de l'app habituelle.
set -euo pipefail
RACINE="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$RACINE"

PUBLIER=0
if [ "${1:-}" = "--publier" ]; then
  PUBLIER=1
  shift
fi
if [ "$PUBLIER" = 1 ] && [ -n "$(git status --porcelain)" ]; then
  # L'APK doit sortir d'un commit, que la pré-version désigne.
  echo "ARRET : l'arbre n'est pas propre — enregistrer (commit) avant de publier." >&2
  exit 1
fi

# Deux cibles, deux pré-versions distinctes : l'APK du PC et celui du VPS
# parlent à deux serveurs différents et ne se remplacent jamais.
if [ "${1:-}" = "--vps" ]; then
  # Le serveur du VPS, derrière son portier https : joignable de partout.
  # Le même nom que HOTE dans server/outils/vps/deployer.sh.
  CIBLE=vps
  URL="https://api.neovibe.fun"
  OU="parle au serveur Rust du VPS ($URL), joignable de partout"
else
  CIBLE=pc
  IP="${1:-$(python -c "import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(('8.8.8.8', 80)); print(s.getsockname()[0])")}"
  URL="http://$IP:8787"
  OU="parle au serveur Rust du PC ($URL) par le Wi-Fi de la maison"
fi
echo "App d'essai pour le serveur $URL"

# `NEOVIBE_ESSAI_RUST=1` : l'autre paquet et le droit de parler en clair
# (android/app/build.gradle.kts) ; `SERVEUR_URL` : l'adresse du serveur
# visé (lib/core/api/serveur.dart).
NEOVIBE_ESSAI_RUST=1 flutter build apk --release --split-per-abi \
  --target-platform android-arm64 \
  --dart-define="SERVEUR_URL=$URL"

mkdir -p build/essai_rust
cp build/app/outputs/flutter-apk/app-arm64-v8a-release.apk build/essai_rust/NeoVibe-Rust.apk
# L'adresse du PC gravée dans l'APK, que serveur_telephone.sh compare à
# celle du moment. Un APK pour le VPS ne dépend pas du PC : pas de fichier.
if [ "$CIBLE" = pc ]; then
  echo "$IP" > build/essai_rust/adresse.txt
else
  rm -f build/essai_rust/adresse.txt
fi

# Vérifié SUR L'ARTEFACT, pas cru sur parole : le paquet et le nom affiché.
SDK="$(cygpath -u "${ANDROID_HOME:-D:/Android/Sdk}" 2> /dev/null || echo "${ANDROID_HOME:-D:/Android/Sdk}")"
AAPT="$(ls -d "$SDK"/build-tools/*/ | sort -V | tail -1)aapt"
BADGE="$("$AAPT" dump badging build/essai_rust/NeoVibe-Rust.apk)"
echo "$BADGE" | grep -E "^package:|^application-label:"
if ! echo "$BADGE" | grep -q "name='com.neovibe.neovibe.essairust'"; then
  echo "🔴 Ce n'est PAS le paquet de l'app d'essai : il remplacerait l'app habituelle. Ne pas l'installer."
  exit 1
fi
echo "Prêt : build/essai_rust/NeoVibe-Rust.apk"

if [ "$PUBLIER" = 1 ]; then
  VERSION="$(echo "$BADGE" | head -1 | grep -o "versionName='[^']*'" | cut -d"'" -f2)"
  if [ "$CIBLE" = vps ]; then TAG="essai-rust-vps-v$VERSION"; else TAG="essai-rust-v$VERSION"; fi
  SHA="$(git rev-parse HEAD)"
  git push origin HEAD:master
  NOTES="App d'essai « NeoVibe (Rust) » : s'installe À CÔTÉ de NeoVibe, $OU. Mode d'emploi : docs/serveur-rust.md, « L'app d'essai »."
  if gh release view "$TAG" > /dev/null 2>&1; then
    # Même version et même cible, autre construction : on remplace l'APK.
    gh release upload "$TAG" build/essai_rust/NeoVibe-Rust.apk --clobber
    gh release edit "$TAG" --notes "$NOTES"
  else
    gh release create "$TAG" build/essai_rust/NeoVibe-Rust.apk --prerelease --target "$SHA" \
      --title "App d'essai du serveur Rust ($CIBLE) — v$VERSION" --notes "$NOTES"
  fi
  echo "Publiée : pré-version $TAG"
fi
