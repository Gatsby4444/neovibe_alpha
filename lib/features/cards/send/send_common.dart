import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/motion.dart';

import '../../../core/content/saved_store.dart';
import '../../../core/prefs.dart';
import '../../../core/models/card.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/top_banner.dart';
import 'vibe_draft.dart';

/// Pièces communes aux quatre écrans de paramétrage.
///
/// ⚠️ **Ce qui est ici est ce qui obéit aux MÊMES règles partout.** Tout ce
/// qui dépend de la destination reste dans l'écran de cette destination —
/// c'est la raison d'être du découpage. Un réglage qui « existe presque
/// pareil » dans deux contextes n'a rien à faire dans ce fichier : il finirait
/// paramétré par des booléens jusqu'à redevenir l'écran unique qu'on vient de
/// démonter.

/// **Le Drop** — nom public de la bibliothèque de conversation (Jay,
/// 2026-09-14).
///
/// Ce que c'est : les Vibes qu'on y met restent **cachées pour tout le monde,
/// l'auteur compris, jusqu'à 18h30**, puis se révèlent d'un coup pour tous les
/// membres (`docs/bibliotheques-ephemeres.md`). « Bibliothèque » se confondait
/// avec la Bibliothèque de profil (permanente, publique) et ne disait rien du
/// mécanisme. Le code et la base gardent `library` — renommage public
/// seulement, comme « Card » → « Vibe ».
///
/// Sa couleur : **ambre**, distincte du rose du chat, pour qu'on voie au
/// premier coup d'œil vers où part une Vibe. Pas le doré : c'est celui du
/// One of One.
const dropAccent = Color(0xFFF59E0B);

/// L'icône du Drop : la même que l'annonce « a ajouté une vibe — 18h30 » du
/// fil de chat, pour que l'objet ait un seul visage dans toute l'app.
const dropIcon = Icons.lock_clock_outlined;

/// Le bouton « Enregistrer pour moi » — un **signet dans la barre de titre**
/// depuis le 2026-09-14.
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
    // Un signet dans la barre de titre, pas un bouton en bas de liste
    // (Jay, 2026-09-14 : « tout en bas, difficilement accessible »). Toujours
    // à la même place quel que soit le défilement, et le signet plein dit
    // « déjà fait » sans un mot.
    final primary = Theme.of(context).colorScheme.primary;
    return IconButton(
      onPressed: _busy ? null : _save,
      tooltip: _saved ? 'Sauvegardée' : 'Enregistrer pour moi',
      icon: _busy
          ? const SizedBox(
              height: 18,
              width: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              _saved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
              color: _saved ? primary : null,
            ),
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

// ⚠️ **`OneOfOneBanner` a été SUPPRIMÉ le 2026-09-14** (demande de Jay,
// captures du partage refondu) : inséré en tête de liste, l'encadré doré
// **décalait toute l'interface** au moment où le nombre de destinataires
// tombait à un — et remontait quand il repassait à deux. La pastille du titre
// (`VibeTypeChip`, ci-dessous) annonce déjà le basculement, sans bouger la
// page ; c'est elle seule qui reste. Un seul appelant relevé
// (`RecipientPickerScreen`), zéro dépendant de sa constante `gold`.

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

/// **Les règles de visionnage, à éditer en place** — ouvertures, durée par
/// face photo, barre de lecture des vidéos.
///
/// Un seul propriétaire : le sur-écran ⚙︎ « Groupes et amis » de l'écran de
/// partage. Ces règles ne s'appliquent qu'aux personnes : une story ou une
/// publication n'en a pas (2026-09-14).
class ViewingRulesEditor extends StatefulWidget {
  const ViewingRulesEditor({
    super.key,
    required this.acceptsDuration,
    required this.hasVideo,
    required this.maxViews,
    required this.viewDuration,
    required this.scrubbable,
    required this.onChanged,
  });

  /// Posées par l'appelant, d'après la prise (envoi) ou la Vibe (Modifier,
  /// 2026-09-25) — la règle elle-même est [acceptsViewDuration].
  final bool acceptsDuration;
  final bool hasVideo;
  final int? maxViews;
  final int? viewDuration;
  final bool scrubbable;
  final void Function(int? maxViews, int? viewDuration, bool scrubbable)
  onChanged;

  @override
  State<ViewingRulesEditor> createState() => _ViewingRulesEditorState();
}

class _ViewingRulesEditorState extends State<ViewingRulesEditor> {
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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

        // La durée de lecture ne concerne que les faces photo d'une Vibe
        // standard : une face vidéo se lit en entier (2026-07-12), un Oneshot
        // n'a pas de chrono (2026-09-14). Voir [VibeDraft.acceptsDuration].
        if (widget.acceptsDuration) ...[
          const SizedBox(height: 8),
          Text(
            _duration == 21
                ? 'Durée de lecture${widget.hasVideo ? ' (face photo)' : ''} : illimitée'
                : 'Durée de lecture${widget.hasVideo ? ' (face photo)' : ''} : $_duration s',
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

        if (widget.hasVideo) ...[
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
