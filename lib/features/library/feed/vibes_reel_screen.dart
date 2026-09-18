import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/content/content_face.dart';
import '../../../core/content/content_view_reporter.dart';
import '../../../core/content/likes.dart';
import '../../../core/models/library_item.dart';
import '../../../core/supabase_providers.dart';
import '../../../core/widgets/like_burst.dart';
import '../../../core/widgets/pinch_to_close.dart';
import '../../../core/widgets/system_bars.dart';
import '../../../core/widgets/vibe_face.dart';
import '../../cards/flippable_card.dart' show FlipControl;
import '../../connections/connections_repository.dart';
import 'publication_actions.dart';
import 'reel_common.dart';
import 'vibe_card_chrome.dart';
import 'vibe_card_view.dart';

/// **Les Vibes en plein écran, à la suite** — façon Reels : une Vibe par
/// écran, fond noir, on glisse vers le haut pour la suivante.
///
/// ⚠️ **Ici, la carte se retourne par les CÔTÉS** — un tap sur son bord
/// gauche ou droit — et n'écoute aucun glissement (Jay, 2026-09-18 : *« pour
/// swiper une card cela devient trop complexe en mode plein écran de tenter
/// de bricoler pour avoir les deux gestes mouvement et scroll en même
/// temps »*). Le défilement est donc seul à tenir le doigt. Le geste libre
/// (retourner, incliner) reste celui des autres visionneuses — une Vibe
/// reçue, la bibliothèque partagée — voir [FlipControl].
/// **La carte est seule à l'écran, centrée, et porte tout le reste**
/// (`VibeCardChrome`) : l'identité en haut, les actions en colonne à droite,
/// la légende en bas. Elles sont *dans* la carte, sur ses deux faces — donc
/// elles bougent avec elle et ne lui prennent aucune place.
///
/// ⚠️ **Deux essais avant celui-là, et ce qu'ils apprennent.** Les actions ont
/// d'abord flotté par-dessus la carte (cœur au milieu de l'image) ; puis on
/// leur a réservé une gouttière à côté — et la carte, poussée vers la gauche,
/// n'était plus centrée (*« ce n'est pas joli »*, Jay, 2026-09-16). Tant que
/// la commande est à CÔTÉ du contenu, elle le déplace. Dedans, elle ne coûte
/// rien.
///
/// Seule la croix reste par-dessus, fixe : fermer est une commande de
/// l'écran, pas du contenu — elle doit rester au même endroit même quand la
/// carte tourne.
///
/// Fermer : la croix, ou **tirer vers le bas depuis la première Vibe** —
/// le même geste que les autres visionneurs (Jay, 2026-09-14), lu ici dans
/// le sur-défilement que la liste rapporte, puisque c'est elle qui tient le
/// doigt (voir [_OverscrollToClose]).
///
/// Même écran demain pour le feed des Vibes : seule la liste change.
class VibesReelScreen extends ConsumerStatefulWidget {
  const VibesReelScreen({
    super.key,
    required this.vibes,
    required this.initialIndex,
  });

  final List<LibraryItem> vibes;
  final int initialIndex;

  @override
  ConsumerState<VibesReelScreen> createState() => _VibesReelScreenState();
}

class _VibesReelScreenState extends ConsumerState<VibesReelScreen> {
  late List<LibraryItem> _vibes = List.of(widget.vibes);
  late final PageController _pages = PageController(
    initialPage: widget.initialIndex,
  );
  late int _current = widget.initialIndex;

  /// ⚠️ Capturé à l'initialisation : `ref` est interdit dans `dispose()`.
  late final ContentViewReporter _reporter;

