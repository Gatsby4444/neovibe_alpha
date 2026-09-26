"""La répétition du déménagement (2026-09-26).

Monte une base Postgres VIDE et jetable dans Docker, y rejoue toutes les
migrations du dépôt dans l'ordre, puis compare le résultat à la base de dev,
objet par objet (tables, colonnes, contraintes, index, fonctions, droits,
politiques, déclencheurs, tâches planifiées, temps réel, coffres, réglages).

Répond à UNE question : « les fichiers du dépôt suffisent-ils à reconstruire
le serveur à l'identique ? ». Tout ce qui a été fait à la main en base sans
fichier apparaît ici — c'est exactement ce qui manquerait sur le VPS.

Usage, depuis la racine du dépôt :   python tool/repetition_vps/repeter.py
Prérequis : Docker démarré (image postgres:17-alpine), PAT dans
docdev/PATsupabase.txt. Rien n'est écrit sur la base de dev : lecture seule.

⚠️ Ce n'est PAS Supabase : `bootstrap.sql` imite le strict nécessaire (rôles,
auth.uid(), storage.objects, et pg_cron / pgsodium qui manquent à l'image).
Les services eux-mêmes (connexion des comptes, stockage des fichiers, temps
réel) se vérifient sur le VPS, pas ici.
"""
import io
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from collections import Counter

sys.stdout.reconfigure(encoding='utf-8')
ICI = os.path.dirname(os.path.abspath(__file__))
RACINE = os.path.dirname(os.path.dirname(ICI))
PROJET = 'dvixmhvqqjvbrpsckmyi'
CONTENEUR = 'nv_repet'
ENV = dict(os.environ, MSYS_NO_PATHCONV='1')


def dev(sql):
    """Une requête en LECTURE sur la base de dev, par l'API de gestion."""
    tok = open(os.path.join(RACINE, 'docdev', 'PATsupabase.txt')).read().strip()
    req = urllib.request.Request(
        f'https://api.supabase.com/v1/projects/{PROJET}/database/query',
        data=json.dumps({'query': sql}).encode(),
        headers={'Authorization': 'Bearer ' + tok, 'Content-Type': 'application/json',
                 'User-Agent': 'neovibe-repetition'},
        method='POST')
    try:
        rows = json.loads(urllib.request.urlopen(req).read().decode())
    except urllib.error.HTTPError as e:
        sys.exit('base de dev : ' + e.read().decode())
    return '\n'.join(' | '.join(str(v) for v in r.values()) for r in rows)


def docker(*args, **kw):
    return subprocess.run(['docker', *args], env=ENV, capture_output=True, **kw)


def locale(fichier):
    r = docker('exec', CONTENEUR, 'psql', '-At', '-U', 'postgres', '-d', 'postgres',
               '-f', '/work/' + fichier)
    return r.stdout.decode('utf-8', 'replace')


CLES = ('table ', 'col ', 'con ', 'idx ', 'fn ', 'fnexec ', 'pol ', 'trg ', 'view ', 'enum ',
        'grant ', 'colgrant ', 'nsp ', 'cron ', 'realtime ', 'bucket ')


def lignes(texte):
    out = []
    for l in texte.replace('\r', '').split('\n'):
        if l.startswith(CLES) or not out:
            out.append(l)
        else:  # une définition sur plusieurs lignes
            out[-1] += ' ' + l
    return set(x.strip() for x in out if x.strip())


def main():
    print('1. Base vide et jetable…')
    docker('rm', '-f', CONTENEUR)
    r = docker('run', '-d', '--name', CONTENEUR, '-e', 'POSTGRES_PASSWORD=repetition',
               '-v', os.path.join(RACINE, 'supabase', 'migrations') + ':/migr:ro',
               '-v', ICI + ':/work:ro', 'postgres:17-alpine', '-c', 'wal_level=logical')
    if r.returncode:
        sys.exit('Docker : ' + r.stderr.decode())
    for _ in range(30):
        if docker('exec', CONTENEUR, 'pg_isready', '-U', 'postgres').returncode == 0:
            break
        time.sleep(1)
    time.sleep(2)

    print('2. Les migrations, dans l\'ordre…')
    r = docker('exec', CONTENEUR, 'sh', '/work/replay.sh')
    print('   ' + r.stdout.decode('utf-8', 'replace').strip())
    if r.returncode:
        sys.exit(1)

    print('3. Comparaison avec la base de dev…')
    d = lignes(dev(open(os.path.join(ICI, 'inventory.sql'), encoding='utf-8').read()))
    l = lignes(locale('inventory.sql'))
    seul_dev, seul_local = sorted(d - l), sorted(l - d)
    cfg_dev = dev(open(os.path.join(ICI, 'cfg.sql'), encoding='utf-8').read()).strip()
    cfg_local = locale('cfg.sql').strip()

    print(f'   objets : dev {len(d)}, reconstruits {len(l)}')
    for titre, liste in (('seulement en dev', seul_dev), ('seulement reconstruit', seul_local)):
        print(f'   {titre} : {dict(Counter(x.split(" ")[0] for x in liste)) or "rien"}')
        for x in liste:
            print('     ' + x[:160])
    print('   réglages : ' + ('identiques' if cfg_dev == cfg_local else 'DIFFÉRENTS'))
    docker('rm', '-f', CONTENEUR)
    print('   (base jetable supprimée)')


if __name__ == '__main__':
    main()
