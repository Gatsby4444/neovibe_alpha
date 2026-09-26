#!/usr/bin/env bash
# Lance cargo avec la bonne chaîne de construction sur le PC de Jay.
#
# Sur ce PC (Windows, chaîne Rust « GNU »), l'éditeur de liens fourni par
# Rust est incomplet (« cannot find crt2.o », constaté le 2026-09-26) : on
# lui préfère la chaîne MinGW complète de WinLibs, déjà installée. Ailleurs
# (Linux, le VPS), ce script ne change rien et appelle cargo tel quel.
set -euo pipefail
W="/c/Users/USER/AppData/Local/Microsoft/WinGet/Packages/BrechtSanders.WinLibs.POSIX.MSVCRT_Microsoft.Winget.Source_8wekyb3d8bbwe/mingw64/bin"
if [ -x "$W/gcc.exe" ]; then
  export PATH="$W:$PATH"
  export CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER="$W/gcc.exe"
  export RUSTFLAGS="${RUSTFLAGS:-} -C link-self-contained=no"
fi
# La base locale de travail (outils/base_locale.py) : sqlx y vérifie chaque
# requête au moment de la construction.
export DATABASE_URL="${DATABASE_URL:-postgres://postgres:neovibe@localhost:54329/postgres}"
# Les variables du serveur local (entrepôt de fichiers…), hors dépôt.
ENV_LOCAL="$(dirname "$0")/../../docdev/serveur_local.env"
if [ -f "$ENV_LOCAL" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_LOCAL"
  set +a
fi
cd "$(dirname "$0")/.."
exec cargo "$@"
