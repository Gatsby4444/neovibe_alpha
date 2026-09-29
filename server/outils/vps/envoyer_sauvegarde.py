#!/usr/bin/env python3
"""Envoie la dernière sauvegarde de la base HORS du VPS, dans le coffre R2
`neovibe-sauvegardes` — lancé en root après chaque sauvegarde
(nv-sauvegarde.service, `ExecStartPost=+`).

Pourquoi : les sauvegardes de /var/backups/neovibe sont sur le même disque
que la base ; la perte du VPS les emporterait avec elle. Dans le coffre,
chaque envoi est intouchable 30 jours (verrou : même la clé du serveur ne
peut ni l'effacer ni le remplacer), puis effacé à 31 jours (cycle de vie) ;
les deux règles sont posées et relues par regles_r2.py.

Les deux fichiers d'un même passage partent ensemble (`neovibe-<date>.dump`
et `roles-<date>.sql`) : sans les rôles, la base ne se restaure pas sur une
machine neuve (restaurer.sh). Pour restaurer depuis R2 : les télécharger
dans un même dossier, puis restaurer.sh.
"""
import glob
import os
import sys

import boto3
from botocore.config import Config

DOSSIER = '/var/backups/neovibe'
COFFRE = 'sauvegardes'


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
    dumps = sorted(glob.glob(f'{DOSSIER}/neovibe-*.dump'))
    if not dumps:
        sys.exit('Aucune sauvegarde à envoyer.')
    dump = dumps[-1]
    date = os.path.basename(dump)[len('neovibe-'):-len('.dump')]
    roles = f'{DOSSIER}/roles-{date}.sql'
    if not os.path.exists(roles):
        sys.exit(f'Sauvegarde incomplète : {roles} manque, rien n\'est envoyé.')
    env = reglages()
    s3 = boto3.client('s3', endpoint_url=env['NV_S3_INTERNE'], region_name=env.get('NV_S3_REGION') or 'auto',
                      aws_access_key_id=env['NV_S3_CLE'], aws_secret_access_key=env['NV_S3_SECRET'],
                      config=Config(s3={'addressing_style': 'path'}, retries={'max_attempts': 5}))
    seau = (env.get('NV_S3_PREFIXE') or 'neovibe-') + COFFRE
    for f in (roles, dump):
        s3.upload_file(f, seau, os.path.basename(f))
        # Vérifié, pas supposé : la taille dans le coffre est celle du disque.
        if s3.head_object(Bucket=seau, Key=os.path.basename(f))['ContentLength'] != os.path.getsize(f):
            sys.exit(f'{os.path.basename(f)} : taille différente dans le coffre')
    print(f'envoyée hors du VPS : {os.path.basename(dump)} + {os.path.basename(roles)} → {seau}')


if __name__ == '__main__':
    main()
