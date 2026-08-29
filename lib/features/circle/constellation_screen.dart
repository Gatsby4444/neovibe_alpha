import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/profile.dart';
import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import '../../core/typography.dart';
import '../connections/connections_repository.dart';
import '../connections/friendship.dart';
import '../connections/friendships_repository.dart';
import '../connections/tier_avatar.dart';
import '../library/user_library_screen.dart';

/// **La constellation** : tous tes amis en nid d'abeille, à la manière de
/// l'écran d'accueil d'une Apple Watch.
///
/// ## Pourquoi c'est un écran POUSSÉ, et pas un onglet
///
/// Cette grille se déplace au doigt. L'accueil de NeoVibe, lui, change de
/// section au glissement horizontal. Les deux gestes sont **le même geste** :
/// dans un onglet, ils se disputeraient, et c'est celui qui gagne l'arène des
/// gestes qui déciderait — pas nous.
///
/// ✅ **Vérifié dans le code le 2026-08-29** : le détecteur de glissement de
/// `HomeShell` entoure le CONTENU de l'accueil, et une route poussée n'en est
/// pas l'enfant — c'est une surface sœur. **Le conflit n'existe donc pas**,
/// structurellement, et non parce qu'on aurait trouvé un réglage.
///
/// Solution proposée par Jay le 2026-08-29, adoptée telle quelle.
///
/// ## ⚠️ La sortie est une CROIX — et le glissement diagonal ne peut PAS
/// exister ici
///
/// Jay proposait un glissement diagonal pour fermer, avec une animation de
/// brisure. **Il n'est pas là, et ce n'est pas un oubli** : le conflit de
/// gestes qu'on venait d'éviter en poussant cet écran se reforme à
/// l'intérieur. Une grille qu'on traîne au doigt prend TOUS les glissements,
/// diagonale comprise — c'est sa raison d'être. Ajouter un second lecteur du
/// même geste, c'est laisser l'arène des gestes décider à notre place, et
/// obtenir tantôt une fermeture, tantôt un déplacement.
///
/// Le geste redeviendrait possible sur une grille **fixe** (sans déplacement
/// au doigt), ou en le déplaçant sur un bord de l'écran. Les deux sont des
/// décisions de Jay, pas des détails d'implémentation.
///
/// La croix reste de toute façon obligatoire : un geste diagonal ne se devine
/// pas, et il n'existe aucun retour arrière visible dans une grille qui se
/// déplace dans tous les sens. Un écran dont on ne sait pas sortir est un bug.
class ConstellationScreen extends ConsumerStatefulWidget {
  const ConstellationScreen({super.key});

  @override
  ConsumerState<ConstellationScreen> createState() =>
      _ConstellationScreenState();
}

class _ConstellationScreenState extends ConsumerState<ConstellationScreen> {
  final _transformation = TransformationController();
  var _filtre = FiltreDePalier.tous;

  /// Le diamètre d'une pastille au centre de l'écran.
  static const _diametre = 78.0;

  /// L'écart entre deux centres. Plus grand que le diamètre : la place du
  /// pseudo se prend ici, pas en rognant les photos.
  static const _pas = 104.0;

  /// Ce qu'il reste d'une pastille au bord du champ de vision.
  ///
  /// ⚠️ **Elle rétrécit pour de vrai, elle n'est pas mise à l'échelle.** Un
  /// widget rapetissé par `Transform.scale` garde la boîte de clic de sa taille
  /// d'origine : on aurait deux boîtes, la visible et la cliquable, et un appui
  /// à côté d'une petite pastille aurait ouvert le profil d'un voisin. Ici la
  /// TAILLE est calculée, donc les deux boîtes n'en font qu'une.
  static const _minimum = 0.44;

  @override
  void dispose() {
    _transformation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(currentUserIdProvider);
    final connections = ref.watch(fullConnectionsProvider);
    final amities = ref.watch(friendshipsProvider).value ?? const {};

    final ids = me == null
        ? const <String>[]
        : [
            for (final c in connections)
              if (_filtre.retient(
                amities[c.peerIdFor(me)]?.tier ?? FriendshipTier.friend,
              ))
                c.peerIdFor(me),
          ];

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: ids.isEmpty
                  ? _Vide(filtre: _filtre)
                  : _Ruche(
                      ids: ids,
                      controller: _transformation,
                      diametre: _diametre,
                      pas: _pas,
                      minimum: _minimum,
                    ),
            ),
            _Chapeau(
              filtre: _filtre,
              nombre: ids.length,
              onFiltre: (f) => setState(() => _filtre = f),
            ),
          ],
        ),
      ),
    );
  }
}

