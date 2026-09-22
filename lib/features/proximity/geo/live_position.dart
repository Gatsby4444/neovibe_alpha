/// **La vue dérivée de la position : garder le meilleur relevé, et le servir.**
///
/// ## 🔴 Le défaut que ce fichier répare — relevé le 2026-09-22
///
/// Dans le métro, NeoVibe affichait Jay à `réseau ± 675 m` quand Google Maps le
/// plaçait à la bonne intersection. Jay : *« je ne peux pas livrer cela, on
/// n'est pas au niveau. »*
///
/// La cause n'était **pas** la source des données — vérifié le même jour dans
/// `geolocator_android-4.6.2/…/GeolocationManager.java:80` : quand les services
/// Google Play sont présents, le paquet passe déjà par le moteur de position de
/// Google, celui-là même qui sert Google Maps. La cause était la **façon de
/// demander** :
///
/// > `getCurrentPosition` s'abonne, prend la **toute première** position livrée,
/// > puis coupe (`MethodCallHandlerImpl.java:241`). La première livrée est la
/// > plus rapide, donc la plus grossière — celle que le moteur rend de mémoire
/// > avant d'avoir rien mesuré.
///
/// ## Ce que fait ce fichier, en une image
///
/// Demander sa position, ce n'est pas prendre une photo : c'est **régler des
/// jumelles**. Les premières secondes sont floues, puis ça se précise.
/// [CoarseLocation.watch] tient les jumelles à l'œil ; ce fichier **retient la
/// vue la plus nette** et la donne à qui la demande.
///
/// ## ⚠️ Sa place dans la chaîne : c'est le SERVEUR, pas la cuisine
///
/// Règle de Jay du 2026-08-25. [CoarseLocation] est la cuisine : elle publie
/// fidèlement tout ce qu'Android lui donne, du meilleur au pire, sans trier.
/// Trier est un **usage** — il vit ici. Les écrans, eux, ne parlent jamais à
/// [CoarseLocation] : ils lisent [livePositionProvider].
///
/// ## ⚠️ Un seul chemin vers la position, côté Dart
///
/// Règle 4 de `CLAUDE.md` — *un chemin, une donnée*. Huit endroits appelaient
/// `CoarseLocation.current()` chacun de leur côté, avec chacun son relevé et sa
/// fraîcheur : huit avis sur « où suis-je », qu'aucune erreur n'aurait départagés.
/// Ils passent tous par [LivePosition.current] désormais.
///
/// ## ⚠️ Ce que ce fichier NE fait pas
///
/// Il ne décide pas quand la position vaut la peine d'être mesurée : ce sont
/// ses lecteurs qui le disent, par [acquire] et [release]. Tant que personne ne
/// demande, aucune radio ne tourne et rien ne coûte de batterie.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'coarse_location.dart';

/// Ce que la vue dérivée retient à un instant donné.
///
/// ⚠️ Porte son égalité de valeur, sans quoi tout écran qui l'observe se
/// redessinerait à chaque relevé — plusieurs fois par seconde, pour rien.
class LivePositionState {
  const LivePositionState({this.fix, this.at, this.received = 0, this.error});

  /// Le meilleur relevé retenu, ou `null` si aucun n'est encore arrivé.
  final CoarseFix? fix;

  /// Quand [fix] a été retenu. `null` avec [fix] `null`.
  ///
  /// ⚠️ C'est l'heure de **réception**, pas celle qu'Android date sur le
  /// relevé. Les deux diffèrent quand le moteur rend un point de mémoire, et
  /// c'est la réception qui dit depuis combien de temps on n'a rien de neuf.
  final DateTime? at;

  /// Combien de relevés sont arrivés depuis le début de l'abonnement.
  ///
  /// ⚠️ **Instrument, et il répond à une question précise** : « le flux
  /// tourne-t-il vraiment ? ». Un compteur figé à 1 avec une mauvaise
  /// précision, c'est le défaut du 2026-09-22 revenu ; un compteur qui monte
  /// avec une précision qui ne descend pas, c'est un réglage du téléphone.
  final int received;

