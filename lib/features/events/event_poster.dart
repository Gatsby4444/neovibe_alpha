import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/diagnostics/app_log.dart';
import '../../core/supabase_providers.dart';
import '../../core/widgets/image_cropper_screen.dart';
import '../../core/work_dir.dart';
import '../cards/native_media.dart';
import 'events_repository.dart';

/// **L'affiche d'une soirée** (Jay, 2026-09-25) — le visuel qui fait
/// reconnaître une soirée d'un coup d'œil dans le radar. Format **3:4**,
/// comme un flyer.
///
/// ⚠️ **Pas chiffrée** : elle est faite pour être vue par ceux qui passent.
/// L'accès reste tenu par le serveur : coffre privé `event_posters`, lecture
/// réservée à qui voit la soirée et SEULEMENT pour l'affiche courante
/// (`event_posters_read`) ; dépôt réservé à l'organisateur, pendant la
/// soirée (`event_posters_insert`, `set_event_details`).
///
/// Chemin versionné `<moi>/<soirée>/poster_<horodatage>.jpg` : deux affiches
/// ne portent jamais le même nom, aucun cache ne peut les confondre (même
/// raison que les photos de profil).
class EventPosterService {
  EventPosterService(this.ref);
  final Ref ref;

  static const _bucket = 'event_posters';
  static const width = 900;
  static const height = 1200;

  /// Choisir une image dans la galerie, puis **la recadrer à la main** en
  /// 3:4 (2026-09-25 — c'était le centre, imposé). Rend le JPEG prêt à
  /// déposer, ou nul si l'utilisateur renonce.
  Future<File?> choose(BuildContext context) async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 95,
    );
    if (picked == null || !context.mounted) return null;
    return Navigator.of(context).push<File>(
      MaterialPageRoute(
        builder: (_) => ImageCropperScreen<File>(
          source: File(picked.path),
          aspect: width / height,
          // Assez pour zoomer net sur une affiche de 900 px de large, sans
          // charger en mémoire les 50 mégapixels d'un capteur récent.
          decodeWidth: 2400,
          produce: render,
        ),
      ),
    );
  }

  /// Le rectangle [src] de [image], rendu à [width]×[height], encodé en JPEG
  /// par le natif (le rendu `dart:ui` ne sait produire que du PNG, trois fois
  /// plus lourd).
  Future<File> render(ui.Image image, Rect src) async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(
      image,
      src,
      const Rect.fromLTWH(0, 0, width + 0.0, height + 0.0),
      ui.Paint()..filterQuality = FilterQuality.high,
    );
    final picture = recorder.endRecording();
    final rendered = await picture.toImage(width, height);
    picture.dispose();
    final data = await rendered.toByteData(format: ui.ImageByteFormat.rawRgba);
    rendered.dispose();
    if (data == null) throw StateError('Affiche illisible');
    final dir = await WorkDir.fresh('poster');
    final out = File('${dir.path}${Platform.pathSeparator}poster.jpg');
    await NativeMedia.encodeJpeg(
      rgba: data.buffer.asUint8List(),
      width: width,
      height: height,
      dest: out.path,
      quality: 84,
    );
    return out;
  }

  /// Dépose l'affiche de [eventId] et rend son chemin — à passer ensuite à
  /// `EventsRepository.setDetails`, qui seule la rend visible.
  Future<String> upload(String eventId, File jpeg) async {
    final client = ref.read(supabaseProvider);
    final me = client.auth.currentUser!.id;
    final path =
        '$me/$eventId/poster_${DateTime.now().millisecondsSinceEpoch}.jpg';
    await client.storage
        .from(_bucket)
        .uploadBinary(
          path,
          await jpeg.readAsBytes(),
          fileOptions: const FileOptions(contentType: 'image/jpeg'),
        );
    AppLog.instance.server('Affiche déposée', path);
    return path;
  }
}

final eventPosterServiceProvider = Provider(EventPosterService.new);