/// Le bandeau du haut : le titre, la croix de sortie, et les filtres.
class _Chapeau extends StatelessWidget {
  const _Chapeau({
    required this.filtre,
    required this.nombre,
    required this.onFiltre,
  });

  final FiltreDePalier filtre;
  final int nombre;
  final ValueChanged<FiltreDePalier> onFiltre;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: DecoratedBox(
        // Un voile, pas un aplat : la grille passe dessous quand on la
        // déplace, et on veut qu'on la devine.
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [p.ground, p.ground.withValues(alpha: 0)],
            stops: const [0.62, 1],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            NeoSpace.lg,
            NeoSpace.md,
            NeoSpace.lg,
            NeoSpace.xxl,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Constellation', style: context.sectionTitle),
                        Text(
                          nombre == 0
                              ? 'Personne ici'
                              : '$nombre ${nombre > 1 ? 'amis' : 'ami'}',
                          style: context.sectionMeta,
                        ),
                      ],
                    ),
                  ),
                  // ⚠️ La SEULE sortie — voir l'en-tête du fichier : le
                  // glissement diagonal ne peut pas cohabiter avec une grille
                  // qu'on déplace au doigt.
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Fermer',
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
              const SizedBox(height: NeoSpace.sm),
              Row(
                children: [
                  for (final f in FiltreDePalier.values)
                    Padding(
                      padding: const EdgeInsets.only(right: NeoSpace.sm),
                      child: ChoiceChip(
                        label: Text(f.label),
                        selected: filtre == f,
                        onSelected: (_) => onFiltre(f),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Vide extends StatelessWidget {
  const _Vide({required this.filtre});

  final FiltreDePalier filtre;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(NeoSpace.xxl),
      child: Text(
        filtre == FiltreDePalier.tous
            ? 'Ta constellation est vide. Tes amis arrivent par la vraie vie : '
                  'active ta visibilité quand tu sors.'
            : 'Personne à ce palier pour l\'instant. Il se gagne en se '
                  'croisant pour de vrai, jour après jour.',
        textAlign: TextAlign.center,
        style: TextStyle(color: context.muted),
      ),
    ),
  );
}

/// La ruche elle-même : les pastilles posées en nid d'abeille, dans un plan
/// qu'on déplace et qu'on pince.
class _Ruche extends StatelessWidget {
  const _Ruche({
    required this.ids,
    required this.controller,
    required this.diametre,
    required this.pas,
    required this.minimum,
  });

  final List<String> ids;
  final TransformationController controller;
  final double diametre;
  final double pas;
  final double minimum;

  @override
  Widget build(BuildContext context) {
    final places = Ruche.places(ids.length, pas);
    // La boîte qui contient tout le monde, plus une marge d'une pastille.
    final rayon =
        places.fold<double>(0, (r, o) => math.max(r, o.distance)) + pas;
    final cote = rayon * 2;

    return LayoutBuilder(
      builder: (context, box) {
        return InteractiveViewer(
          transformationController: controller,
          // `constrained: false` : le plan est plus grand que l'écran, c'est
          // tout l'intérêt. Sans ça, Flutter le rabote à la taille visible.
          constrained: false,
          minScale: 0.6,
          maxScale: 2.2,
          boundaryMargin: EdgeInsets.all(pas),
          child: SizedBox(
            width: cote,
            height: cote,
            child: AnimatedBuilder(
              animation: controller,
              builder: (context, _) {
                // Le centre du champ de vision, exprimé dans le plan.
                final m = Matrix4.inverted(controller.value);
                final centre = MatrixUtils.transformPoint(
                  m,
                  Offset(box.maxWidth / 2, box.maxHeight / 2),
                );
                // La distance à partir de laquelle une pastille est au plus
                // petit : la demi-diagonale de l'écran.
                final portee = math.max(
                  1.0,
                  math.sqrt(
                        box.maxWidth * box.maxWidth +
                            box.maxHeight * box.maxHeight,
                      ) /
                      2,
                );

                return Stack(
                  children: [
                    for (var i = 0; i < ids.length; i++)
                      _place(
                        context: context,
                        id: ids[i],
                        position: places[i] + Offset(rayon, rayon),
                        centre: centre,
                        portee: portee,
                      ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _place({
    required BuildContext context,
    required String id,
    required Offset position,
    required Offset centre,
    required double portee,
  }) {
    // Plus on s'éloigne du milieu, plus la pastille est petite. C'est le geste
    // signature de la ruche : le regard sait où il est sans aucun repère.
    final t = ((position - centre).distance / portee).clamp(0.0, 1.0);
    final facteur = 1 - (1 - minimum) * Curves.easeOut.transform(t);
    final taille = diametre * facteur;
    // La place réservée reste constante : seule la pastille rétrécit, sinon
    // le nid d'abeille se déformerait à chaque déplacement du doigt.
    return Positioned(
      left: position.dx - pas / 2,
      top: position.dy - pas / 2,
      width: pas,
      height: pas,
      child: _Pastille(id: id, taille: taille, facteur: facteur),
    );
  }
}

class _Pastille extends ConsumerWidget {
  const _Pastille({
    required this.id,
    required this.taille,
    required this.facteur,
  });

  final String id;
  final double taille;

  /// Sert au pseudo : il s'efface quand la pastille devient trop petite pour
  /// qu'il reste lisible. Un texte de 5 px n'informe pas, il salit.
  final double facteur;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Profile? peer = ref.watch(profileByIdProvider(id)).value;
    if (peer == null) return const SizedBox.shrink();

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => UserLibraryScreen(profile: peer)),
          ),
          child: TierAvatar(
            peerId: id,
            storedAvatar: peer.avatarUrl,
            initiale: peer.displayName.characters.first.toUpperCase(),
            size: taille,
          ),
        ),
        // ⚠️ Le pseudo disparaît AVANT de devenir illisible, pas quand il l'est
        // déjà. Apple n'en met pas du tout sur sa ruche ; nous en avons besoin
        // (on ne reconnaît pas quarante camarades à leur photo en 30 px), donc
        // il faut au moins qu'il s'efface proprement.
        if (facteur > 0.68) ...[
          const SizedBox(height: NeoSpace.xs),
          Opacity(
            opacity: ((facteur - 0.68) / 0.2).clamp(0.0, 1.0),
            child: Text(
              peer.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
        ],
      ],
    );
  }
}

/// La géométrie du nid d'abeille — **pure, et hors du widget exprès**.
///
/// ⚠️ C'est de la géométrie, pas de l'affichage. La sortir permet de vérifier
/// qu'aucune pastille n'en chevauche une autre : un chevauchement ne lève
/// aucune erreur, il fait juste disparaître un ami sous un autre. Sur trois
/// amis ça se voit, sur quarante non. Gardé par `test/constellation_test.dart`.
abstract final class Ruche {
  static List<Offset> places(int combien, double pas) {
    if (combien <= 0) return const [];
    final places = <Offset>[Offset.zero];
    // Les six directions d'un pavage hexagonal.
    final directions = <Offset>[
      Offset(pas, 0),
      Offset(pas / 2, -pas * math.sqrt(3) / 2),
      Offset(-pas / 2, -pas * math.sqrt(3) / 2),
      Offset(-pas, 0),
      Offset(-pas / 2, pas * math.sqrt(3) / 2),
      Offset(pas / 2, pas * math.sqrt(3) / 2),
    ];
    var anneau = 1;
    while (places.length < combien) {
      // On part du voisin « sud » du premier de l'anneau, puis on longe les
      // six côtés.
      var point = directions[4] * anneau.toDouble();
      for (var cote = 0; cote < 6 && places.length < combien; cote++) {
        for (
          var pasSurLeCote = 0;
          pasSurLeCote < anneau && places.length < combien;
          pasSurLeCote++
        ) {
          places.add(point);
          point += directions[cote];
        }
      }
      anneau++;
    }
    return places;
  }
}