  /// La dernière erreur du flux, ou `null`. Voir [LivePosition.acquire].
  final String? error;

  /// L'âge du relevé retenu, ou `null` s'il n'y en a pas.
  Duration? ageAt(DateTime now) => at == null ? null : now.difference(at!);

  /// Le relevé est-il encore « où je suis » ?
  ///
  /// Même borne que le repli sur le dernier point connu
  /// (`CoarseLocation.maxLastKnownAge`), et pour la même raison : au-delà, on
  /// s'annoncerait là où l'on n'est plus.
  bool isFresh(DateTime now) =>
      at != null && CoarseLocation.isFreshEnough(at!, now);

  @override
  bool operator ==(Object other) =>
      other is LivePositionState &&
      other.fix == fix &&
      other.at == at &&
      other.received == received &&
      other.error == error;

  @override
  int get hashCode => Object.hash(fix, at, received, error);
}

/// La vue dérivée. **Retient le meilleur relevé récent ; ne mesure rien
/// elle-même.**
class LivePosition extends Notifier<LivePositionState> {
  /// Au-delà de cet écart d'âge, un relevé plus jeune gagne **même s'il est
  /// moins précis**.
  ///
  /// ⚠️ Sans cette règle, un excellent relevé figerait la position : on garde
  /// éternellement le point le plus précis, et quelqu'un qui marche reste
  /// affiché là où il était. Une précision ancienne ne décrit plus rien.
  ///
  /// **Trente secondes**, la même valeur que le natif (`LocationBeat.kt:136`),
  /// parce que c'est la même règle écrite deux fois dans deux langages : deux
  /// valeurs différentes, et le point affiché et le point publié
  /// divergeraient sans que rien ne le signale.
  static const renouvelle = Duration(seconds: 30);

  int _holders = 0;
  StreamSubscription<CoarseFix>? _sub;

  /// Le tir unique en cours, s'il y en a un.
  ///
  /// ⚠️ Partagé : trois écrans qui demandent la position en même temps doivent
  /// déclencher **une** mesure, pas trois. Sans ça, chacun ouvre son
  /// abonnement au moteur de position et on paie trois fois le réveil radio.
  Future<CoarseFix?>? _tirEnCours;

  @override
  LivePositionState build() {
    ref.onDispose(_debranche);
    return const LivePositionState();
  }

  /// **La règle, isolée pour être éprouvable : retient-on ce relevé ?**
  ///
  /// ⚠️ Séparée parce que se tromper ici ne lève aucune erreur. Trop stricte,
  /// la position se fige sur un vieux point ; trop laxiste, elle saute au gré
  /// du bruit — et les deux s'affichent comme un point posé sur une carte.
  ///
  /// L'ordre compte :
  ///
  /// 1. rien de retenu → on prend ;
  /// 2. ce qu'on tient est **périmé** → on prend, quelle que soit sa précision :
  ///    un mauvais point d'ici vaut mieux qu'un bon point d'il y a dix minutes ;
  /// 3. le nouveau est **plus net** → on prend, toujours ;
  /// 4. ce qu'on tient a vieilli de plus de [renouvelle] **et** le nouveau
  ///    n'est pas *nettement* plus flou ([degradationMax]) → on prend ;
  /// 5. sinon → on garde.
  ///
  /// ⚠️ **La quatrième ligne est celle qui protège la marche à pied**, et la
  /// cinquième celle qui protège l'entrée dans un bâtiment. Sans la 4, un
  /// excellent relevé fige la position et quelqu'un qui marche reste affiché
  /// où il était. Sans la 5, un relevé de rue à ± 10 m serait remplacé
  /// trente secondes plus tard par une estimation d'antenne à ± 500 m — et le
  /// point sauterait à deux rues de là, ce que Jay a vu le 2026-09-22.
  static bool retient({
    required CoarseFix? garde,
    required DateTime? gardeAt,
    required CoarseFix venu,
    required DateTime now,
  }) {
    if (garde == null || gardeAt == null) return true;
    if (!CoarseLocation.isFreshEnough(gardeAt, now)) return true;
    if (venu.accuracy <= garde.accuracy) return true;
    return now.difference(gardeAt) > renouvelle &&
        venu.accuracy <= garde.accuracy * degradationMax;
  }

