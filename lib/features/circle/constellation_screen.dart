import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
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

/// **La constellation** : tes amis posés sur une sphère, comme l'écran
/// d'accueil d'une Apple Watch.
///
/// ---------------------------------------------------------------------------
/// ## 🔴 RÉÉCRITE EN ENTIER LE 2026-08-30, après le test de Jay
///
/// La première version *marchait* et était **inutilisable**. Trois défauts, et
/// aucun des trois ne levait la moindre erreur — c'est exactement la famille de
/// bugs qui ne se voit qu'en essayant, ou en comptant.
///
/// | Ce que Jay a vu | La cause réelle |
/// |---|---|
/// | « ce n'est pas centré » | `InteractiveViewer(constrained: false)` place le plan par son coin **haut-gauche**. Le centre du nid d'abeille tombait donc hors de l'écran, sous le bandeau. |
/// | « pas fluide du tout » | un `AnimatedBuilder` enveloppait la grille entière : **chaque pastille était RECONSTRUITE à chaque image** du glissement, et chacune consultait un provider au passage. |
/// | « pas de mouvement 4D » | le rétrécissement était linéaire et faible, et il n'y avait **aucune inertie**. Un plan qui s'arrête net au lâcher du doigt est mort, quelle que soit la beauté du reste. |
///
/// ⚠️ **La leçon, à ne pas reperdre** : j'ai livré une interface sans jamais
/// mesurer ce qu'elle coûte par image. « Ça compile et ça s'affiche » ne dit
/// rien de la fluidité — même famille que « le format est juste et le lecteur
/// inutilisable ».
///
/// ---------------------------------------------------------------------------
/// ## Comment celle-ci est faite
///
/// **1. On ne reconstruit rien pendant le geste, on REPEINT.**
/// Les pastilles sont construites **une fois**, quand la liste d'amis change.
/// Le déplacement est porté par un [Flow] : son délégué recalcule des matrices
/// à chaque image et se contente de **repeindre** des enfants déjà posés. Aucun
/// `build`, aucune lecture de provider, aucune mise en page pendant le
/// glissement.
///
/// ✅ **Et l'effet de bord est exactement ce qu'il fallait** : `RenderFlow`
/// rejoue l'inverse de la même matrice pour le test de contact. La zone
/// cliquable **est** la zone visible, par construction — plus besoin de calculer
/// des tailles à la main pour éviter d'avoir deux boîtes distinctes.
///
/// **2. La sphère, pour de vrai.**
/// Une pastille à la distance `d` du centre de l'écran n'est pas seulement
/// rapetissée : elle est **projetée**. En posant `θ = d / R` (son angle sur le
/// globe), sa position devient `R·sin θ` et sa taille `cos θ`. C'est la
/// projection orthographique d'une sphère, celle d'un globe vu de face. Les
/// pastilles se **resserrent** en s'éloignant au lieu de simplement rétrécir,
/// et c'est ce resserrement qui donne le relief.
///
/// **3. L'inertie.**
/// Au lâcher du doigt, une [FrictionSimulation] prolonge le mouvement. Sans
/// elle, aucun réglage de courbe ne rendra le plan « fluide » : ce qui manquait
/// n'était pas une animation, c'était une **physique**.
///
/// **4. Le centre est le centre.**
/// Le décalage part de zéro, et zéro veut dire « le milieu du nid d'abeille au
/// milieu de l'écran ». Il n'y a plus de plan géant dont on regarderait un coin.
///
/// ---------------------------------------------------------------------------
/// ## Pourquoi c'est un écran POUSSÉ
///
/// Cette grille se déplace au doigt ; l'accueil change de section au glissement
/// horizontal. C'est le même geste. Dans un onglet, les deux se disputeraient et
/// c'est l'arène des gestes qui trancherait, pas nous.
///
/// ✅ Vérifié dans le code : le détecteur de `HomeShell` entoure le CONTENU de
/// l'accueil, et une route poussée n'en est pas l'enfant. **Le conflit n'existe
/// pas**, structurellement. Solution proposée par Jay le 2026-08-29.
///
/// ⚠️ **Le glissement diagonal de fermeture reste impossible ici**, et pour la
/// raison retournée : une grille qu'on traîne au doigt prend déjà TOUS les
/// glissements. La croix est la sortie ; le double-appui recentre.
class ConstellationScreen extends ConsumerStatefulWidget {
  const ConstellationScreen({super.key});

