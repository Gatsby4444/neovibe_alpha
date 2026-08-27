#!/usr/bin/env bash
# Publie une release GitHub — et REFUSE de publier un APK qui ne s'installera
# pas chez Jay.
#
# ## ⚠️ Pourquoi ce script existe
#
# `RAPPELS.md` #61 disait déjà, depuis le 2026-08-25, en toutes lettres :
#
#     Ne plus jamais publier un APK produit par `flutter build apk --release`
#     seul : il est signé par la nouvelle clé SANS la preuve de rotation et ne
#     s'installera pas — sans que rien ne le signale.
#
# **Le 2026-08-27, deux releases ont été publiées exactement comme ça** (v0.9.135
# et v0.9.136), et la v0.9.136 a refusé de s'installer sur la tablette de Jay :
# « Application non installée », sans autre explication.
#
# ⚠️ **La note ne suffisait pas, et c'était prévisible** : une consigne écrite
# est un garde-fou, et `CLAUDE.md` dit qu'un garde-fou est un aveu — il faut le
# maintenir, le comprendre, et ne jamais le contourner par mégarde. C'est
# précisément ce qui s'est passé. Ce script **supprime la cause** : il n'y a plus
# de chemin de publication qui ne vérifie pas.
#
# ⚠️ **La vérification que j'avais faite ne pouvait pas voir le défaut** : j'ai
# comparé l'empreinte de la v0.9.136 à celle de la v0.9.135 — deux APK cassés de
# la même façon. Un instrument qui compare le neuf au neuf ne peut pas contenir
# la preuve du contraire. Ce script compare à des valeurs **attendues, écrites
# ici**, pas à la build précédente.
#
# Usage :  bash tool/publish-release.sh v0.9.137 "Titre" notes.md
set -euo pipefail

cd "$(dirname "$0")/.."

TAG="${1:?usage: publish-release.sh <tag> <titre> [fichier-de-notes]}"
TITRE="${2:?usage: publish-release.sh <tag> <titre> [fichier-de-notes]}"
NOTES="${3:-}"

SDK="${ANDROID_HOME:-D:/Android/Sdk}"
BT="$(ls -d "$SDK"/build-tools/*/ | sort -V | tail -1)"
APKSIGNER="${BT}apksigner.bat"
AAPT="${BT}aapt2.exe"
APK="build/app/outputs/flutter-apk/app-release.apk"

# ⚠️ **Les empreintes ATTENDUES, écrites en dur.** C'est ce qui rend le contrôle
# indépendant de la build précédente. Elles viennent de `docdev/keystore-README.txt`
# et de la v0.9.134, la dernière qui se soit installée sur les DEUX appareils.
NOUVELLE_CLE="b0aa3fc79e5ddb44337373d62d3d9e9cc69654a18957be5fe95bb2982c508474"
ANCIENNE_CLE="4df8a044a99356be33b0d51e88c353298a397065b114e16004473808ab573f1a"

echo "== 1/4 l'APK existe-t-il ? =="
[ -f "$APK" ] || { echo "ARRET : $APK introuvable. Lance d'abord tool/build-release.sh." >&2; exit 1; }

echo "== 2/4 la preuve de rotation est-elle là ? =="
CERTS="$("$APKSIGNER" verify --print-certs "$APK" 2>&1)"

if ! grep -q "V3.1 Signer.*$NOUVELLE_CLE" <<< "$CERTS"; then
  echo "ARRET : pas de signataire V3.1 avec la clé NeoVibe." >&2
  echo "L'APK ne s'installera pas sur les appareils Android 13+." >&2
  echo "Utilise tool/build-release.sh, pas 'flutter build apk --release'." >&2
  exit 1
fi

if ! grep -q "V3.0 Signer.*$ANCIENNE_CLE" <<< "$CERTS"; then
  echo "ARRET : pas de signataire V3.0 avec l'ancienne clé de debug." >&2
  echo "⚠️ C'EST LA PANNE DU 2026-08-27 : l'APK se construit parfaitement et" >&2
  echo "refuse de s'installer sur la tablette (Android 10), avec pour seule" >&2
  echo "explication « Application non installée »." >&2
  echo "Utilise tool/build-release.sh, pas 'flutter build apk --release'." >&2
  exit 1
fi
echo "   les deux signataires sont là."

echo "== 3/4 le versionCode progresse-t-il ? =="
CODE="$("$AAPT" dump badging "$APK" | head -1 | grep -o "versionCode='[0-9]*'" | grep -o "[0-9]*")"
NOM="$("$AAPT" dump badging "$APK" | head -1 | grep -o "versionName='[^']*'" | cut -d"'" -f2)"
PRECEDENT="$(gh release list --limit 1 --json tagName --jq '.[0].tagName' 2>/dev/null || echo '')"

if [ -n "$PRECEDENT" ]; then
  # ⚠️ On lit le versionCode de la release précédente sur SON artefact, pas sur
  # son nom : Android ne lit que le versionCode, jamais le versionName (#60).
  TMP="$(mktemp -d)"
  if gh release download "$PRECEDENT" -p "*.apk" -O "$TMP/prec.apk" >/dev/null 2>&1; then
    AVANT="$("$AAPT" dump badging "$TMP/prec.apk" | head -1 | grep -o "versionCode='[0-9]*'" | grep -o "[0-9]*")"
    if [ "$CODE" -le "$AVANT" ]; then
      echo "ARRET : versionCode $CODE <= $AVANT ($PRECEDENT)." >&2
      echo "Android refusera l'installation (-25). Monte la version dans pubspec.yaml." >&2
      rm -rf "$TMP"; exit 1
    fi
    echo "   $CODE > $AVANT ($PRECEDENT)."
  fi
  rm -rf "$TMP"
fi

echo "== 4/4 publication de $TAG ($NOM, versionCode $CODE) =="
CIBLE="build/neovibe-$TAG.apk"
cp "$APK" "$CIBLE"

if [ -n "$NOTES" ]; then
  gh release create "$TAG" "$CIBLE" --title "$TITRE" --notes-file "$NOTES"
else
  gh release create "$TAG" "$CIBLE" --title "$TITRE" --generate-notes
fi