  @override
  void initState() {
    super.initState();
    _reporter = ref.read(contentViewReporterProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(likesStoreProvider.notifier).load(_vibes.map((v) => v.id));
      // La vue ne part qu'après 3 s d'affichage réel (Jay, 2026-08-13).
      _reporter.watching(_vibes[_current].id);
    });
  }

  @override
  void dispose() {
    if (_current < _vibes.length) _reporter.stopped(_vibes[_current].id);
    _pages.dispose();
    super.dispose();
  }

  void _onPage(int i) {
    if (_current < _vibes.length) _reporter.stopped(_vibes[_current].id);
    setState(() => _current = i);
    _reporter.watching(_vibes[i].id);
  }

  void _removed(LibraryItem item) {
    _reporter.stopped(item.id);
    final rest = _vibes.where((v) => v.id != item.id).toList();
    if (rest.isEmpty) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {
      _vibes = rest;
      _current = _current.clamp(0, rest.length - 1);
    });
    // La liste a rétréci sous le doigt : si on était sur la dernière, la
    // page courante du contrôleur n'existe plus. On le recale sur ce qu'on
    // affiche vraiment, sinon il pointe hors de la liste.
    if (_pages.hasClients && _pages.page?.round() != _current) {
      _pages.jumpToPage(_current);
    }
    _reporter.watching(_vibes[_current].id);
  }

  @override
  Widget build(BuildContext context) {
    return DarkSystemBars(
      // Écran noir sans AppBar : il annonce lui-même des icônes
      // système claires (voir [DarkSystemBars]).
      // Transparent : la route est une superposition (voir [ReelRoute]), le
      // noir est DANS ce qui se rétracte — autour de l'heptagone, le profil.
      child: Scaffold(
        backgroundColor: Colors.transparent,
        // Dézoomer à deux doigts ferme, et l'écran suit le geste
        // (Jay, 2026-09-17). Posé ICI, autour de tout : c'est l'écran qui se
        // rétracte, pas la carte.
        body: PinchToClose(
          onClose: () => Navigator.of(context).maybePop(),
          child: OverscrollToClose(
            atFirstPage: _current == 0,
            onClose: () => Navigator.of(context).maybePop(),
            child: Stack(
              children: [
                const Positioned.fill(child: ColoredBox(color: Colors.black)),
                // Sans la lueur de bord : le sur-défilement du haut est un
                // geste (fermer), pas une butée à signaler.
                ScrollConfiguration(
                  behavior: ScrollConfiguration.of(
                    context,
                  ).copyWith(overscroll: false),
                  // ⚠️ **Pas de seuil élargi ici.** On a essayé (v0.9.194) :
                  // la carte gagnait alors trop souvent — Jay a tranché,
                  // *« le nouveau système est pire »*. Ce qui départage n'est
                  // pas la distance mais le **temps de pose**
                  // (`HeldPanGestureRecognizer`), et il vit dans la carte,
                  // donc partout à la fois.
                  child: Builder(
                    builder: (context) => PageView.builder(
                      controller: _pages,
                      scrollDirection: Axis.vertical,
                      onPageChanged: _onPage,
                      itemCount: _vibes.length,
                      itemBuilder: (context, i) => _ReelPage(
                        key: ValueKey(_vibes[i].id),
                        item: _vibes[i],
                        active: i == _current,
                        onDeleted: () => _removed(_vibes[i]),
                      ),
                    ),
                  ),
                ),
                // En haut à DROITE : le haut-gauche de la carte porte
                // désormais la photo et le pseudo.
                Positioned(
                  top: 0,
                  right: 0,
                  child: SafeArea(
                    child: IconButton(
                      icon: const Icon(Icons.close),
                      color: Colors.white,
                      tooltip: 'Fermer',
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Une Vibe et ce qui flotte dessus. Les faces sont ouvertes ici aussi
/// (même provider que [VibeCardView], donc même cache) pour « Enregistrer ».
class _ReelPage extends ConsumerWidget {
  const _ReelPage({
    super.key,
    required this.item,
    required this.active,
    required this.onDeleted,
  });

  final LibraryItem item;
  final bool active;
  final VoidCallback onDeleted;

  ContentFace _spec(bool front) => (
    contentId: item.id,
    ownerId: item.ownerId,
    bucket: 'library',
    path: front ? item.frontPath : item.backPath!,
    slot: front ? ContentSlot.front : ContentSlot.back,
    isVideo: front ? item.frontIsVideo : item.backIsVideo,
    encrypted: item.encrypted,
    batchOwner: item.ownerId,
    expiresAt: null,
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mine = item.ownerId == ref.watch(currentUserIdProvider);
    final owner = ref.watch(profileByIdProvider(item.ownerId)).value;
    final front = ref.watch(contentFaceProvider(_spec(true))).value;
    final back = item.hasBack
        ? ref.watch(contentFaceProvider(_spec(false))).value
        : null;

    return SafeArea(
      child: Center(
        // Double tap = j'aime, avec le cœur qui jaillit — à la place de
        // l'appui long (Jay, 2026-09-18 : *« rajoute le double tap pour liker
        // sur les cards, remplace l'appui long par cela, puisqu'on n'a plus
        // le mode mouvement »*). ⚠️ Le prix, assumé et dit à Jay : un tap sur
        // un bord attend ~300 ms (le temps d'un éventuel second tap) avant
        // de retourner la carte.
        child: LikeBurst(
          contentId: item.id,
          doubleTap: true,
          longPress: false,
          child: VibeCardView(
            item: item,
            active: active,
            // Au plus près des bords : la marge du cadre est tout ce qui
            // sépare deux Vibes quand on passe de l'une à l'autre.
            display: VibeDisplay.full,
            control: FlipControl.sides,
            // Tout est DANS la carte : elle reste centrée et prend l'écran.
            overlay: VibeCardChrome(
              header: ReelIdentity(item: item, owner: owner, mine: mine),
              actions: PublicationActions(
                item: item,
                mine: mine,
                saveId: item.id,
                saveFront: front,
                saveBack: back,
                saveFrontIsVideo: item.frontIsVideo,
                saveBackIsVideo: item.backIsVideo,
                vertical: true,
                color: Colors.white,
                onDeleted: onDeleted,
              ),
              // Pas de légende sur une Vibe : le texte y viendra par son
              // propre éditeur, écrit SUR l'image (Jay, 2026-09-17).
              caption: null,
            ),
          ),
        ),
      ),
    );
  }
}