  @override
  ConsumerState<ConstellationScreen> createState() =>
      _ConstellationScreenState();
}

class _ConstellationScreenState extends ConsumerState<ConstellationScreen>
    with TickerProviderStateMixin {
  /// Le déplacement du nid d'abeille, en unités « monde ».
  ///
  /// ⚠️ **Zéro veut dire centré**, et c'est tout l'intérêt : il n'y a aucun
  /// calage à faire au premier affichage, donc aucun moyen de se tromper.
  final _pan = ValueNotifier<Offset>(Offset.zero);

  /// Le zoom du pincement.
  final _zoom = ValueNotifier<double>(1);

  /// Le lancer : prolonge le mouvement après que le doigt est parti.
  late final AnimationController _lancer = AnimationController.unbounded(
    vsync: this,
  );

  /// Le retour élastique quand on a tiré trop loin.
  late final AnimationController _retour = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 340),
  );

  Offset _departLancer = Offset.zero;
  Offset _sensLancer = Offset.zero;
  Animation<Offset>? _retourAnime;
  double _zoomAuDepart = 1;
  var _filtre = FiltreDePalier.tous;

  /// Le rayon du nid d'abeille, en unités monde. Recalculé à chaque
  /// construction, parce qu'il dépend du nombre d'amis retenus par le filtre.
  double _rayonMonde = 0;

  static const _diametre = 76.0;
  static const _pas = 100.0;
  static const _hauteurEtiquette = 22.0;

  /// Le débordement maximal quand on tire au-delà du bord.
  ///
  /// ⚠️ Sans butée, on peut pousser toute la constellation hors de l'écran et
  /// croire qu'elle a planté. Avec une butée SÈCHE, le geste paraît cassé.
  /// L'élastique est la seule des trois options qui ne ment pas.
  static const _debordement = 96.0;

  @override
  void initState() {
    super.initState();
    _lancer.addListener(() {
      _pan.value = _borne(_departLancer + _sensLancer * _lancer.value);
    });
    _retour.addListener(() {
      final a = _retourAnime;
      if (a != null) _pan.value = a.value;
    });
  }

  @override
  void dispose() {
    _lancer.dispose();
    _retour.dispose();
    _pan.dispose();
    _zoom.dispose();
    super.dispose();
  }

  /// La butée dure : le centre du nid ne s'éloigne jamais de plus que son rayon.
  Offset _borne(Offset o) {
    final max = math.max(_rayonMonde, 1.0);
    return o.distance <= max ? o : Offset.fromDirection(o.direction, max);
  }

  /// La butée élastique, pendant le geste : le débordement s'amortit et sature.
  Offset _elastique(Offset o) {
    final max = math.max(_rayonMonde, 1.0);
    final d = o.distance;
    if (d <= max) return o;
    final trop = d - max;
    // Asymptotique : plus on tire, moins ça avance, et jamais au-delà de
    // `_debordement`.
    final amorti = _debordement * (1 - math.exp(-trop / _debordement));
    return Offset.fromDirection(o.direction, max + amorti);
  }

  void _arreterTout() {
    _lancer.stop();
    _retour.stop();
  }

  void _debutGeste(ScaleStartDetails d) {
    _arreterTout();
    _zoomAuDepart = _zoom.value;
  }

  void _pendantGeste(ScaleUpdateDetails d) {
    if (d.pointerCount > 1) {
      _zoom.value = (_zoomAuDepart * d.scale).clamp(0.65, 1.9);
    }
    // ⚠️ Le déplacement du doigt est en PIXELS, le décalage est en unités
    // monde : sans la division par le zoom, la grille suivrait deux fois plus
    // vite une fois zoomée, et le doigt « glisserait » sous le contenu.
    _pan.value = _elastique(_pan.value + d.focalPointDelta / _zoom.value);
  }

  void _finGeste(ScaleEndDetails d) {
    // Hors des bornes : on revient. La physique n'a rien à dire ici.
    if (_pan.value.distance > _rayonMonde) {
      _rappeler(_borne(_pan.value));
      return;
    }
    final v = d.velocity.pixelsPerSecond / _zoom.value;
    final vitesse = v.distance;
    // En dessous, c'est un doigt qui se pose, pas un lancer.
    if (vitesse < 220) return;

    _departLancer = _pan.value;
    _sensLancer = v / vitesse;
    // ⚠️ **Une vraie friction, pas une courbe.** Une durée fixe avec
    // `Curves.decelerate` donnerait le même arrêt quelle que soit la force du
    // geste — c'est précisément ce qui fait « pas fluide ».
    _lancer.animateWith(FrictionSimulation(0.135, 0, vitesse));
  }

  void _rappeler(Offset cible) {
    _retourAnime = Tween(
      begin: _pan.value,
      end: cible,
    ).animate(CurvedAnimation(parent: _retour, curve: Curves.easeOutCubic));
    _retour.forward(from: 0);
  }

  void _recentrer() {
    _arreterTout();
    _zoom.value = 1;
    _rappeler(Offset.zero);
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(currentUserIdProvider);
    final connections = ref.watch(fullConnectionsProvider);
    final amities = ref.watch(friendshipsProvider).value ?? const {};

    // ⚠️ **Les plus proches au CENTRE.** C'est la seule chose que l'ordre peut
    // dire, et il vaut mieux qu'il dise quelque chose : au milieu de la sphère
    // les pastilles sont les plus grandes et les plus lisibles. Un ordre
    // arbitraire gâcherait la meilleure place de l'écran.
    final ids = me == null
        ? <String>[]
        : (connections
              .map((c) => c.peerIdFor(me))
              .where(
                (id) =>
                    _filtre.retient(amities[id]?.tier ?? FriendshipTier.friend),
              )
              .toList()
            ..sort((a, b) {
              final parPalier = (amities[b]?.tier.rang ?? 0).compareTo(
                amities[a]?.tier.rang ?? 0,
              );
              if (parPalier != 0) return parPalier;
              return (amities[b]?.serie ?? 0).compareTo(amities[a]?.serie ?? 0);
            }));

    final places = Ruche.places(ids.length, _pas);
    _rayonMonde = places.fold<double>(0, (r, o) => math.max(r, o.distance));

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: ids.isEmpty
                ? _Vide(filtre: _filtre)
                : GestureDetector(
                    // ⚠️ `onScale*` SEUL : mêler `onPan*` et `onScale*` sur un
                    // même détecteur lève à l'exécution. Un geste à un doigt
                    // arrive ici avec `scale == 1`.
                    onScaleStart: _debutGeste,
                    onScaleUpdate: _pendantGeste,
                    onScaleEnd: _finGeste,
                    onDoubleTap: _recentrer,
                    behavior: HitTestBehavior.opaque,
                    child: Flow(
                      delegate: _SphereDelegate(
                        places: places,
                        pan: _pan,
                        zoom: _zoom,
                      ),
                      children: [
                        for (final id in ids)
                          // Construite UNE fois. Ensuite elle n'est plus que
                          // repeinte, image après image.
                          _Pastille(
                            key: ValueKey(id),
                            id: id,
                            diametre: _diametre,
                            hauteurEtiquette: _hauteurEtiquette,
                          ),
                      ],
                    ),
                  ),
          ),
          _Chapeau(
            filtre: _filtre,
            nombre: ids.length,
            onFiltre: (f) => setState(() {
              _filtre = f;
              _recentrer();
            }),
          ),
        ],
      ),
    );
  }
}

