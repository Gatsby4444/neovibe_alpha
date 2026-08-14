import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/motion.dart';

import '../../../core/content/saved_store.dart';
import '../../../core/models/card.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/avatar.dart';
import '../../../core/widgets/rive_send_button.dart';
import '../../../core/widgets/top_banner.dart';
import '../../connections/connections_repository.dart';
import 'vibe_draft.dart';

/// Pièces communes aux quatre écrans de paramétrage.
///
/// ⚠️ **Ce qui est ici est ce qui obéit aux MÊMES règles partout.** Tout ce
/// qui dépend de la destination reste dans l'écran de cette destination —
/// c'est la raison d'être du découpage. Un réglage qui « existe presque
/// pareil » dans deux contextes n'a rien à faire dans ce fichier : il finirait
/// paramétré par des booléens jusqu'à redevenir l'écran unique qu'on vient de
/// démonter.

/// Le bouton « Enregistrer pour moi ».
///
/// Refonte du 2026-08-14, demande de Jay : ce n'était **pas** une case à
/// cocher qui promettait une copie à l'envoi, c'est un bouton qui la fait
/// **maintenant**, avec un bandeau qui dit ce qui vient de se passer.
///
/// Ce que le changement corrige au passage : la case cochée n'agissait qu'après
/// un envoi réussi. Abandonner l'écran, ou échouer à l'envoi, faisait perdre la
/// prise **sans que rien ne le dise** — la case était cochée, donc l'utilisateur
/// croyait sa copie faite. Un bouton qui agit tout de suite n'a pas cet écart
/// entre ce qui est promis et ce qui est fait.
class SaveForMeButton extends ConsumerStatefulWidget {
  const SaveForMeButton({super.key, required this.draft});

  final VibeDraft draft;

  @override
  ConsumerState<SaveForMeButton> createState() => _SaveForMeButtonState();
}

class _SaveForMeButtonState extends ConsumerState<SaveForMeButton> {
  var _saved = false;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    // L'état vient du magasin, pas de la mémoire de l'écran : revenir en
    // arrière puis rouvrir ce paramétrage ne doit pas faire oublier une copie
    // déjà faite.
    ref
        .read(savedStoreProvider)
        .isSaved(widget.draft.localId)
        .then((saved) {
          if (mounted && saved) setState(() => _saved = true);
        })
        .catchError((_) {});
  }

  Future<void> _save() async {
    if (_busy) return;
    final draft = widget.draft;
    final store = ref.read(savedStoreProvider);
    if (await store.isSaved(draft.localId)) {
      if (!mounted) return;
      setState(() => _saved = true);
      TopBanner.show(
        context,
        'Vibe déjà sauvegardée',
        tone: TopBannerTone.already,
      );
      return;
    }
    setState(() => _busy = true);
    try {
      // Les fichiers capturés sont encore en clair sous la main : la copie est
      // une simple recopie, sans déchiffrement ni réseau.
      await store.add(
        contentId: draft.localId,
        cardType: draft.type,
        writeFront: (t) => draft.front.copy(t.path),
        writeBack: draft.back == null ? null : (t) => draft.back!.copy(t.path),
        frontIsVideo: draft.frontIsVideo,
        backIsVideo: draft.backIsVideo,
        mine: true,
      );
      ref.invalidate(savedItemsProvider);
      if (!mounted) return;
      setState(() {
        _saved = true;
        _busy = false;
      });
      TopBanner.show(context, 'Vibe sauvegardée');
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      TopBanner.show(
        context,
        'Sauvegarde impossible : $e',
        tone: TopBannerTone.already,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: OutlinedButton.icon(
        onPressed: _busy ? null : _save,
        icon: _busy
            ? const SizedBox(
                height: 16,
                width: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                _saved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
              ),
        label: Text(_saved ? 'Sauvegardée' : 'Enregistrer pour moi'),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(46),
          foregroundColor: _saved
              ? Theme.of(context).colorScheme.primary
              : null,
        ),
      ),
    );
  }
}

/// « Les destinataires pourront la garder. »
///
/// Une One of One n'est jamais enregistrable par son destinataire :
/// l'exclusivité EST le format. L'interrupteur reste visible mais inerte, pour
/// que la règle se lise au lieu de disparaître sans explication.
class SaveableSwitch extends StatelessWidget {
  const SaveableSwitch({
    super.key,
    required this.type,
    required this.value,
    required this.onChanged,
  });

  final CardType type;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      title: const Text('Sauvegardable'),
      subtitle: Text(
        type.canBeSaveable
            ? 'Les destinataires pourront la garder dans leurs Enregistrements'
            : 'Impossible sur une One of One — elle n\'existe que pour son '
                  'destinataire, le temps de sa vue',
      ),
      value: value && type.canBeSaveable,
      onChanged: type.canBeSaveable ? onChanged : null,
    );
  }
}

