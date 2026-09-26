"""Copie les DONNÉES de la base de dev (Supabase) sur le PC — lecture seule.

Sert à la preuve par comparaison (docs/serveur-rust.md §4) : les deux
gardiens, l'ancien (SQL) et le nouveau (Rust), sont interrogés sur une copie
réaliste. Les fichiers vont dans `docdev/copie_base_dev/`, ignoré par git :
ce sont les comptes de test (adresses, empreintes de mots de passe), ils ne
quittent jamais le PC.

Usage, depuis la racine du dépôt :  python server/outils/copier_base_dev.py
Prérequis : le PAT dans docdev/PATsupabase.txt.
"""
import json
import os
import sys
import urllib.error
import urllib.request

sys.stdout.reconfigure(encoding='utf-8')
RACINE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PROJET = 'dvixmhvqqjvbrpsckmyi'
SORTIE = os.path.join(RACINE, 'docdev', 'copie_base_dev')
# Les tables propres à Supabase qu'on reprend (le reste de `auth` et de
# `storage` appartient à leurs logiciels).
EN_PLUS = [('auth', 'users'), ('storage', 'buckets'), ('storage', 'objects')]


def dev(sql):
    tok = open(os.path.join(RACINE, 'docdev', 'PATsupabase.txt')).read().strip()
    req = urllib.request.Request(
        f'https://api.supabase.com/v1/projects/{PROJET}/database/query',
        data=json.dumps({'query': sql}).encode(),
        headers={'Authorization': 'Bearer ' + tok, 'Content-Type': 'application/json',
                 'User-Agent': 'neovibe-copie'},
        method='POST')
    try:
        return json.loads(urllib.request.urlopen(req, timeout=120).read().decode())
    except urllib.error.HTTPError as e:
        sys.exit(f'base de dev : {e.read().decode()}')


def main():
    os.makedirs(SORTIE, exist_ok=True)
    tables = [(r['s'], r['t']) for r in dev(
        "select table_schema s, table_name t from information_schema.tables "
        "where table_schema in ('public', 'private') and table_type = 'BASE TABLE' order by 1, 2")]
    tables += EN_PLUS
    total = 0
    for schema, table in tables:
        lignes, page, taille = [], 0, 200
        while True:
            rows = dev(f'select coalesce(json_agg(t), \'[]\'::json) as j from '
                       f'(select * from {schema}."{table}" order by ctid '
                       f'offset {page * taille} limit {taille}) t')
            morceau = rows[0]['j']
            if isinstance(morceau, str):
                morceau = json.loads(morceau)
            lignes += morceau
            if len(morceau) < taille:
                break
            page += 1
        with open(os.path.join(SORTIE, f'{schema}.{table}.json'), 'w', encoding='utf-8') as f:
            json.dump(lignes, f, ensure_ascii=False)
        total += len(lignes)
        print(f'  {schema}.{table} : {len(lignes)}')
    print(f'{len(tables)} tables, {total} lignes -> {SORTIE}')


if __name__ == '__main__':
    main()
