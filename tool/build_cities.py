"""Fabrique assets/geo/cities.tsv.gz depuis GeoNames (cities5000, CC BY 4.0).

Usage :  python tool/build_cities.py chemin/vers/cities5000.zip
         (https://download.geonames.org/export/dump/cities5000.zip)

Sortie : une ligne par lieu, « nom <tab> lat <tab> lon <tab> pays », gzip.

⚠️ Les ARRONDISSEMENTS et quartiers y figurent comme des villes, codés de
façon incohérente (« Paris 16 Passy » en PPL, « Marseille 01 » en PPLA5,
« Lyon 02 » en PPLX — relevé le 2026-09-25). Règle qui ne dépend pas des
codes : un nom qui commence par le nom d'une ville du même pays suivi d'un
numéro, ou un quartier (PPLX) dont le nom commence par une ville du même pays,
prend le nom de cette ville. Le point est gardé (il densifie la ville), seul
le nom change : la galerie dit la VILLE (Jay : « le quartier plus tard »).
"""
import gzip
import io
import re
import sys
import zipfile

src = sys.argv[1]
rows = []
with zipfile.ZipFile(src) as z, z.open('cities5000.txt') as f:
    for line in io.TextIOWrapper(f, encoding='utf-8'):
        c = line.rstrip('\n').split('\t')
        rows.append((c[1], float(c[4]), float(c[5]), c[7], c[8]))

villes = {(n, cc) for n, _, _, code, cc in rows if code != 'PPLX'}
numero = re.compile(r'^(.+?) \d{1,2}(e|er)?\b')


def parent(nom, code, cc):
    m = numero.match(nom)
    if m and (m.group(1), cc) in villes:
        return m.group(1)
    if code == 'PPLX':
        mots = nom.split(' ')
        for k in range(len(mots) - 1, 0, -1):
            tete = ' '.join(mots[:k])
            if (tete, cc) in villes:
                return tete
        return None  # un quartier sans ville reconnue : écarté
    return nom


out = []
for nom, la, lo, code, cc in rows:
    p = parent(nom, code, cc)
    if p is None:
        continue
    out.append(f'{p}\t{round(la, 4)}\t{round(lo, 4)}\t{cc}')

data = '\n'.join(out).encode('utf-8')
with open('assets/geo/cities.tsv.gz', 'wb') as f:
    f.write(gzip.compress(data, 9))
print(len(out), 'lieux,', len(data), 'octets avant compression')
