import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FileOptions;

import '../../core/diagnostics/app_log.dart';
import '../../core/supabase_providers.dart';
import '../../core/widgets/avatar.dart';
import 'avatar_cropper_screen.dart';

/// Tout ce qui concerne **ma** photo de profil : la choisir, la recadrer, la
/// déposer, la retirer.
///
/// ### Pourquoi un seul endroit
///
/// La séquence existait en **double**, recopiée dans l'écran d'inscription et
/// dans l'édition de profil. Tant qu'elle se limitait à « choisir un fichier
/// et le téléverser », la duplication était sans conséquence. Elle en a une
/// dès qu'il faut recadrer, versionner le chemin et supprimer l'ancien
/// fichier : **une étape oubliée d'un côté ne se verrait ni au diff, ni à
/// `flutter analyze`** — juste un avatar qui ne se met pas à jour, sur un seul
/// écran, que personne ne relierait à sa cause.
class AvatarService {
  AvatarService(this._ref);

  final Ref _ref;

  static const _bucket = 'avatars';

  /// Propose l'appareil photo ou la galerie, puis recadre.
  ///
  /// Rend les octets PNG carrés, ou nul si l'utilisateur renonce à n'importe
  /// quelle étape.
  Future<Uint8List?> pickAndCrop(BuildContext context) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // L'appareil photo D'ABORD, et ce n'est pas un détail d'ordre :
            // NeoVibe est une app caméra-first, où le contenu se prend au
            // moment où il arrive. Reléguer la prise de vue au second rang
            // dirait le contraire de tout le reste du produit.
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Prendre une photo'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choisir dans la galerie'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return null;

    // Pas de `maxWidth`/`maxHeight` ici : le recadrage a besoin de la pleine
    // résolution pour que le zoom reste net. C'est lui qui produit les 512 px
    // finaux.
    final picked = await ImagePicker().pickImage(
      source: source,
      imageQuality: 95,
    );
    if (picked == null || !context.mounted) return null;

    return Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(
        builder: (_) => AvatarCropperScreen(source: File(picked.path)),
      ),
    );
  }

  /// Dépose une nouvelle photo et met le profil à jour. Rend le chemin stocké.
  ///
  /// ### Le chemin porte une version, et c'est ce qui règle le vrai problème
  ///
  /// Jusqu'au 2026-08-13, le fichier s'appelait toujours `<uid>/avatar.jpg`.
  /// Changer sa photo écrasait donc l'ancienne **au même chemin** — et
  /// l'ancienne image restait affichée, à trois niveaux de cache qui n'en
  /// savaient rien :
  ///
  /// 1. `avatarUrlProvider`, une famille Riverpod **sans `autoDispose`**,
  ///    indexée sur la valeur stockée — inchangée, donc jamais recalculée ;
  /// 2. l'URL signée elle-même, valable une heure ;
  /// 3. le cache d'images de Flutter, indexé sur l'URL.
  ///
  /// On aurait pu ajouter un paramètre anti-cache, invalider le provider et
  /// vider `imageCache`. Trois garde-fous à maintenir, pour une cause qui
  /// tient en une phrase : **deux images différentes portaient le même nom.**
  ///
  /// Un chemin versionné supprime la cause. Chaque dépôt crée un nom neuf, donc
  /// une clé de provider neuve, une URL neuve et une entrée de cache neuve —
  /// et aucun cache ne peut plus se tromper, y compris ceux qu'on ajoutera
  /// plus tard sans y penser.
  Future<String> upload(Uint8List bytes) async {
    final client = _ref.read(supabaseProvider);
    final me = client.auth.currentUser!.id;
    final previous = _ref.read(myProfileProvider).value?.avatarUrl;

    final path = '$me/avatar_${DateTime.now().millisecondsSinceEpoch}.png';
    await client.storage
        .from(_bucket)
        .uploadBinary(
          path,
          bytes,
          fileOptions: const FileOptions(contentType: 'image/png'),
        );
    await client.from('profiles').update({'avatar_url': path}).eq('id', me);

    // L'ancien fichier n'a plus aucun lecteur : le laisser, c'est faire
    // grossir le coffre d'une photo à chaque changement. Sans conséquence si
    // ça échoue — le profil pointe déjà ailleurs.
    await _deleteObject(previous);
    AppLog.instance.server('Photo de profil déposée', path);

    _ref.invalidate(myProfileProvider);
    return path;
  }

  /// Retire ma photo de profil.
  ///
  /// ⚠️ Ce n'était **pas possible** avant le 2026-08-13 : la mise à jour du
  /// profil utilisait l'entrée conditionnelle `'avatar_url': ?value`, qui
  /// **omet** la colonne quand la valeur est nulle. On pouvait donc changer sa
  /// photo, jamais l'enlever — et rien ne le disait, puisque l'écran
  /// enregistrait sans erreur.
  Future<void> remove() async {
    final client = _ref.read(supabaseProvider);
    final me = client.auth.currentUser!.id;
    final previous = _ref.read(myProfileProvider).value?.avatarUrl;

    await client.from('profiles').update({'avatar_url': null}).eq('id', me);
    await _deleteObject(previous);
    await _ref.read(avatarFileCacheProvider).purge(previous);
    AppLog.instance.action('Photo de profil retirée');

    _ref.invalidate(myProfileProvider);
  }

  Future<void> _deleteObject(String? stored) async {
    final path = avatarPath(stored);
    if (path == null) return;
    try {
      await _ref.read(supabaseProvider).storage.from(_bucket).remove([path]);
    } catch (_) {
      // Le fichier a déjà disparu, ou la politique refuse : sans importance,
      // plus rien ne le désigne.
    }
  }
}

final avatarServiceProvider = Provider(AvatarService.new);