/// La projection sphérique, et le placement de chaque pastille.
///
/// ⚠️ **Tout ce qui suit se passe SANS reconstruire un seul widget.** Le
/// délégué reçoit `repaint: pan + zoom` : quand l'un des deux change, Flutter
/// **repeint** les enfants avec de nouvelles matrices. C'est toute la
/// différence entre 60 images par seconde et le diaporama de la première
/// version.
class _SphereDelegate extends FlowDelegate {
  _SphereDelegate({required this.places, required this.pan, required this.zoom})
    : super(repaint: Listenable.merge([pan, zoom]));

  final List<Offset> places;
  final ValueListenable<Offset> pan;
  final ValueListenable<double> zoom;

  /// Au-delà de cet angle, la pastille est passée derrière l'horizon : on ne la
  /// peint pas du tout.
  ///
  /// ⚠️ Ce n'est pas qu'une économie. Sans découpe, toutes les pastilles
  /// lointaines viendraient s'empiler sur le bord du disque en un tas illisible.
  static const _angleHorizon = 1.45;

  /// Là où une pastille commence à s'effacer, pour que sa disparition ne soit
  /// pas un clignotement.
  static const _angleFondu = 1.18;

  /// Ce qu'il reste d'une pastille au ras de l'horizon.
  static const _tailleMinimale = 0.24;

