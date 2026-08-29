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
import 'sphere.dart';

/// **La constellation** : tes amis posés sur une bulle qu'on fait tourner.
///
/// ---------------------------------------------------------------------------
/// ## 🔴 TROISIÈME VERSION — 2026-08-30, après deux retours de Jay
///
/// | Version | Ce que Jay a dit | Ce qui n'allait pas |
/// |---|---|---|
/// | 1 | « pas centré, pas fluide, pas de 4D » | le plan était posé par son coin, chaque pastille était reconstruite à chaque image, aucune inertie |
/// | 2 | « tout le groupe bouge en même temps » | c'était encore un **plan** avec une loupe. Sur un plan, tous les points se déplacent du même vecteur : le volume est impossible. |
///
/// ➡️ **Consigne de Jay** : *« comme si on posait chaque photo sur une bulle ou
/// une sphère que l'on faisait tourner […] une vraie physique avec de vraies
/// règles, pas du bricolage »*.
///
/// ## Ce que ça change, et pourquoi ça ne se réglait pas
///
/// Sur une sphère qui tourne, un ami près de l'axe bouge à peine et un ami sur
/// l'équateur file. **C'est ce désaccord de vitesses qui fait le volume**, et
/// aucune courbe posée sur un plan ne peut l'imiter — parce que sur un plan il
/// n'y a qu'un seul vecteur pour tout le monde.
///
/// ## Les quatre règles, toutes dans `sphere.dart`, toutes mesurées
///
/// 1. **La répartition** : spirale d'or. Écart régulier quel que soit le nombre
///    d'amis — la seule construction simple qui n'entasse pas aux pôles.
/// 2. **La taille de la sphère** : `diamètre × marge ⁄ √(4π/N)`. Plus d'amis =
///    sphère plus grande. Et comme le doigt suit la surface au millimètre, un
///    monde plus peuplé paraît plus **lourd**. Ce n'est pas un effet ajouté,
///    c'est une conséquence.
/// 3. **Le geste** : l'arc parcouru à la surface vaut la distance parcourue par
///    le doigt. La photo touchée reste sous le doigt.
/// 4. **Le lâcher** : moment angulaire, puis friction. La rotation ne connaît
///    **aucune butée** — la sphère est infinie par construction, il n'y a pas de
///    bord à atteindre.
///
/// ## Ce qui n'a pas changé depuis la version 2, et qui était juste
///
/// - On ne reconstruit rien pendant le geste : un [Flow] **repeint** des enfants
///   déjà posés. Zéro `build`, zéro requête, zéro mise en page par image.
/// - C'est un écran **poussé**, donc aucun conflit avec le glissement de
///   navigation de l'accueil.
///
/// ⚠️ **Le contact est géré ici, pas par les enfants.** Sur une sphère, deux
/// amis peuvent se recouvrir : celui de devant doit gagner. `RenderFlow` teste
/// les enfants dans l'ordre de la liste, qui n'a rien à voir avec la
/// profondeur — il aurait donc parfois désigné l'ami de derrière. On refait
/// donc le test nous-mêmes, du plus proche au plus lointain.
class ConstellationScreen extends ConsumerStatefulWidget {
  const ConstellationScreen({super.key});

  @override
  ConsumerState<ConstellationScreen> createState() =>
      _ConstellationScreenState();
}