  /// De combien un relevé peut être plus flou que celui qu'on tient et quand
  /// même le remplacer, une fois celui-ci vieilli.
  ///
  /// **Deux**, c'est-à-dire « deux fois moins net, pas plus ». Ce n'est pas un
  /// chiffre mesuré : c'est la frontière entre *bouger* (la précision varie
  /// peu d'un relevé à l'autre) et *changer de palier* (le GPS lâche, l'antenne
  /// prend le relais, et l'incertitude est multipliée par dix ou cinquante).
  /// À revoir quand on aura mesuré, à deux téléphones — `RAPPELS.md` #158.
  static const degradationMax = 2;

  /// **Quelqu'un a besoin d'une position vivante.** À relâcher par [release].
  ///
  /// ⚠️ Compté, pas booléen : la carte et le ping peuvent en avoir besoin en
  /// même temps, et le premier qui s'en va ne doit pas couper l'autre.
  void acquire() {
    _holders++;
    if (_sub != null) return;
    _sub = ref
        .read(coarseLocationProvider)
        .watch()
        .listen(
          _offre,
          onError: (Object e) {
            // Permission retirée en cours de route, service de localisation
            // éteint : il n'y a plus rien à écouter, et c'est un fait à dire —
            // pas une panne à cacher. Ce qu'on tenait reste, il vieillira.
            state = LivePositionState(
              fix: state.fix,
              at: state.at,
              received: state.received,
              error: e.toString(),
            );
          },
          cancelOnError: false,
        );
  }

  /// Un lecteur s'en va. La radio s'arrête quand le dernier est parti.
  ///
  /// ⚠️ **Le relevé retenu n'est PAS effacé.** Il reste une mesure valable, qui
  /// vieillira toute seule ([LivePositionState.isFresh]). L'effacer ferait
  /// repartir de zéro le prochain écran ouvert, et lui redonnerait la première
  /// réponse grossière — le défaut d'origine, revenu par la porte de l'arrêt.
  void release() {
    if (_holders > 0) _holders--;
    if (_holders == 0) _debranche();
  }

  void _debranche() {
    _sub?.cancel();
    _sub = null;
  }

  /// **Le meilleur relevé disponible maintenant, quitte à en demander un.**
  ///
  /// Pour tout ce qui a besoin d'une position **une fois** : créer un
  /// événement, poser une ancre, un tour de balise. Si le flux tourne déjà et
  /// tient quelque chose de frais, ça ne coûte rien ; sinon un tir unique part,
  /// et son résultat est **rangé au même endroit que les autres** — sans quoi
  /// on aurait deux positions courantes qui s'ignorent.
  Future<CoarseFix?> current() async {
    final now = DateTime.now();
    if (state.isFresh(now)) return state.fix;
    final tir = _tirEnCours ??= ref.read(coarseLocationProvider).current();
    try {
      final fix = await tir;
      if (fix != null) _offre(fix);
      return fix ?? state.fix;
    } finally {
      _tirEnCours = null;
    }
  }

  /// Un relevé arrive — du flux ou d'un tir unique. **Constate, puis range.**
  void _offre(CoarseFix venu) {
    final now = DateTime.now();
    final garde = retient(
      garde: state.fix,
      gardeAt: state.at,
      venu: venu,
      now: now,
    );
    state = LivePositionState(
      fix: garde ? venu : state.fix,
      at: garde ? now : state.at,
      received: state.received + 1,
      error: null,
    );
  }
}

final livePositionProvider = NotifierProvider<LivePosition, LivePositionState>(
  LivePosition.new,
);