  @override
  Size getSize(BoxConstraints constraints) => constraints.biggest;

  /// Toutes les pastilles ont la MÊME boîte. C'est la matrice qui les
  /// rapetisse — donc la zone de contact suit la zone visible, sans qu'on ait
  /// à la calculer nous-mêmes.
  @override
  BoxConstraints getConstraintsForChild(int i, BoxConstraints constraints) =>
      constraints.loosen();

  @override
  void paintChildren(FlowPaintingContext context) {
    final taille = context.size;
    final centre = Offset(taille.width / 2, taille.height / 2);
    // Le rayon du globe : la demi-diagonale, pour que le disque projeté
    // recouvre l'écran entier, coins compris.
    final rayon =
        math.sqrt(taille.width * taille.width + taille.height * taille.height) /
        2;
    final z = zoom.value;
    final decalage = pan.value;

    for (var i = 0; i < context.childCount && i < places.length; i++) {
      // Position à plat, en pixels écran, avant projection.
      final plat = (places[i] + decalage) * z;
      final d = plat.distance;

      // θ : l'angle sur la sphère. `d` est une longueur d'ARC, pas une corde.
      final theta = d / rayon;
      if (theta > _angleHorizon) continue;

      final (vue, echelleBrute) = Ruche.projeter(
        d: d,
        rayon: rayon,
        minimum: _tailleMinimale,
      );
      final direction = d == 0 ? Offset.zero : plat / d;
      final vu = direction * vue;
      // Le raccourci de perspective : une surface inclinée de θ paraît cos θ
      // fois moins large. La MÊME loi déplace les pastilles et les rapetisse —
      // c'est de là que vient le relief.
      final echelle = echelleBrute * z;

      final opacite = theta <= _angleFondu
          ? 1.0
          : (1 - (theta - _angleFondu) / (_angleHorizon - _angleFondu)).clamp(
              0.0,
              1.0,
            );

      final boite = context.getChildSize(i) ?? Size.zero;
      final m = Matrix4.identity()
        ..translateByDouble(centre.dx + vu.dx, centre.dy + vu.dy, 0, 1)
        ..scaleByDouble(echelle, echelle, 1, 1)
        // On ramène le centre de l'enfant sur le point visé : sans ces deux
        // lignes, la mise à l'échelle partirait de son coin haut-gauche et les
        // pastilles fuiraient vers le bas-droite en rétrécissant.
        ..translateByDouble(-boite.width / 2, -boite.height / 2, 0, 1);

      context.paintChild(i, transform: m, opacity: opacite);
    }
  }