class _ConstellationScreenState extends ConsumerState<ConstellationScreen>
    with SingleTickerProviderStateMixin {
  /// L'orientation de la bulle. **Aucune borne** : elle tourne indéfiniment.
  final _rotation = ValueNotifier<Rot>(Rot.identite);

  /// Le grossissement du pincement.
  final _zoom = ValueNotifier<double>(1);

  /// L'élan : la bulle continue de tourner après le doigt, et ralentit.
  late final AnimationController _elan = AnimationController.unbounded(
    vsync: this,
  );

  /// L'axe autour duquel l'élan fait tourner, figé au lâcher du doigt.
  Vec3 _axeElan = const Vec3(0, 1, 0);

  /// L'angle déjà consommé par l'élan — il ne s'applique qu'en différence.
  double _angleConsomme = 0;

  double _zoomAuDepart = 1;
  var _filtre = FiltreDePalier.tous;

  /// Ce que la dernière peinture a réellement affiché. Sert au test de contact.
  final _vues = <PointVu>[];

  /// Le rayon affiché à la dernière peinture — il fait la conversion entre les
  /// pixels du doigt et les radians de la sphère.
  double _rayonAffiche = 1;

  static const _diametre = 72.0;
  static const _hauteurEtiquette = 22.0;

  @override
  void initState() {
    super.initState();
    _elan.addListener(_tourneParElan);
  }

  @override
  void dispose() {
    _elan.dispose();
    _rotation.dispose();
    _zoom.dispose();
    super.dispose();
  }

  void _tourneParElan() {
    final delta = _elan.value - _angleConsomme;
    _angleConsomme = _elan.value;
    if (delta == 0) return;
    _rotation.value = Rot.axeAngle(_axeElan, delta).fois(_rotation.value);
  }

  void _debutGeste(ScaleStartDetails d) {
    _elan.stop();
    _zoomAuDepart = _zoom.value;
  }

  void _pendantGeste(ScaleUpdateDetails d) {
    if (d.pointerCount > 1) {
      _zoom.value = (_zoomAuDepart * d.scale).clamp(0.7, 1.8);
    }
    final delta = d.focalPointDelta;
    if (delta == Offset.zero) return;
    // ⚠️ La conversion pixels → radians passe par le rayon AFFICHÉ, zoom
    // compris : sans ça, la sphère tournerait deux fois trop vite une fois
    // agrandie et le doigt « glisserait » sur la surface.
    _rotation.value = Rot.axeAngle(
      Sphere.axeDeGeste(delta),
      Sphere.angleDeGeste(delta.distance, _rayonAffiche),
    ).fois(_rotation.value);
  }

  void _finGeste(ScaleEndDetails d) {
    final v = d.velocity.pixelsPerSecond;
    final vitesse = v.distance;
    // En dessous, c'est un doigt qui se pose, pas un lancer.
    if (vitesse < 200) return;
    _axeElan = Sphere.axeDeGeste(v);
    _angleConsomme = 0;
    // ⚠️ **Une vraie friction, et sur l'ANGLE.** Une durée fixe avec une
    // courbe donnerait le même arrêt quelle que soit la force du geste — c'est
    // exactement ce qui fait « pas fluide ». Ici la vitesse initiale est une
    // vitesse angulaire, et elle s'éteint toute seule.
    _elan.animateWith(
      FrictionSimulation(0.12, 0, Sphere.angleDeGeste(vitesse, _rayonAffiche)),
    );
  }

  /// Le test de contact, **du plus proche au plus lointain**.
  void _appui(TapUpDetails d, List<String> ids) {
    final devantDabord = _vues.toList()
      ..sort((a, b) => b.profondeur.compareTo(a.profondeur));
    for (final vue in devantDabord) {
      final rayonPastille = _diametre / 2 * vue.echelle * _zoom.value;
      if ((d.localPosition - vue.centre).distance <= rayonPastille) {
        final profil = ref.read(profileByIdProvider(ids[vue.index])).value;
        if (profil == null) return;
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => UserLibraryScreen(profile: profil)),
        );
        return;
      }
    }
  }

  void _remettreDroit() {
    _elan.stop();
    _zoom.value = 1;
    _rotation.value = Rot.identite;
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(currentUserIdProvider);
    final connections = ref.watch(fullConnectionsProvider);
    final amities = ref.watch(friendshipsProvider).value ?? const {};

    // ⚠️ **Les plus proches en PREMIER**, donc au pôle avant de la spirale :
    // c'est là qu'on regarde quand l'écran s'ouvre. L'ordre est la seule chose
    // qui puisse dire quelque chose ici, autant qu'il dise quelque chose.
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
                    onTapUp: (d) => _appui(d, ids),
                    onDoubleTap: _remettreDroit,
                    behavior: HitTestBehavior.opaque,
                    child: Flow(
                      delegate: _BulleDelegate(
                        points: Sphere.points(ids.length),
                        rotation: _rotation,
                        zoom: _zoom,
                        diametre: _diametre,
                        vues: _vues,
                        surRayon: (r) => _rayonAffiche = r,
                      ),
                      children: [
                        for (final id in ids)
                          // Construite UNE fois. Ensuite elle n'est plus que
                          // repeinte, image après image.
                          // 🔴 **`RepaintBoundary` — la correction de la
                          // saccade constatée par Jay le 2026-08-30.**
                          //
                          // Sans lui, tous les enfants vivent dans le MÊME
                          // calque : à chaque image, Flutter réenregistre les
                          // opérations de dessin des 155 pastilles — le cercle,
                          // le dégradé de l'anneau, la découpe, le texte.
                          // Le `Flow` évitait déjà de les *reconstruire* ; il
                          // ne pouvait pas éviter de les *réenregistrer*.
                          //
                          // Avec lui, chaque pastille est dessinée **une fois**
                          // dans son propre calque. Par image, il ne reste
                          // qu'à replacer des calques déjà prêts — du travail
                          // de carte graphique, pas de processeur.
                          //
                          // ⚠️ C'est exactement le cas d'école où il aide : un
                          // enfant qui ne change jamais, déplacé à chaque
                          // image. Posé au hasard, il coûterait plus qu'il ne
                          // rapporte.
                          RepaintBoundary(
                            key: ValueKey(id),
                            child: _Pastille(
                              id: id,
                              diametre: _diametre,
                              hauteurEtiquette: _hauteurEtiquette,
                            ),
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
              _remettreDroit();
            }),
          ),
        ],
      ),
    );
  }
}

