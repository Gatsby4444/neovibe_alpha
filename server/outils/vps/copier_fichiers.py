#!/usr/bin/env python3
"""Recopie les fichiers de Supabase (stockage de la base de dev) vers
l'entrepôt du VPS (Cloudflare R2) — EN ROOT SUR LE VPS
(`deployer.sh --fichiers` l'envoie et l'appelle).

La liste des fichiers est celle de la base du VPS (`storage.objects`, copie
de la dev) : on recopie exactement ce que la base connaît, pas plus. Même
chemin, coffre `avatars` → `neovibe-avatars` (`_` devenu `-`, comme
`EntrepotS3::nom_physique`), même type de contenu.

⚠️ Le nom du coffre recopie la règle du serveur (`EntrepotS3::nom_physique`,
server/crates/nv-entrepot/src/lib.rs) : outil de déménagement, joué une
fois par copie de la dev ; si cette règle change, la changer ici aussi.

Rejouable : un fichier déjà présent avec la même taille est sauté. Rien
n'est effacé, ni d'un côté ni de l'autre. Supabase n'est que lu.

L'adresse de Supabase et sa clé de service arrivent par l'ENTRÉE standard
(deux lignes), jamais par la ligne de commande ni par un fichier : elles ne
restent pas sur le VPS. Les accès à R2 sont ceux du serveur
(/etc/neovibe/nv-server.env).
"""
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

import boto3
from botocore.config import Config


def reglages():
    env = {}
    for ligne in open('/etc/neovibe/nv-server.env', encoding='utf-8'):
        # Seulement les accès de l'entrepôt : ni la clé des badges, ni le mot
        # de passe de la base ne sont lus ici.
        if ligne.startswith('NV_S3_') and '=' in ligne:
            k, v = ligne.rstrip('\n').split('=', 1)
            env[k] = v
    return env


def main():
    supabase = sys.stdin.readline().strip().rstrip('/')
    cle = sys.stdin.readline().strip()
    if not supabase.startswith('https://') or not cle:
        sys.exit('Attendu sur l\'entrée : l\'adresse de Supabase, puis sa clé de service.')
    env = reglages()
    s3 = boto3.client('s3', endpoint_url=env['NV_S3_INTERNE'], region_name=env.get('NV_S3_REGION') or 'auto',
                      aws_access_key_id=env['NV_S3_CLE'], aws_secret_access_key=env['NV_S3_SECRET'],
                      config=Config(s3={'addressing_style': 'path'}, retries={'max_attempts': 5}))
    prefixe = env.get('NV_S3_PREFIXE') or 'neovibe-'

    sortie = subprocess.run(
        ['sudo', '-u', 'postgres', 'psql', '-d', 'neovibe', '-At', '-F', '\t', '-c',
         "select bucket_id, name, coalesce(metadata->>'mimetype', 'application/octet-stream'), "
         "coalesce((metadata->>'size')::bigint, -1) from storage.objects order by 1, 2"],
        check=True, capture_output=True, text=True).stdout
    objets = [l.split('\t') for l in sortie.splitlines() if l]

    copies = sautes = 0
    echecs = []
    octets = 0
    for i, (coffre, nom, type_, taille) in enumerate(objets, 1):
        taille = int(taille)
        seau = prefixe + coffre.replace('_', '-')
        try:
            try:
                t = s3.head_object(Bucket=seau, Key=nom)
                if t['ContentLength'] == taille:
                    sautes += 1
                    continue
            except s3.exceptions.ClientError:
                pass
            url = f'{supabase}/storage/v1/object/{coffre}/{urllib.parse.quote(nom)}'
            req = urllib.request.Request(url, headers={'Authorization': 'Bearer ' + cle, 'apikey': cle})
            corps = urllib.request.urlopen(req, timeout=120).read()
            if taille >= 0 and len(corps) != taille:
                raise ValueError(f'taille lue {len(corps)} ≠ attendue {taille}')
            s3.put_object(Bucket=seau, Key=nom, Body=corps, ContentType=type_)
            copies += 1
            octets += len(corps)
        except urllib.error.HTTPError as e:
            echecs.append(f'{coffre}/{nom} : Supabase {e.code}')
        except Exception as e:  # noqa: BLE001 — on compte, on continue
            echecs.append(f'{coffre}/{nom} : {str(e)[:120]}')
        if i % 100 == 0:
            print(f'  {i}/{len(objets)}…', flush=True)

    print(f'{len(objets)} fichiers connus de la base : {copies} copiés ({octets / 1e6:.0f} Mo), '
          f'{sautes} déjà là, {len(echecs)} en échec')
    for e in echecs[:30]:
        print('  ÉCHEC', e)
    sys.exit(1 if echecs else 0)


if __name__ == '__main__':
    main()
