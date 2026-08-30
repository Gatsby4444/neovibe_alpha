import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/motion.dart';

import '../../../core/content/saved_store.dart';
import '../../../core/prefs.dart';
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

// ⚠️ **`ShareableSwitch` a été SUPPRIMÉ le 2026-08-31**, avec les quatre écrans
// de paramétrage. Le nouvel écran de partage règle « Partageable » par une puce
// compacte, posée sur la ligne de la destination — demande de Jay :
// *« des boutons et containers à taille réduite pour bien proposer toutes les
// options »*. Un `SwitchListTile` par option y ferait doubler la hauteur de
// chaque ligne.
//
// ⚠️ **`ScrubbableSwitch` reste**, lui : il est appelé par `ViewingRulesSheet`.
// Vérifié à l'inventaire avant de couper — j'ai failli l'emporter avec.

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
          // `displayColor` et non `color` : sur l'habillage clair de l'app, le
          // jaune de la standard devient illisible. La règle existait et n'était
          // appliquée nulle part (inventaire des orphelines, 2026-08-17).
          border: type.gradient == null
              ? Border.all(color: type.displayColor(context))
              : null,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          type.tag,
          style: TextStyle(
            color: type.gradient == null
                ? type.displayColor(context)
                : Colors.white,
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

// ---------------------------------------------------------------------------
// Les règles de visionnage
// ---------------------------------------------------------------------------
//
// ⚠️ **Déplacées ici depuis `circle_settings_screen.dart` le 2026-08-31**, avec
// le nouvel écran de partage. Elles obéissent aux mêmes règles partout où l'on
// envoie à des PERSONNES — ce qui est exactement le critère d'entrée de ce
// fichier. Les recopier dans l'écran de partage aurait fait deux définitions
// d'« une ouverture », qui auraient fini par diverger.
//
// ⚠️ **Elles ne concernent QUE les personnes.** Une story ou une publication
// n'a ni compteur d'ouvertures ni durée par face : c'est écrit dans la feuille
// elle-même, et c'est pour ça qu'elle ne s'affiche que lorsqu'au moins une
// personne est cochée.

/// Le rappel des règles en vigueur, cliquable.
///
/// Il existe parce que les régler est passé derrière un bouton : sans lui,
/// « 2 ouvertures » deviendrait une règle qui s'applique sans jamais s'annoncer
/// — exactement ce que la refonte cherchait à éviter en les sortant du chemin.
class ViewingRulesSummary extends StatelessWidget {
  const ViewingRulesSummary({
    super.key,
    required this.maxViews,
    required this.viewDuration,
    required this.onTap,
  });

  final int? maxViews;
  final int? viewDuration;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final views = maxViews == null
        ? 'ouvertures illimitées'
        : '$maxViews ouverture${maxViews! > 1 ? 's' : ''}';
    final duration = viewDuration == null
        ? 'lecture illimitée'
        : '$viewDuration s par face';
    return ListTile(
      dense: true,
      leading: const Icon(Icons.tune, size: 18),
      title: Text('$views · $duration'),
      subtitle: Text(
        'Retourner la Vibe ne consomme rien',
        style: TextStyle(color: context.muted),
      ),
      trailing: const Icon(Icons.chevron_right, size: 18),
      onTap: onTap,
    );
  }
}

/// Les règles de visionnage, derrière le bouton « réglages » de l'AppBar.
class ViewingRulesSheet extends StatefulWidget {
  const ViewingRulesSheet({
    super.key,
    required this.draft,
    required this.maxViews,
    required this.viewDuration,
    required this.scrubbable,
    required this.onChanged,
  });

  final VibeDraft draft;
  final int? maxViews;
  final int? viewDuration;
  final bool scrubbable;
  final void Function(int? maxViews, int? viewDuration, bool scrubbable)
  onChanged;

  @override
  State<ViewingRulesSheet> createState() => ViewingRulesSheetState();
}

class ViewingRulesSheetState extends State<ViewingRulesSheet> {
  /// 1-5 ouvertures ; **6 = illimité**. Le curseur porte le cran « illimité »
  /// au lieu d'un interrupteur à côté : c'est le même réglage, il n'a pas à se
  /// faire en deux gestes à deux endroits.
  late int _views = widget.maxViews ?? 6;

