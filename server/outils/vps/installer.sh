#!/usr/bin/env bash
# Installe sur le VPS ce dont le serveur NeoVibe a besoin — à lancer EN ROOT
# SUR LE VPS (deployer.sh le copie et l'appelle). Rejouable : ce qui existe
# déjà n'est pas refait, et aucun secret existant n'est écrasé.
#
# Ce qu'il pose (docs/serveur-rust.md, étape 12) :
# - PostgreSQL 17 (dépôt officiel de PostgreSQL : Ubuntu 26.04 ne fournit
#   que la 18, et le schéma est prouvé sur la 17), joignable SEULEMENT
#   depuis la machine elle-même ;
# - Caddy, le portier https (dépôt officiel de Caddy : celui d'Ubuntu est
#   figé en 2.6, de 2022), qui obtient et renouvelle seul le certificat de
#   api.neovibe.fun ;
# - Rust, pour construire le serveur sur place ;
# - l'utilisateur système `neovibe`, qui fait tourner le serveur (sans
#   shell, sans droits) ;
# - le service `nv-server` et la sauvegarde quotidienne de la base.
set -euo pipefail
ICI="$(cd "$(dirname "$0")" && pwd)"
export DEBIAN_FRONTEND=noninteractive

echo "1. Paquets de base…"
apt-get update -q
apt-get install -y -q ca-certificates curl gnupg build-essential pkg-config debian-keyring debian-archive-keyring apt-transport-https ufw

echo "   Entrée par clé seulement, pare-feu…"
# L'image Hostinger laissait l'entrée par mot de passe ouverte
# (50-cloud-init.conf, constaté le 2026-09-28) : notre fichier est lu
# AVANT (00-), et en SSH la première valeur lue l'emporte.
cat > /etc/ssh/sshd_config.d/00-neovibe.conf <<'EOF'
# NeoVibe (server/outils/vps/installer.sh) : on n'entre qu'avec une clé.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
EOF
sshd -t
systemctl reload ssh
# Entrent : SSH, et le portier https (80 pour le certificat et la
# redirection, 443 en TCP et en UDP — HTTP/3). Tout le reste est refusé.
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment ssh
ufw allow 80/tcp comment http
ufw allow 443/tcp comment https
ufw allow 443/udp comment http3
ufw --force enable

echo "2. PostgreSQL 17…"
if [ ! -f /etc/apt/sources.list.d/pgdg.list ]; then
  install -d /usr/share/postgresql-common/pgdg
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
  echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list
  apt-get update -q
fi
apt-get install -y -q postgresql-17
# Joignable seulement depuis la machine (c'est déjà le défaut : on l'écrit
# pour que ce soit une règle, pas un hasard).
PGCONF=/etc/postgresql/17/main/conf.d/neovibe.conf
cat > "$PGCONF" <<'EOF'
# NeoVibe (server/outils/vps/installer.sh) : la base n'écoute que la
# machine elle-même ; seul le serveur NeoVibe lui parle.
listen_addresses = 'localhost'
EOF
systemctl restart postgresql@17-main

echo "3. Caddy…"
if [ ! -f /etc/apt/sources.list.d/caddy-stable.list ]; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -q
fi
apt-get install -y -q caddy
install -m 644 "$ICI/Caddyfile" /etc/caddy/Caddyfile
# Sans interface d'administration (Caddyfile), Caddy ne se recharge pas : il redémarre.
systemctl restart caddy

echo "4. Rust…"
if [ ! -x /root/.cargo/bin/cargo ]; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
fi

echo "5. L'utilisateur neovibe et les dossiers…"
id neovibe >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin neovibe
install -d -m 755 /opt/neovibe /opt/neovibe/bin
install -d -m 700 /etc/neovibe
install -d -m 700 -o postgres -g postgres /var/backups/neovibe

echo "6. Les secrets (jamais écrasés)…"
ENV=/etc/neovibe/nv-server.env
if [ ! -f "$ENV" ]; then
  umask 077
  cat > "$ENV" <<EOF
# Configuration du serveur NeoVibe (server/crates/nv-server/src/config.rs).
# Lisible par root seulement. Jamais dans le dépôt.
NV_DATABASE_URL=
NV_ADRESSE=127.0.0.1:8787
NV_PORTIER_LOCAL=1
NV_BADGE_CLE=
NV_S3_INTERNE=
NV_S3_PUBLIQUE=
NV_S3_REGION=auto
NV_S3_CLE=
NV_S3_SECRET=
EOF
  echo "   $ENV créé — reste à remplir : NV_S3_CLE, NV_S3_SECRET (la clé des badges est tirée au déploiement)"
fi
# Le serveur se connecte avec SON rôle, `nv_server` : lire et écrire des
# données, rien d'autre (server/migrations/20260929000000_le_role_du_serveur.sql
# lui donne ses droits ; ici, la machine lui donne le droit de se connecter
# et son mot de passe). `postgres` n'a PAS de mot de passe : on ne l'atteint
# que depuis la machine, en tant qu'utilisateur système postgres
# (sudo -u postgres), pour les migrations et les sauvegardes. Le mot de
# passe passe par l'entrée de psql, jamais par sa ligne de commande.
if ! grep -q '^NV_DATABASE_URL=postgres://nv_server:' "$ENV"; then
  MDP="$(openssl rand -hex 24)"
  sudo -u postgres psql -q -v ON_ERROR_STOP=1 -v mdp="$MDP" <<'SQL'
select 'create role nv_server' where not exists (select 1 from pg_roles where rolname = 'nv_server')
\gexec
alter role nv_server login password :'mdp';
alter role postgres password null;
SQL
  sed -i "s#^NV_DATABASE_URL=.*#NV_DATABASE_URL=postgres://nv_server:$MDP@127.0.0.1:5432/neovibe#" "$ENV"
  echo "   rôle nv_server : mot de passe tiré au sort"
fi

echo "7. Le service et la sauvegarde…"
install -m 644 "$ICI/nv-server.service" /etc/systemd/system/nv-server.service
install -m 755 "$ICI/sauvegarde.sh" /opt/neovibe/bin/sauvegarde.sh
install -m 755 "$ICI/restaurer.sh" /opt/neovibe/bin/restaurer.sh
install -m 644 "$ICI/nv-sauvegarde.service" /etc/systemd/system/nv-sauvegarde.service
install -m 644 "$ICI/nv-sauvegarde.timer" /etc/systemd/system/nv-sauvegarde.timer
systemctl daemon-reload
systemctl enable --now nv-sauvegarde.timer
systemctl enable nv-server.service

echo "Installé."
