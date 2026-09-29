"""Monte la base locale de travail du serveur Rust (Docker, port 54329).

1. une base PostgreSQL 17 vide et l'imitation minimale de Supabase
   (`tool/repetition_vps/bootstrap.sql`) ;
2-4. LA recette de la base (`recette_base.sh`, la même que sur le VPS) :
   les migrations de `supabase/migrations/` — la structure ET l'ancien
   gardien SQL, dont la preuve par comparaison a besoin —, celles du
   serveur Rust (`server/migrations/`), et la copie des données de dev
   (`docdev/copie_base_dev/`, voir `copier_base_dev.py`) ;
5. l'instrument de la preuve (`preuve.sql` : le journal des changements) ;
6. **la base du serveur** (`nv_serveur`), copie de la précédente.

## ⚠️ Deux bases, deux usages — jamais la même (2026-09-27)

| Base | Qui s'y branche | Ce qui la modifie |
|---|---|---|
| `postgres` — **la référence** | la preuve, `cargo` (sqlx) | rien : chaque situation de la preuve est annulée |
| `nv_serveur` — **la base de travail** | le serveur lancé, les essais de bout en bout, l'app d'essai | le serveur (ses balais passent chaque minute), les essais |

Constaté le 2026-09-27 : le serveur, lancé sur la référence pour un essai,
a fermé en une minute (balai des soirées, « désertée ») la soirée dont
5 situations de la preuve avaient besoin. Le balai avait raison ; c'est le
partage qui était faux.

Usage, depuis la racine du dépôt :
    python server/outils/base_locale.py            tout remonter
    python server/outils/base_locale.py --serveur  remettre la base du
                                                   serveur à l'état de la référence
Adresses :
    postgres://postgres:neovibe@localhost:54329/postgres    (la référence)
    postgres://postgres:neovibe@localhost:54329/nv_serveur  (le serveur)
"""
import os
import subprocess
import sys
import time

sys.stdout.reconfigure(encoding='utf-8')
ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.dirname(os.path.dirname(ICI))
NOM = 'nv_rust_db'
ENV = dict(os.environ, MSYS_NO_PATHCONV='1')


def docker(*args, check=True):
    r = subprocess.run(['docker', *args], env=ENV, capture_output=True)
    if check and r.returncode:
        sys.exit(f'docker {" ".join(args[:3])}… : {r.stderr.decode("utf-8", "replace")}'
                 f'{r.stdout.decode("utf-8", "replace")[-2000:]}')
    return r


def psql(fichier, un_bloc=True):
    args = ['exec', NOM, 'psql', '-q', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', 'postgres']
    if un_bloc:
        args.append('-1')
    return docker(*args, '-f', fichier)


def main():
    copie = os.path.join(RACINE, 'docdev', 'copie_base_dev')
    if not os.path.isdir(copie):
        sys.exit('Pas de copie des données : lancer d\'abord server/outils/copier_base_dev.py')
    print('1. Base vide…')
    docker('rm', '-f', NOM, check=False)
    docker('run', '-d', '--name', NOM, '-p', '54329:5432', '-e', 'POSTGRES_PASSWORD=neovibe',
           '-v', os.path.join(RACINE, 'supabase', 'migrations') + ':/migr:ro',
           '-v', os.path.join(RACINE, 'tool', 'repetition_vps') + ':/work:ro',
           '-v', copie + ':/copie:ro',
           '-v', os.path.join(RACINE, 'server', 'migrations') + ':/nvmigr:ro',
           '-v', ICI + ':/outils:ro',
           'postgres:17-alpine', '-c', 'wal_level=logical', '-c', 'max_connections=200')
    for _ in range(40):
        if docker('exec', NOM, 'pg_isready', '-U', 'postgres', check=False).returncode == 0:
            break
        time.sleep(1)
    time.sleep(2)

    # Étapes 2 à 4 : LA recette, la même que sur le VPS (recette_base.sh).
    r = docker('exec', '-e', 'BASE=postgres', '-e', 'TRAVAIL=/work', '-e', 'MIGR=/migr',
               '-e', 'NVMIGR=/nvmigr', '-e', 'OUTILS=/outils', '-e', 'COPIE=/copie',
               NOM, 'sh', '/outils/recette_base.sh')
    print(r.stdout.decode('utf-8', 'replace').rstrip())

    print('5. L\'instrument de la preuve…')
    psql('/outils/preuve.sql')
    base_du_serveur()
    print('Prête : postgres://postgres:neovibe@localhost:54329/postgres (la référence)')


def base_du_serveur():
    """La base de travail du serveur : une base EN SERVICE, comme celle du VPS
    — montée par LA recette (recette_base.sh) avec les migrations « en
    service » rangées parmi les autres dans le même ordre que sur le VPS
    (ordre_des_migrations.sh). Pas une copie de la référence retouchée
    ensuite : le retrait de l'ancien gardien, joué après une migration plus
    récente, en aurait effacé les fonctions (relecteur, 2026-09-29)."""
    print('6. La base du serveur (une base en service, comme le VPS)…')
    for requete in ('drop database if exists nv_serveur with (force)',
                    'create database nv_serveur',
                    'alter database nv_serveur set search_path = "$user", public, extensions'):
        r = docker('exec', NOM, 'psql', '-q', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres',
                   '-d', 'template1', '-c', requete, check=False)
        if r.returncode:
            sys.exit(f'{requete} : {r.stderr.decode("utf-8", "replace").strip()}\n'
                     'Quelque chose est branché sur la base du serveur (un serveur, un '
                     'essai) : l\'arrêter, puis relancer.')
    # Les migrations « en service » ne sont pas montées dans le conteneur :
    # on les y dépose (la référence ne les reçoit jamais).
    docker('exec', NOM, 'rm', '-rf', '/en_service')
    docker('cp', os.path.join(RACINE, 'server', 'migrations_en_service'), NOM + ':/en_service')
    r = docker('exec', '-e', 'BASE=nv_serveur', '-e', 'TRAVAIL=/work', '-e', 'MIGR=/migr',
               '-e', 'NVMIGR=/nvmigr', '-e', 'OUTILS=/outils', '-e', 'COPIE=/copie',
               '-e', 'EN_SERVICE=/en_service', NOM, 'sh', '/outils/recette_base.sh')
    print(r.stdout.decode('utf-8', 'replace').rstrip())
    print('   postgres://postgres:neovibe@localhost:54329/nv_serveur')


if __name__ == '__main__':
    if '--serveur' in sys.argv[1:]:
        base_du_serveur()
    else:
        main()