  /// 1-20 s ; **21 = illimitée**.
  late int _duration = widget.viewDuration ?? 21;

  late bool _scrubbable = widget.scrubbable;

  void _push() => widget.onChanged(
    _views == 6 ? null : _views,
    _duration == 21 ? null : _duration,
    _scrubbable,
  );

  @override
  Widget build(BuildContext context) {
    final draft = widget.draft;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Règles de visionnage',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Elles ne s\'appliquent qu\'ici : une story ou une publication '
              'n\'en a pas.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: context.muted),
            ),
            const SizedBox(height: 14),

            Text(
              _views == 6 ? 'Ouvertures : illimitées' : 'Ouvertures : $_views',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            Text(
              'Une ouverture, pas un affichage : la Vibe se retourne autant '
              'qu\'on veut tant qu\'elle est ouverte.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: context.muted),
            ),
            Slider(
              value: _views.toDouble(),
              min: 1,
              max: 6,
              divisions: 5,
              label: _views == 6 ? '∞' : '$_views',
              onChanged: (v) {
                setState(() => _views = v.round());
                _push();
              },
            ),

            // La durée de lecture ne concerne que les faces photo : une face
            // vidéo se lit en entier (consigne Jay 2026-07-12).
            if (draft.hasPhoto) ...[
              const SizedBox(height: 8),
              Text(
                _duration == 21
                    ? 'Durée de lecture${draft.hasVideo ? ' (face photo)' : ''} : illimitée'
                    : 'Durée de lecture${draft.hasVideo ? ' (face photo)' : ''} : $_duration s',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              Text(
                'Par face, et le compte se met en pause quand on retourne la '
                'Vibe.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: context.muted),
              ),
              Slider(
                value: _duration.toDouble(),
                min: 1,
                max: 21,
                divisions: 20,
                label: _duration == 21 ? '∞' : '$_duration s',
                onChanged: (v) {
                  setState(() => _duration = v.round());
                  _push();
                },
              ),
            ],

            if (draft.hasVideo) ...[
              const SizedBox(height: 4),
              ScrubbableSwitch(
                value: _scrubbable,
                onChanged: (v) {
                  setState(() => _scrubbable = v);
                  _push();
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Popup de première utilisation : comment vivent les Vibes (consigne Jay).
///
/// ⚠️ **Déplacée ici le 2026-08-31**, avec la disparition de l'écran de choix
/// de format. Elle vivait dans ce fichier-là : l'y laisser l'aurait fait
/// disparaître avec lui, et le premier écran d'envoi n'aurait plus rien
/// expliqué — sans qu'aucune erreur ne le signale.
///
/// Appelée depuis **tout premier écran d'envoi atteint** : le partage, et le
/// paramétrage du cercle quand on y entre directement depuis un chat.
Future<void> maybeShowVibesExplainer(
  BuildContext context,
  WidgetRef ref,
) async {
  if (ref.read(cardsExplainerShownProvider)) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Comment vivent tes Vibes'),
      content: const SingleChildScrollView(
        child: Text(
          'Dans les chats, une Vibe s\'ouvre un nombre limité de fois '
          '(2 par défaut). Une ouverture, c\'est une ouverture : tant que la '
          'Vibe est ouverte, tu peux la retourner autant que tu veux sans rien '
          'consommer.\n\n'
          'Le temps de lecture est illimité par défaut ; tu peux le limiter '
          'par Vibe. Tes défauts se règlent dans Réglages > Vibes.\n\n'
          'Chaque Vibe apparaît dans le chat comme un container : on clique '
          'pour l\'ouvrir, jamais d\'aperçu. Le container reste 24 h et le '
          'destinataire peut te demander un replay : rien ne se revoit sans '
          'ton accord.\n\n'
          'Si tu l\'envoies à UNE seule personne sans la publier, elle devient '
          'une One of One : exclusive, pour elle seule, à jamais.\n\n'
          'Dans ta bibliothèque, ce que tu publies se regarde sans limite.',
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Compris'),
        ),
      ],
    ),
  );
  await ref.read(cardsExplainerShownProvider.notifier).markShown();
}
