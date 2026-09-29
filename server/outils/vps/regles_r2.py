"""Pose (et relit) les règles du coffre R2 des sauvegardes — depuis le PC.

    python server/outils/vps/regles_r2.py            pose les règles puis les affiche
    python server/outils/vps/regles_r2.py --lire     les affiche seulement

Le coffre `neovibe-sauvegardes` reçoit chaque nuit la sauvegarde de la base
(envoyer_sauvegarde.py), avec la clé S3 du serveur. Cette clé peut effacer :
si le serveur était compromis, les sauvegardes partiraient avec lui
(relevé par le relecteur le 2026-09-29). Au lieu d'une deuxième clé, on
supprime la cause : un VERROU sur le coffre — aucun objet ne peut être
effacé ni remplacé avant 30 jours, quelle que soit la clé.

- verrou : 30 jours (« bucket lock ») ;
- cycle de vie : effacement à 31 jours (après le verrou), et les envois en
  morceaux abandonnés effacés à 7 jours (la règle par défaut de R2).

Accès : le jeton Cloudflare de docdev/clouflare.txt (droits R2 ; il expire
le 2026-12-28, RAPPELS #176 ①).
"""
import json
import os
import re
import sys
import urllib.request

sys.stdout.reconfigure(encoding='utf-8')
RACINE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
COMPTE = 'f6094b62b3445d1cbf8b05e6945a1d16'
COFFRE = 'neovibe-sauvegardes'
JOUR = 86400

VERROU = {'rules': [{'id': 'sauvegardes-intouchables-30-jours', 'enabled': True, 'prefix': '',
                     'condition': {'type': 'Age', 'maxAgeSeconds': 30 * JOUR}}]}
CYCLE = {'rules': [
    {'id': 'Default Multipart Abort Rule', 'enabled': True, 'conditions': {},
     'abortMultipartUploadsTransition': {'condition': {'type': 'Age', 'maxAge': 7 * JOUR}}},
    {'id': 'sauvegardes-31-jours', 'enabled': True, 'conditions': {'prefix': ''},
     'deleteObjectsTransition': {'condition': {'type': 'Age', 'maxAge': 31 * JOUR}}},
]}


def jeton():
    texte = open(os.path.join(RACINE, 'docdev', 'clouflare.txt'), encoding='utf-8').read()
    return re.search(r'cfat[A-Za-z0-9_-]+|[A-Za-z0-9_-]{40,}', texte).group(0)


def cf(methode, chemin, corps=None):
    req = urllib.request.Request(
        f'https://api.cloudflare.com/client/v4/accounts/{COMPTE}/r2/buckets/{COFFRE}/{chemin}',
        data=json.dumps(corps).encode() if corps is not None else None, method=methode,
        headers={'Authorization': 'Bearer ' + jeton(), 'cf-r2-jurisdiction': 'eu',
                 'Content-Type': 'application/json'})
    r = json.loads(urllib.request.urlopen(req, timeout=60).read())
    if not r.get('success'):
        sys.exit(f'{chemin} : {r.get("errors")}')
    return r.get('result')


def main():
    if '--lire' not in sys.argv[1:]:
        cf('PUT', 'lifecycle', CYCLE)
        cf('PUT', 'lock', VERROU)
    for r in cf('GET', 'lock')['rules']:
        print(f"verrou  : {r['id']} — {r['condition'].get('maxAgeSeconds', 0) // JOUR} jours, actif={r['enabled']}")
    for r in cf('GET', 'lifecycle')['rules']:
        t = r.get('deleteObjectsTransition') or r.get('abortMultipartUploadsTransition')
        print(f"cycle   : {r['id']} — {t['condition']['maxAge'] // JOUR} jours, actif={r['enabled']}")


if __name__ == '__main__':
    main()