/// Les octets d'une affiche — téléchargés une fois par chemin (le chemin est
/// versionné : un chemin, une image, pour toujours).
final eventPosterBytesProvider = FutureProvider.family<Uint8List, String>((
  ref,
  path,
) {
  return ref
      .watch(supabaseProvider)
      .storage
      .from('event_posters')
      .download(path);
});

/// **La couleur d'une affiche** : sa teinte la plus vive, pour teinter le
/// fond du radar. Calculée sur une vignette de 24 px — les couleurs saturées
/// pèsent plus que les gris, sinon toute affiche sombre donnerait du noir.
final eventPosterColorProvider = FutureProvider.family<Color, String>((
  ref,
  path,
) async {
  final bytes = await ref.watch(eventPosterBytesProvider(path).future);
  return dominantColor(bytes);
});

Future<Color> dominantColor(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes, targetWidth: 24);
  final frame = await codec.getNextFrame();
  codec.dispose();
  final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
  frame.image.dispose();
  if (data == null) return const Color(0xFF6B2BD9);
  var r = 0.0, g = 0.0, b = 0.0, total = 0.0;
  for (var i = 0; i + 3 < data.lengthInBytes; i += 4) {
    final pr = data.getUint8(i) / 255;
    final pg = data.getUint8(i + 1) / 255;
    final pb = data.getUint8(i + 2) / 255;
    final hi = math.max(pr, math.max(pg, pb));
    final lo = math.min(pr, math.min(pg, pb));
    final poids = (hi - lo) * (hi - lo) + 0.02;
    r += pr * poids;
    g += pg * poids;
    b += pb * poids;
    total += poids;
  }
  return Color.fromARGB(
    255,
    (r / total * 255).round(),
    (g / total * 255).round(),
    (b / total * 255).round(),
  );
}

/// La couleur d'une soirée SANS affiche : tirée de son nom, toujours la même.
Color eventSeedColor(String title) {
  final h = title.codeUnits.fold<int>(7, (a, c) => (a * 31 + c) & 0xffff);
  return HSLColor.fromAHSL(1, (h % 360).toDouble(), 0.62, 0.42).toColor();
}

/// **L'affiche, ou son remplaçant** : sans affiche, un dégradé aux couleurs
/// de la soirée et ses initiales — aucune carte ne doit paraître vide.
class EventPoster extends ConsumerWidget {
  const EventPoster({
    super.key,
    required this.title,
    this.posterPath,
    this.radius = 22,
  });

  final String title;
  final String? posterPath;
  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = posterPath;
    final bytes = path == null
        ? null
        : ref.watch(eventPosterBytesProvider(path)).value;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: AspectRatio(
        aspectRatio: 3 / 4,
        child: bytes != null
            ? Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true)
            : _Generated(title: title),
      ),
    );
  }
}

class _Generated extends StatelessWidget {
  const _Generated({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    final base = eventSeedColor(title);
    final initiales = title
        .split(RegExp(r'\s+'))
        .where((m) => m.isNotEmpty)
        .take(2)
        .map((m) => m.characters.first.toUpperCase())
        .join();
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            HSLColor.fromColor(base).withLightness(0.55).toColor(),
            base,
            HSLColor.fromColor(base).withLightness(0.16).toColor(),
          ],
        ),
      ),
      child: Center(
        child: Text(
          initiales,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 64,
            fontWeight: FontWeight.w700,
            letterSpacing: 2,
          ),
        ),
      ),
    );
  }
}

/// **Enregistrer le profil d'une soirée** — un seul chemin pour la création
/// et les réglages : déposer la nouvelle affiche s'il y en a une, puis la
/// rendre visible avec la description (`set_event_details`). Sans affiche
/// neuve, l'affiche en place ne bouge pas, sauf si [clearPoster].
Future<void> saveEventProfile(
  WidgetRef ref,
  String eventId, {
  required String description,
  File? newPoster,
  bool clearPoster = false,
}) async {
  final path = newPoster == null
      ? null
      : await ref.read(eventPosterServiceProvider).upload(eventId, newPoster);
  await ref
      .read(eventsRepositoryProvider)
      .setDetails(
        eventId,
        description: description.trim(),
        posterPath: path,
        clearPoster: clearPoster && path == null,
      );
}