/// La bulle : elle tourne les points, les projette, et les peint du fond vers
/// l'avant.
///
/// ⚠️ **Tout se passe ici SANS reconstruire un seul widget.** Le délégué reçoit
/// `repaint: rotation + zoom` : quand l'un change, Flutter **repeint** les
/// enfants avec de nouvelles matrices. C'est toute la différence entre 60
/// images par seconde et un diaporama.
class _BulleDelegate extends FlowDelegate {
  _BulleDelegate({
    required this.points,
    required this.rotation,
    required this.zoom,
    required this.diametre,
    required this.vues,
    required this.surRayon,
  }) : super(repaint: Listenable.merge([rotation, zoom]));

  final List<Vec3> points;
  final ValueListenable<Rot> rotation;
  final ValueListenable<double> zoom;
  final double diametre;

  /// Ce que cette peinture a affiché — relu par l'écran pour le test de contact.
  ///
  /// ⚠️ **Une liste partagée, et c'est assumé.** L'alternative serait de
  /// recalculer toute la projection au moment du toucher : deux endroits qui
  /// font le même calcul, donc deux occasions de diverger. Ici, ce qu'on touche
  /// est très exactement ce qui a été peint.
  final List<PointVu> vues;

  /// Publie le rayon réellement affiché : c'est lui qui convertit les pixels du
  /// doigt en radians de rotation.
  final void Function(double) surRayon;

  @override
  Size getSize(BoxConstraints constraints) => constraints.biggest;

  /// Toutes les pastilles ont la MÊME boîte. C'est la matrice qui les
  /// rapetisse — donc la zone peinte suit exactement la géométrie.
  @override
  BoxConstraints getConstraintsForChild(int i, BoxConstraints constraints) =>
      constraints.loosen();

