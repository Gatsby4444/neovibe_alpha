#!/usr/bin/env bash
# Construit l'APK de release, et vérifie l'artefact.
#
# ## 🔴 CE SCRIPT NE SIGNE PLUS — 2026-08-29
#
# Il portait la signature avec preuve de rotation, parce que le plugin Android
# ne sait pas la produire. C'était un **garde-fou**, et `CLAUDE.md` dit qu'un
# garde-fou est un aveu : il faut le maintenir, le comprendre, et ne jamais le
# contourner par mégarde. Il a été contourné — deux releases publiées par
# `flutter build apk --release` le 2026-08-27, dont une qui a refusé de
# s'installer chez Jay.
#
# **La cause est supprimée** : la signature vit maintenant dans
# `android/app/build.gradle.kts`, sur la tâche d'empaquetage. Il n'existe donc
# plus de chemin qui produise un APK sans la preuve — `flutter build apk`,
# `gradlew assembleRelease` ou n'importe quel outil futur passent tous par là.
# Et si les fichiers de rotation manquent, **la construction échoue** au lieu de
# livrer un artefact qui ne s'installera nulle part.
#
# ⚠️ **Ce script reste utile, et seulement pour ça** : il construit, puis il
# **relit l'artefact**. Deux vérifications sur le fichier produit, pas sur ce
# que la construction a dit avoir fait.
#
# Usage :  bash tool/build-release.sh
set -euo pipefail

cd "$(dirname "$0")/.."

SDK="${ANDROID_HOME:-D:/Android/Sdk}"
BT="$(ls -d "$SDK"/build-tools/*/ | sort -V | tail -1)"
APKSIGNER="${BT}apksigner.bat"
AAPT="${BT}aapt.exe"
APK="build/app/outputs/flutter-apk/app-release.apk"

echo "== 1/3 construction (la signature se fait DANS Gradle) =="
flutter build apk --release

echo "== 2/3 vérification de la signature, sur l'artefact =="
# ⚠️ **On relit le fichier, on ne croit pas la construction.** Gradle vérifie
# déjà, sur l'APK qu'il produit ; celui-ci est la COPIE que Flutter dépose et
# que Jay télécharge. Ce sont deux fichiers, donc deux vérifications.
PREUVE="$("$APKSIGNER" verify --print-certs "$APK")"
echo "$PREUVE" | grep -E "Signer.*DN:"
echo "$PREUVE" | grep -q "CN=NeoVibe" || { echo "ARRET : signataire NeoVibe absent." >&2; exit 1; }
echo "$PREUVE" | grep -q "CN=Android Debug" || {
  echo "ARRET : la preuve de rotation manque — cet APK ne s'installerait pas" >&2
  echo "par-dessus une version antérieure. Voir RAPPELS.md #61." >&2
  exit 1
}

echo "== 3/3 vérification du versionCode =="
# ⚠️ Le SEUL contrôle qui prouve quelque chose : il doit dépasser celui de la
# release précédente (RAPPELS.md #60).
"$AAPT" dump badging "$APK" | head -1

echo
echo "OK. APK prêt : $APK"
echo "Contrôler AVANT de publier :"
echo "  - versionCode strictement supérieur à la release précédente"
echo "  - un bloc V3.1 avec CN=NeoVibe (appareils Android 13+)"
echo "  - un bloc V3.0 avec CN=Android Debug (appareils Android 10-12)"