/// **L'affiche et la description, à remplir** — la création et les réglages
/// d'une soirée montrent le même bloc.
class EventProfileFields extends StatelessWidget {
  const EventProfileFields({
    super.key,
    required this.title,
    required this.description,
    required this.newPoster,
    required this.currentPosterPath,
    required this.onPick,
    required this.onClear,
    this.enabled = true,
  });

  final String title;
  final TextEditingController description;

  /// L'affiche choisie à l'instant (pas encore déposée).
  final File? newPoster;

  /// L'affiche en place, s'il y en a une.
  final String? currentPosterPath;
  final VoidCallback onPick;
  final VoidCallback onClear;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final aUneAffiche = newPoster != null || currentPosterPath != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 96,
              child: GestureDetector(
                onTap: enabled ? onPick : null,
                child: newPoster != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: AspectRatio(
                          aspectRatio: 3 / 4,
                          child: Image.file(newPoster!, fit: BoxFit.cover),
                        ),
                      )
                    : EventPoster(
                        title: title.isEmpty ? '?' : title,
                        posterPath: currentPosterPath,
                        radius: 12,
                      ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Affiche (facultatif)',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Format vertical 3:4. On la reconnaît d\'un coup d\'œil '
                    'dans le radar de ceux qui passent.',
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    children: [
                      OutlinedButton.icon(
                        onPressed: enabled ? onPick : null,
                        icon: const Icon(Icons.image_outlined, size: 18),
                        label: Text(aUneAffiche ? 'Changer' : 'Choisir'),
                      ),
                      if (aUneAffiche)
                        TextButton(
                          onPressed: enabled ? onClear : null,
                          child: const Text('Retirer'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: description,
          enabled: enabled,
          maxLength: 200,
          maxLines: 3,
          minLines: 1,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Description (facultatif)',
            hintText: 'Ce qui se passe ce soir, en deux phrases',
          ),
        ),
      ],
    );
  }
}

/// **Modifier l'affiche et la description** d'une soirée en cours — depuis
/// ses réglages. Même bloc qu'à la création ([EventProfileFields]), même
/// chemin d'écriture ([saveEventProfile]).
class EventProfileEditScreen extends ConsumerStatefulWidget {
  const EventProfileEditScreen({
    super.key,
    required this.eventId,
    required this.title,
    this.description,
    this.posterPath,
  });

  final String eventId;
  final String title;
  final String? description;
  final String? posterPath;

  @override
  ConsumerState<EventProfileEditScreen> createState() =>
      _EventProfileEditScreenState();
}

class _EventProfileEditScreenState
    extends ConsumerState<EventProfileEditScreen> {
  late final _description = TextEditingController(
    text: widget.description ?? '',
  );
  File? _poster;
  var _cleared = false;
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await saveEventProfile(
        ref,
        widget.eventId,
        description: _description.text,
        newPoster: _poster,
        clearPoster: _cleared,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: const Text('Affiche et description'),
        actions: [
          TextButton(
            onPressed: _busy ? null : _save,
            child: const Text('Enregistrer'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          EventProfileFields(
            title: widget.title,
            description: _description,
            newPoster: _poster,
            currentPosterPath: _cleared ? null : widget.posterPath,
            enabled: !_busy,
            onPick: () async {
              final f = await ref
                  .read(eventPosterServiceProvider)
                  .choose(context);
              if (f != null && mounted) {
                setState(() {
                  _poster = f;
                  _cleared = false;
                });
              }
            },
            onClear: () => setState(() {
              _poster = null;
              _cleared = true;
            }),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}
