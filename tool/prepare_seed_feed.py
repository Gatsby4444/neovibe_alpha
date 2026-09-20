# -*- coding: utf-8 -*-
"""Prépare des médias LIBRES DE DROITS pour le feed de test (2026-09-20).

Sources :
  - photos : Lorem Picsum (https://picsum.photos), des photos Unsplash
    (licence Unsplash : usage libre) ;
  - vidéos : Big Buck Bunny, Sintel (Blender Foundation, CC BY), Jellyfish
    (Xiph, CC BY) — clips de https://test-videos.co.uk.

« Comme si édités depuis l'app » : les mêmes sorties que `AlbumExport` et
`MediaTranscoder` — publications en 1080×1350 (4:5) ou 1080×1080, Flows et
faces de Vibe en 1080×1920 (9:16), JPEG q85, H.264 + AAC, `moov` en tête
(faststart), couvertures de vidéo extraites du fichier produit.

Sortie : docdev/seed-feed/  (ignoré par git)
Usage : python tool/prepare_seed_feed.py
"""
import io, os, subprocess, sys, urllib.request
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

OUT = os.path.join(os.path.dirname(__file__), '..', 'docdev', 'seed-feed')
os.makedirs(OUT, exist_ok=True)
FFMPEG = 'ffmpeg'


def fetch(url, dest):
    if os.path.exists(dest) and os.path.getsize(dest) > 0:
        return dest
    print('  ↓', url)
    req = urllib.request.Request(url, headers={'User-Agent': 'neovibe-seed/1.0'})
    with urllib.request.urlopen(req, timeout=120) as r, open(dest, 'wb') as f:
        f.write(r.read())
    return dest


def run(args):
    subprocess.run([FFMPEG, '-y', '-loglevel', 'error', *args], check=True)


# ── Photos : 24 photos 4:5, 6 carrées, 8 en 9:16 (faces de Vibe) ──────────
raw = os.path.join(OUT, 'raw')
os.makedirs(raw, exist_ok=True)
photos = []
for i in range(38):
    seed = 1000 + i * 7
    src = fetch(f'https://picsum.photos/seed/{seed}/1200/1600', os.path.join(raw, f'photo_{i:02d}.jpg'))
    if i < 24:
        w, h, name = 1080, 1350, f'pub_{i:02d}_4x5.jpg'
    elif i < 30:
        w, h, name = 1080, 1080, f'pub_{i:02d}_1x1.jpg'
    else:
        w, h, name = 1080, 1920, f'vibe_{i:02d}_9x16.jpg'
    dest = os.path.join(OUT, name)
    if not os.path.exists(dest):
        # Comme AlbumExport : recadrage centré au ratio, 1080 de large, q85.
        run(['-i', src, '-vf', f'scale={w}:{h}:force_original_aspect_ratio=increase,crop={w}:{h}', '-q:v', '3', dest])
    photos.append(name)

# ── Vidéos : 3 sources CC, découpées en clips de 8 à 20 s ─────────────────
videos_src = {
    'bbb': 'https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/720/Big_Buck_Bunny_720_10s_5MB.mp4',
    'jelly': 'https://test-videos.co.uk/vids/jellyfish/mp4/h264/720/Jellyfish_720_10s_5MB.mp4',
    'sintel': 'https://test-videos.co.uk/vids/sintel/mp4/h264/720/Sintel_720_10s_5MB.mp4',
}
clips = []
for key, url in videos_src.items():
    src = fetch(url, os.path.join(raw, f'{key}.mp4'))
    for j, (ratio, w, h) in enumerate([('4x5', 1080, 1350), ('9x16', 1080, 1920), ('1x1', 1080, 1080)]):
        name = f'video_{key}_{ratio}.mp4'
        dest = os.path.join(OUT, name)
        if not os.path.exists(dest):
            # Comme MediaTranscoder : H.264 3,5 Mbit/s, image-clé chaque seconde,
            # AAC, moov en tête. Rogné à 8–10 s.
            run(['-ss', str(j), '-t', '9', '-i', src,
                 '-vf', f'scale={w}:{h}:force_original_aspect_ratio=increase,crop={w}:{h},fps=30',
                 '-c:v', 'libx264', '-b:v', '3500k', '-g', '30', '-pix_fmt', 'yuv420p',
                 '-c:a', 'aac', '-b:a', '96k', '-movflags', '+faststart', dest])
        poster = os.path.join(OUT, name.replace('.mp4', '_poster.jpg'))
        if not os.path.exists(poster):
            # La couverture, tirée du fichier PRODUIT, à 1,5 s.
            run(['-ss', '1.5', '-i', dest, '-frames:v', '1', '-q:v', '3', poster])
        clips.append(name)

print('photos :', len(photos), '· vidéos :', len(clips), '→', os.path.abspath(OUT))
