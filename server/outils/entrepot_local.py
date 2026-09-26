"""Monte l'entrepôt de fichiers LOCAL (SeaweedFS, compatible S3) — port 8333.

MinIO n'est plus distribué en image Docker (constaté le 2026-09-27) ;
SeaweedFS parle le même S3 (liens signés, envoi en morceaux).

Les accès sont tirés au hasard au premier lancement et rangés dans
`docdev/serveur_local.env` (ignoré par git), avec les autres variables du
serveur local. `outils/cargo.sh` les charge.

Usage, depuis la racine du dépôt :  python server/outils/entrepot_local.py
"""
import json
import os
import secrets
import socket
import subprocess
import sys
import time

sys.stdout.reconfigure(encoding='utf-8')
RACINE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DOCDEV = os.path.join(RACINE, 'docdev')
ENV_LOCAL = os.path.join(DOCDEV, 'serveur_local.env')
S3_JSON = os.path.join(DOCDEV, 'seaweedfs_s3.json')
NOM = 'nv_s3'
ENV = dict(os.environ, MSYS_NO_PATHCONV='1')


def lire_env():
    valeurs = {}
    if os.path.exists(ENV_LOCAL):
        for l in open(ENV_LOCAL, encoding='utf-8'):
            if '=' in l and not l.startswith('#'):
                k, v = l.strip().split('=', 1)
                valeurs[k] = v
    return valeurs


def main():
    os.makedirs(DOCDEV, exist_ok=True)
    v = lire_env()
    if 'NV_S3_CLE' not in v:
        v['NV_S3_CLE'] = 'nv' + secrets.token_hex(8)
        v['NV_S3_SECRET'] = secrets.token_hex(24)
    v.setdefault('NV_S3_INTERNE', 'http://127.0.0.1:8333')
    v.setdefault('NV_S3_REGION', 'us-east-1')
    v.setdefault('NV_S3_PREFIXE', 'neovibe-')
    with open(ENV_LOCAL, 'w', encoding='utf-8') as f:
        f.write('# Serveur Rust LOCAL (développement) — généré par server/outils/entrepot_local.py.\n')
        f.write('# Jamais dans git (docdev/). Ces accès ne valent que pour l\'entrepôt local.\n')
        for k in sorted(v):
            f.write(f'{k}={v[k]}\n')
    with open(S3_JSON, 'w', encoding='utf-8') as f:
        json.dump({'identities': [{
            'name': 'neovibe',
            'credentials': [{'accessKey': v['NV_S3_CLE'], 'secretKey': v['NV_S3_SECRET']}],
            'actions': ['Admin', 'Read', 'Write', 'List', 'Tagging'],
        }]}, f)
    subprocess.run(['docker', 'rm', '-f', NOM], env=ENV, capture_output=True)
    r = subprocess.run(['docker', 'run', '-d', '--name', NOM, '-p', '8333:8333',
                        '-v', S3_JSON + ':/etc/seaweedfs/s3.json:ro',
                        'chrislusf/seaweedfs', 'server', '-s3', '-s3.port=8333',
                        '-s3.config=/etc/seaweedfs/s3.json', '-dir=/data'],
                       env=ENV, capture_output=True)
    if r.returncode:
        sys.exit(r.stderr.decode('utf-8', 'replace'))
    for _ in range(60):
        try:
            socket.create_connection(('127.0.0.1', 8333), timeout=1).close()
            break
        except OSError:
            time.sleep(1)
    time.sleep(3)
    print(f'Entrepôt local prêt : {v["NV_S3_INTERNE"]} (accès dans {ENV_LOCAL})')


if __name__ == '__main__':
    main()