  @override
  bool shouldRepaint(_SphereDelegate old) =>
      old.places != places || old.pan != pan || old.zoom != zoom;
}

/// Une pastille : la photo, son anneau de palier, et le pseudo.
///
/// ⚠️ **Elle n'a aucune idée d'où elle est.** Toute la géométrie vit dans le
/// délégué, et c'est ce qui permet de la construire une fois pour toutes. Lui
/// passer sa position l'obligerait à se reconstruire à chaque image, et on
/// serait revenu au point de départ.
class _Pastille extends ConsumerWidget {
  const _Pastille({
    super.key,
    required this.id,
    required this.diametre,
    required this.hauteurEtiquette,
  });

  final String id;
  final double diametre;
  final double hauteurEtiquette;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Profile? peer = ref.watch(profileByIdProvider(id)).value;
    final boite = Size(diametre + 24, diametre + hauteurEtiquette);
    if (peer == null) {
      return SizedBox(width: boite.width, height: boite.height);
    }

    return SizedBox(
      width: boite.width,
      height: boite.height,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => UserLibraryScreen(profile: peer),
              ),
            ),
            child: TierAvatar(
              peerId: id,
              storedAvatar: peer.avatarUrl,
              initiale: peer.displayName.characters.first.toUpperCase(),
              size: diametre,
            ),
          ),
          const SizedBox(height: NeoSpace.xs),
          Text(
            peer.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
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
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                NeoSpace.lg,
                NeoSpace.sm,
                NeoSpace.sm,
                0,
              ),
              child: Row(
                children: [
                  // ⚠️ `IgnorePointer` sur le titre : sans lui, tout le haut de
                  // l'écran mangerait les glissements et la constellation
                  // paraîtrait bloquée dans cette bande.
                  Expanded(
                    child: IgnorePointer(
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
                  ),
                  // La SEULE sortie découvrable — voir l'en-tête du fichier.
                  IconButton.filledTonal(
                    icon: const Icon(Icons.close),
                    tooltip: 'Fermer',
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
            ),
            const SizedBox(height: NeoSpace.sm),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: NeoSpace.lg),
              child: Row(
                children: [
                  for (final f in FiltreDePalier.values)
                    Padding(
                      padding: const EdgeInsets.only(right: NeoSpace.sm),
                      child: ChoiceChip(
                        label: Text(f.label),
                        selected: filtre == f,
                        onSelected: (_) => onFiltre(f),
                        backgroundColor: p.surface,
                      ),
                    ),
                ],
              ),
            ),
          ],
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

/// La géométrie de la constellation — **pure, et hors des widgets exprès**.
///
/// ⚠️ C'est de la géométrie, pas de l'affichage. La sortir permet de la
/// **mesurer** : un chevauchement de pastilles ne lève aucune erreur, il fait
/// juste disparaître un ami sous un autre. Sur trois amis ça se voit, sur
/// quarante non. Gardé par `test/constellation_test.dart`.
abstract final class Ruche {
  /// Les positions d'un nid d'abeille, en spirale depuis le centre.
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

  /// La projection sphérique — **isolée pour être mesurable**.
  ///
  /// Rend la distance VUE et l'échelle d'une pastille dont la position à plat
  /// est à la distance [d] du centre, sur un globe de rayon [rayon].
  ///
  /// ⚠️ Un effet visuel se juge à l'œil, mais ses **invariants** ne se voient
  /// pas : que rien ne grandisse en s'éloignant, que rien ne sorte du disque,
  /// que deux pastilles ne se croisent jamais. Ceux-là se démontrent.
  static (double vue, double echelle) projeter({
    required double d,
    required double rayon,
    double minimum = 0.24,
  }) {
    final theta = d / rayon;
    return (rayon * math.sin(theta), math.max(math.cos(theta), minimum));
  }
}
