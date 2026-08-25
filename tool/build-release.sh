#!/usr/bin/env bash
# Construit l'APK de release et le signe AVEC LA PREUVE DE ROTATION.
#
# ⚠️ **Pourquoi ce script existe, et pourquoi il ne faut pas construire à la
# main.** Le 2026-08-25, deux pannes d'installation successives ont bloqué le
# test chez Jay :
#
#   -25  versionCode en recul  (passage d'APK découpés à un APK complet)
#   -7   signatures en conflit (la clé de debug est propre à CHAQUE machine)
#
# La seconde a été réglée par une **rotation de clé** : l'APK porte la preuve
# que l'ancienne clé autorise la nouvelle, donc il s'installe par-dessus une
# version signée par l'ancienne, sans désinstaller.
#
# `flutter build apk --release` seul produit un APK signé par la nouvelle clé
# SANS cette preuve — il ne s'installera pas sur un appareil qui a une version
# antérieure au 2026-08-25. **Rien ne le signale : l'APK se construit
# parfaitement, c'est l'installation qui échoue, chez Jay.** D'où ce script.
#
# Usage :  bash tool/build-release.sh
set -euo pipefail

cd "$(dirname "$0")/.."

SDK="${ANDROID_HOME:-D:/Android/Sdk}"
BT="$(ls -d "$SDK"/build-tools/*/ | sort -V | tail -1)"
APKSIGNER="${BT}apksigner.bat"
AAPT="${BT}aapt.exe"
APK="build/app/outputs/flutter-apk/app-release.apk"

ANCIENNE="docdev/ancienne-cle-debug.keystore"
NOUVELLE="docdev/neovibe-release.jks"
LIGNAGE="docdev/lineage-neovibe.bin"
MOTDEPASSE_FICHIER="docdev/keystore-password.txt"

for f in "$ANCIENNE" "$NOUVELLE" "$LIGNAGE" "$MOTDEPASSE_FICHIER"; do
  if [ ! -f "$f" ]; then
    echo "ARRET : $f manquant." >&2
    echo "Ces fichiers sont hors dépôt et DOIVENT suivre le projet d'une" >&2
    echo "machine à l'autre. Voir RAPPELS.md #13, #61 et RSUNA.md." >&2
    exit 1
  fi
done
MDP="$(cat "$MOTDEPASSE_FICHIER")"

echo "== 1/4 construction =="
flutter build apk --release

echo "== 2/4 signature avec preuve de rotation =="
# ⚠️ L'ordre compte : le signataire le PLUS ANCIEN d'abord, puis --next-signer.
# ⚠️ v1 et v2 ne peuvent pas porter deux signataires ; `minSdk` valant 29 et le
#    schéma v3 existant depuis l'API 28, ils sont inutiles ici.
"$APKSIGNER" sign \
  --lineage "$LIGNAGE" \
  --min-sdk-version 29 \
  --v1-signing-enabled false \
  --v2-signing-enabled false \
  --v3-signing-enabled true \
  --ks "$ANCIENNE" --ks-pass pass:android \
  --ks-key-alias androiddebugkey --key-pass pass:android \
  --next-signer \
  --ks "$NOUVELLE" --ks-pass "pass:$MDP" \
  --ks-key-alias neovibe --key-pass "pass:$MDP" \
  "$APK"

echo "== 3/4 vérification de la signature =="
"$APKSIGNER" verify --verbose --print-certs "$APK" | grep -E "Verified using v3|Signer.*DN:"

echo "== 4/4 vérification du versionCode =="
# ⚠️ Le SEUL contrôle qui prouve quelque chose : il doit dépasser celui de la
# release précédente (RAPPELS.md #60).
"$AAPT" dump badging "$APK" | head -1

echo
echo "OK. APK prêt : $APK"
echo "Contrôler AVANT de publier :"
echo "  - versionCode strictement supérieur à la release précédente"
echo "  - un bloc V3.1 avec CN=NeoVibe (appareils Android 13+)"
echo "  - un bloc V3.0 avec CN=Android Debug (appareils Android 10-12)"
