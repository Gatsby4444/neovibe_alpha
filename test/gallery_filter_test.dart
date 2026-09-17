import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/features/library/album_editor/gallery/native_gallery.dart';

/// Ce que ce test défend : **le filtre de la galerie a une égalité de
/// valeur.** C'est elle, et rien d'autre, qui décide si la grille se recharge
/// — un filtre sans `==` rechargerait à chaque reconstruction, ou jamais.
void main() {
  const camera = GalleryAlbum(id: '42', name: 'Camera', count: 1045);
  const camera2 = GalleryAlbum(id: '42', name: 'Camera', count: 1046);
  const snap = GalleryAlbum(id: '7', name: 'Snapchat', count: 131);

  test('deux filtres sur le même dossier sont le même filtre', () {
    // Le compte a bougé (une photo de plus) : ce n'est pas un autre dossier.
    expect(
      const GalleryFilter(album: camera),
      const GalleryFilter(album: camera2),
    );
    expect(
      const GalleryFilter(album: camera),
      isNot(const GalleryFilter(album: snap)),
    );
  });

  test('les trois raccourcis se distinguent', () {
    expect(GalleryFilter.tout, isNot(GalleryFilter.photos));
    expect(GalleryFilter.photos, isNot(GalleryFilter.videos));
    expect(GalleryFilter.tout, const GalleryFilter());
  });

  test('le titre dit ce qu\'on regarde', () {
    expect(GalleryFilter.tout.label, 'Récent');
    expect(GalleryFilter.photos.label, 'Photos');
    expect(GalleryFilter.videos.label, 'Vidéos');
    expect(const GalleryFilter(album: camera).label, 'Camera');
  });
}