  @override
  void paintChildren(FlowPaintingContext context) {
    final taille = context.size;
    // Le rayon minimum : la bulle occupe une bonne part de l'écran même à trois
    // amis, sinon tout se tasse au centre.
    final rayonMinimum = taille.shortestSide * 0.34;
    final rayon =
        Sphere.rayon(
          combien: points.length,
          diametre: diametre,
          rayonMinimum: rayonMinimum,
        ) *
        zoom.value;
    surRayon(rayon);

    final r = rotation.value;
    vues
      ..clear()
      ..addAll([
        for (var i = 0; i < points.length && i < context.childCount; i++)
          Sphere.projeter(
            index: i,
            p: r.applique(points[i]),
            rayonAffiche: rayon,
            ecran: taille,
          ),
      ]);

    // ⚠️ **Du fond vers l'avant.** Sans ce tri, un ami situé derrière la bulle
    // se dessinerait par-dessus un ami de devant selon son rang dans la liste :
    // l'image resterait jolie et la profondeur serait fausse.
    final ordre = vues.toList()
      ..sort((a, b) => a.profondeur.compareTo(b.profondeur));

    for (final vue in ordre) {
      final boite = context.getChildSize(vue.index) ?? Size.zero;
      final echelle = vue.echelle * zoom.value;
      final m = Matrix4.identity()
        ..translateByDouble(vue.centre.dx, vue.centre.dy, 0, 1)
        ..scaleByDouble(echelle, echelle, 1, 1)
        // On ramène le centre de l'enfant sur le point visé : sans ces deux
        // lignes, la mise à l'échelle partirait de son coin haut-gauche et les
        // pastilles fuiraient vers le bas-droite en rétrécissant.
        ..translateByDouble(-boite.width / 2, -boite.height / 2, 0, 1);
      // ⚠️ **`opacity: 1.0` n'ouvre AUCUN calque**, alors que toute autre
      // valeur en ouvre un. On passe donc l'opacité seulement quand elle sert
      // vraiment — c'est-à-dire pour la moitié arrière de la bulle.
      context.paintChild(
        vue.index,
        transform: m,
        opacity: vue.opacite >= 0.999 ? 1.0 : vue.opacite,
      );
    }
  }

  @override
  bool shouldRepaint(_BulleDelegate old) =>
      old.points != points ||
      old.rotation != rotation ||
      old.zoom != zoom ||
      old.diametre != diametre;
}

/// Une pastille : la photo, son anneau de palier, et le pseudo.
///
/// ⚠️ **Elle n'a aucune idée d'où elle est, ni de ce qu'on fait dessus.** Toute
/// la géométrie vit dans le délégué, et le toucher est géré par l'écran. C'est
/// ce qui permet de la construire une fois pour toutes : lui passer sa position
/// l'obligerait à se reconstruire à chaque image.
class _Pastille extends ConsumerWidget {
  const _Pastille({
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
    final boite = Size(diametre + 26, diametre + hauteurEtiquette);
    if (peer == null) {
      return SizedBox(width: boite.width, height: boite.height);
    }

    return SizedBox(
      width: boite.width,
      height: boite.height,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TierAvatar(
            peerId: id,
            storedAvatar: peer.avatarUrl,
            initiale: peer.displayName.characters.first.toUpperCase(),
            size: diametre,
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
                  // l'écran mangerait les gestes et la bulle paraîtrait bloquée
                  // dans cette bande.
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

/// Gardé pour l'écran : le nombre d'amis au-delà duquel la bulle devient plus
/// grande que l'écran, donc où il faut vraiment la faire tourner pour tout voir.
///
/// ⚠️ Purement informatif — aucune règle n'en dépend. Il est ici pour que la
/// question « à partir de combien d'amis ça change de nature ? » ait une
/// réponse chiffrée au lieu d'une impression.
double amisAvantDeDevoirTourner(double coteEcran, double diametre) {
  // rayon(N) > coté/2  ⟺  N > 4π (diamètre × marge × 2 / coté)²
  final k = diametre * 1.35 * 2 / coteEcran;
  return 4 * math.pi / (k * k);
}