/// Partage hors cercle — story ET publication, même mécanique serveur
/// (`share_content`) : le contenu voyage d'ami en ami, sans limite de sauts, et
/// chaque saut est une personne qui décide.
class ShareableSwitch extends StatelessWidget {
  const ShareableSwitch({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      title: const Text('Partageable'),
      subtitle: Text(
        value
            ? 'Ceux qui la voient pourront la relayer à leurs amis, qui '
                  'pourront la relayer à leur tour — elle peut sortir de ton '
                  'cercle.'
            : 'Elle reste dans ton cercle : personne ne peut la relayer '
                  'ailleurs.',
      ),
      value: value,
      onChanged: onChanged,
    );
  }
}

/// Barre de lecture des vidéos (défaut : intouchable — consigne Jay).
class ScrubbableSwitch extends StatelessWidget {
  const ScrubbableSwitch({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      title: const Text('Barre de lecture contrôlable'),
      subtitle: const Text(
        'Désactivé : le destinataire voit la progression mais ne peut pas se '
        'déplacer dans la vidéo',
      ),
      value: value,
      onChanged: onChanged,
    );
  }
}

/// La barre d'envoi, en bas de chaque écran de paramétrage.
///
/// 🎨 **Le bouton Rive de Jay** (`assets/rive/watch_reel_button.riv`) est monté
/// ici, et **ici seulement** : le bouton d'envoi est le même geste dans les
/// quatre destinations, il n'a aucune raison d'exister en quatre exemplaires.
/// Seul le libellé change — et il change par la propriété `label` du ViewModel,
/// pas par quatre fichiers.
///
/// Le repli est un vrai `FilledButton`, pas un espace vide : si le moteur natif
/// ou l'asset manquent, l'app reste utilisable.
class SendActionBar extends StatelessWidget {
  const SendActionBar({
    super.key,
    required this.label,
    required this.loading,
    required this.onPressed,
  });

  final String label;
  final bool loading;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final effective = loading ? null : onPressed;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        // L'envoi en cours n'est plus annoncé par-dessus le bouton : **le
        // bouton EST le loader**. Il reste dans son état pressé — celui où il
        // devient rond — le temps de la publication (demande de Jay,
        // 2026-08-14). Un rond de progression posé dessus doublait le message
        // et cachait l'animation.
        child: RiveSendButton(
          // Le graphique est dessiné en capitales : on lui donne ce qu'il
          // attend plutôt que de recadrer le texte après coup.
          label: label.toUpperCase(),
          onPressed: effective,
          busy: loading,
          fallback: FilledButton(
            onPressed: effective,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
            child: loading
                ? const SizedBox(
                    height: 22,
                    width: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(label),
          ),
        ),
      ),
    );
  }
}

/// Le 413 du Storage (« exceeded the maximum allowed size ») est illisible pour
/// un utilisateur : on dit ce qui s'est passé et quoi faire.
String friendlySendError(Object e) {
  final text = e.toString();
  if (text.contains('413') || text.contains('maximum allowed size')) {
    return 'Média trop lourd pour l\'envoi (limite serveur). Refais une vidéo '
        'plus courte.';
  }
  return 'Erreur : $text';
}

/// Bandeau du basculement automatique en One of One (2026-08-10).
///
/// L'utilisateur n'a rien choisi : c'est la forme de son envoi qui a décidé.
/// Le bandeau dit donc la conséquence ET la manière d'en sortir.
class OneOfOneBanner extends StatelessWidget {
  const OneOfOneBanner({super.key});

  static const gold = Color(0xFFD4AF37);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 2),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: gold.withValues(alpha: 0.10),
        border: Border.all(color: gold.withValues(alpha: 0.55)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.workspace_premium, color: gold, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'One of One',
                  style: TextStyle(
                    color: gold,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Un seul destinataire et aucune publication : cette Vibe '
                  'devient exclusive, pour elle seule et à jamais. Ajoute '
                  'quelqu\'un pour revenir à une Vibe normale.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// La pastille de type, dans l'AppBar des écrans de paramétrage.
class VibeTypeChip extends StatelessWidget {
  const VibeTypeChip({super.key, required this.type});

  final CardType type;

  @override
  Widget build(BuildContext context) {
    // Elle se met à jour en direct : c'est elle qui annonce le basculement
    // automatique en One of One.
    return AnimatedSwitcher(
      duration: NeoMotion.normal,
      child: Container(
        key: ValueKey(type),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          gradient: type.gradient,
          border: type.gradient == null ? Border.all(color: type.color) : null,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          type.tag,
          style: TextStyle(
            color: type.gradient == null ? type.color : Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

class RecipientTile extends ConsumerWidget {
  const RecipientTile({
    super.key,
    required this.peerId,
    required this.selected,
    required this.onChanged,
  });

  final String peerId;
  final bool selected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileByIdProvider(peerId)).value;
    return CheckboxListTile(
      value: selected,
      onChanged: (v) => onChanged(v ?? false),
      title: Text(profile?.displayName ?? '…'),
      secondary: Avatar(
        stored: profile?.avatarUrl,
        fallback: Text(
          (profile?.displayName ?? '?').characters.first.toUpperCase(),
        ),
      ),
    );
  }
}

/// Message d'absence, mis en forme comme partout ailleurs dans l'app.
class SendEmptyNote extends StatelessWidget {
  const SendEmptyNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(color: context.muted),
      ),
    ),
  );
}
