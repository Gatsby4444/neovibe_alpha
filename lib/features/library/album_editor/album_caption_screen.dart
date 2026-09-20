import 'dart:io';

import 'package:flutter/material.dart';

import '../../../core/theme.dart';
import '../../../core/typography.dart';
import '../../../core/widgets/card_type_badge.dart';
import '../feed/caption_editor.dart';
import 'album_draft.dart';

/// La dernière étape avant de publier : la **légende**, la **visibilité** et
/// les **droits** — les mêmes que ceux d'une Card publiée (publique / selon
/// mes règles d'accès, partageable, sauvegardable), parce que c'est le même
/// contenu avec les mêmes règles.
///
/// Rend le brouillon complété, ou `null` si l'utilisateur revient en arrière.
class AlbumCaptionScreen extends StatefulWidget {
  const AlbumCaptionScreen({
    super.key,
    required this.draft,
    required this.coverThumb,
    this.onChanged,
  });

  final AlbumDraft draft;

  /// Le brouillon à chaque frappe et chaque réglage (Brouillons, 2026-09-20).
  final ValueChanged<AlbumDraft>? onChanged;

  /// La couverture (le premier média), pour rappeler ce qu'on publie.
  final Future<File?> coverThumb;

  @override
  State<AlbumCaptionScreen> createState() => _AlbumCaptionScreenState();
}

class _AlbumCaptionScreenState extends State<AlbumCaptionScreen> {
  late AlbumDraft _draft = widget.draft;
  late final _caption = TextEditingController(text: widget.draft.caption)
    ..addListener(_changed);

  void _changed() =>
      widget.onChanged?.call(_draft.copyWith(caption: _caption.text));

  @override
  void initState() {
    super.initState();
    // Arriver ici est déjà une étape : le brouillon le note.
    WidgetsBinding.instance.addPostFrameCallback((_) => _changed());
  }

  @override
  void dispose() {
    _caption.dispose();
    super.dispose();
  }

  void _publish() =>
      Navigator.of(context).pop(_draft.copyWith(caption: _caption.text));

  @override
  Widget build(BuildContext context) {
    final n = _draft.media.length;
    return Scaffold(
      appBar: AppBar(title: const Text('Publier')),
      body: ListView(
        padding: const EdgeInsets.all(NeoSpace.lg),
        children: [
          CaptionEditor(
            controller: _caption,
            font: _draft.captionFont,
            onFontChanged: (f) =>
                setState(() => _draft = _draft.copyWith(captionFont: f)),

            // (le brouillon suit)
            leading: Container(
              width: 72,
              height: 72 / _draft.aspect.ratio.clamp(0.8, 1.25),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(NeoRadius.sm),
                border: Border.all(color: context.palette.line),
              ),
              clipBehavior: Clip.antiAlias,
              child: FutureBuilder<File?>(
                future: widget.coverThumb,
                builder: (context, snap) => snap.data == null
                    ? ColoredBox(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                      )
                    : Image.file(
                        snap.data!,
                        fit: BoxFit.cover,
                        cacheWidth: 200,
                      ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: NeoSpace.xs),
            child: Row(
              children: [
                Text(
                  '$n média${n > 1 ? 's' : ''} · ${_draft.aspect.label}',
                  style: TextStyle(color: context.muted, fontSize: 12),
                ),
                // ⚠️ **On dit la requalification avant de publier.** L'app
                // décide toute seule qu'une vidéo seule est un Flow ; une
                // décision prise à la place de quelqu'un s'annonce, sinon
                // il découvre après coup un contenu qu'il n'a pas choisi.
                if (_draft.videoSeule) ...[
                  const SizedBox(width: NeoSpace.sm),
                  const FlowBadge(fontSize: 10),
                ],
              ],
            ),
          ),
          const SizedBox(height: NeoSpace.xl),
          Text('Qui peut voir', style: Theme.of(context).textTheme.titleSmall),
          RadioGroup<bool>(
            groupValue: _draft.isPublic,
            onChanged: (v) =>
                setState(() => _draft = _draft.copyWith(isPublic: v ?? false)),
            child: Column(
              children: [
                RadioListTile<bool>(
                  value: false,
                  title: const Text("Selon mes règles d'accès"),
                  subtitle: Text(
                    "Mes amis, ou la liste que j'ai choisie dans les réglages",
                    style: TextStyle(color: context.muted),
                  ),
                ),
                RadioListTile<bool>(
                  value: true,
                  title: const Text('Publique'),
                  subtitle: Text(
                    'Toute personne qui accède à mon profil — et le feed, '
                    'plus tard',
                    style: TextStyle(color: context.muted),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: NeoSpace.md),
          SwitchListTile(
            value: _draft.shareable,
            title: const Text('Partageable'),
            subtitle: Text(
              'Les autres peuvent la repartager dans leurs conversations',
              style: TextStyle(color: context.muted),
            ),
            onChanged: (v) =>
                setState(() => _draft = _draft.copyWith(shareable: v)),
          ),
          SwitchListTile(
            value: _draft.saveable,
            title: const Text('Sauvegardable'),
            subtitle: Text(
              'Les autres peuvent l\'enregistrer sur leur appareil',
              style: TextStyle(color: context.muted),
            ),
            onChanged: (v) =>
                setState(() => _draft = _draft.copyWith(saveable: v)),
          ),
          const SizedBox(height: NeoSpace.xl),
          FilledButton.icon(
            onPressed: _publish,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              shape: const StadiumBorder(),
            ),
            icon: const Icon(Icons.upload_outlined),
            label: const Text('Publier'),
          ),
          const SizedBox(height: NeoSpace.sm),
          Text(
            'La publication part en arrière-plan : tu peux continuer à '
            'utiliser l\'app, le profil dira quand c\'est fait.',
            textAlign: TextAlign.center,
            style: TextStyle(color: context.muted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
