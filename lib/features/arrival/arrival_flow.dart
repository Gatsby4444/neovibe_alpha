import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/event.dart';
import '../events/events_providers.dart';
import 'arrival_permissions.dart';

/// **L'arrivée en soirée — le parcours de test (développeur, 2026-09-24).**
///
/// Consigne de Jay : *« un test activable depuis les paramètres développeur
/// pour l'initialisation en soirée de l'app […] carte blanche, c'est à part,
/// c'est une interface test »*.
///
/// ⚠️ **Ce parcours n'écrit RIEN** : ni compte, ni profil, ni présence dans un
/// événement. Il lit de vraies choses (les autorisations, la position, les
/// soirées autour) et simule le reste — ce qui est simulé porte le mot
/// « démo » à l'écran. Le selfie reste un fichier temporaire de la caméra,
/// effacé à la sortie du test.
enum ArrivalStep {
  /// L'accroche : « ce soir, ça se passe ici ».
  threshold,

  /// Le prénom.
  name,

  /// Le selfie, obligatoire — la photo de profil temporaire.
  selfie,

  /// Le compte (simulé dans le test).
  account,

  /// Position, Bluetooth, notifications — une à la fois.
  permissions,

  /// La recherche de la soirée où l'on est.
  radar,

  /// « Tu es dedans » : les présents, le Drop, les défis.
  inside,
}

/// Une soirée trouvée — réelle, ou la démo quand il n'y en a aucune autour.
@immutable
class ArrivalVenue {
  const ArrivalVenue({
    required this.title,
    required this.place,
    required this.presentCount,
    required this.isDemo,
  });

  /// La soirée de démonstration, quand rien n'est trouvé autour.
  static const demo = ArrivalVenue(
    title: 'Jeudi électro',
    place: 'Le Comptoir',
    presentCount: 23,
    isDemo: true,
  );

  factory ArrivalVenue.fromNearby(NearbyEvent e) => ArrivalVenue(
    title: e.title,
    place: e.venueName ?? e.title,
    presentCount: e.presentCount,
    isDemo: false,
  );

  final String title;
  final String place;
  final int presentCount;
  final bool isDemo;

  @override
  bool operator ==(Object other) =>
      other is ArrivalVenue &&
      other.title == title &&
      other.place == place &&
      other.presentCount == presentCount &&
      other.isDemo == isDemo;

  @override
  int get hashCode => Object.hash(title, place, presentCount, isDemo);
}

@immutable
class ArrivalState {
  const ArrivalState({
    this.step = ArrivalStep.threshold,
    this.firstName = '',
    this.selfie,
    this.location,
    this.bluetooth,
    this.notifications,
    this.venue,
    this.searching = false,
  });

  final ArrivalStep step;
  final String firstName;

  /// Le selfie pris, ou `null`. **Obligatoire** pour passer l'étape.
  final File? selfie;

  /// `null` = pas encore lue.
  final ArrivalGrant? location;
  final ArrivalGrant? bluetooth;
  final ArrivalGrant? notifications;

  final ArrivalVenue? venue;
  final bool searching;

  String get initial =>
      firstName.isEmpty ? '' : firstName.characters.first.toUpperCase();

  ArrivalState copyWith({
    ArrivalStep? step,
    String? firstName,
    File? selfie,
    bool clearSelfie = false,
    ArrivalGrant? location,
    ArrivalGrant? bluetooth,
    ArrivalGrant? notifications,
    ArrivalVenue? venue,
    bool? searching,
  }) => ArrivalState(
    step: step ?? this.step,
    firstName: firstName ?? this.firstName,
    selfie: clearSelfie ? null : (selfie ?? this.selfie),
    location: location ?? this.location,
    bluetooth: bluetooth ?? this.bluetooth,
    notifications: notifications ?? this.notifications,
    venue: venue ?? this.venue,
    searching: searching ?? this.searching,
  );
}

/// Le serveur du parcours : il enchaîne les étapes et demande à la cuisine
/// ([ArrivalPermissions], les soirées autour). **Il ne dessine rien.**
class ArrivalFlow extends Notifier<ArrivalState> {
  @override
  ArrivalState build() {
    // Le selfie du test est un fichier temporaire de la caméra : il ne
    // survit pas au test. Lu au moment de la fermeture, pas à la
    // construction — c'est le dernier pris qui compte.
    ref.onDispose(() => _discard(_selfie));
    return const ArrivalState();
  }

  /// Le dernier selfie pris, tenu hors de l'état pour pouvoir l'effacer à la
  /// fermeture (l'état n'est plus lisible à ce moment-là).
  File? _selfie;

  static void _discard(File? file) {
    if (file == null) return;
    file.delete().ignore();
  }

  ArrivalPermissions get _perms => ref.read(arrivalPermissionsProvider);

  void goTo(ArrivalStep step) => state = state.copyWith(step: step);

  /// Revenir d'une étape — jamais avant l'accroche, jamais depuis la soirée.
  bool back() {
    final i = state.step.index;
    if (i == 0 || state.step == ArrivalStep.inside) return false;
    // La recherche se relance d'elle-même : on revient aux autorisations.
    goTo(ArrivalStep.values[i - 1]);
    return true;
  }

  void setName(String value) => state = state.copyWith(firstName: value.trim());

  void setSelfie(File file) {
    if (_selfie?.path != file.path) _discard(_selfie);
    _selfie = file;
    state = state.copyWith(selfie: file);
  }

  void clearSelfie() {
    _discard(_selfie);
    _selfie = null;
    state = state.copyWith(clearSelfie: true);
  }

  /// Relit les trois autorisations, sans rien demander.
  Future<void> readGrants() async {
    final location = await _perms.location();
    final bluetooth = await _perms.bluetooth();
    final notifications = await _perms.notifications();
    state = state.copyWith(
      location: location,
      bluetooth: bluetooth,
      notifications: notifications,
    );
  }

  Future<void> askLocation() async =>
      state = state.copyWith(location: await _perms.requestLocation());

  Future<void> askBluetooth() async =>
      state = state.copyWith(bluetooth: await _perms.requestBluetooth());

  Future<void> askNotifications() async => state = state.copyWith(
    notifications: await _perms.requestNotifications(),
  );

  /// Cherche la soirée où l'on est. **Lit les vraies soirées autour** ; s'il
  /// n'y en a aucune (ou pas de position), c'est la démo.
  ///
  /// Le radar dure au moins [minRadar] : trouvé en 200 ms, il n'aurait pas eu
  /// le temps de dire ce qu'il fait — et le moment de la découverte est la
  /// moitié de l'effet.
  Future<void> findVenue({
    Duration minRadar = const Duration(milliseconds: 2600),
  }) async {
    state = state.copyWith(searching: true);
    final started = DateTime.now();
    var venue = ArrivalVenue.demo;
    try {
      final nearby = await ref.refresh(nearbyEventsProvider.future);
      final reachable = nearby.where((e) => e.withinReach).toList()
        ..sort((a, b) => a.distanceM.compareTo(b.distanceM));
      if (reachable.isNotEmpty) {
        venue = ArrivalVenue.fromNearby(reachable.first);
      }
    } catch (_) {
      // Pas de position, pas de réseau : la démo, qui le dit à l'écran.
    }
    final left = minRadar - DateTime.now().difference(started);
    if (left > Duration.zero) await Future<void>.delayed(left);
    state = state.copyWith(venue: venue, searching: false);
  }
}

final arrivalFlowProvider =
    NotifierProvider.autoDispose<ArrivalFlow, ArrivalState>(ArrivalFlow.new);

/// Le contenu simulé de la soirée de démonstration.
///
/// ⚠️ Ce ne sont **pas** de vraies personnes ni de vraies Vibes : des prénoms
/// et des légendes inventés, dessinés en dégradés — rien n'est lu en base.
abstract final class ArrivalDemo {
  static const presents = <String>[
    'Inès', 'Malo', 'Sacha', 'Nora', 'Léon', 'Jade', 'Yanis', 'Lou', //
    'Amir', 'Zoé', 'Tom', 'Maya',
  ];

  static const drop = <({String author, int minutes, String caption})>[
    (author: 'Inès', minutes: 2, caption: 'le DJ a lâché le morceau'),
    (author: 'Malo', minutes: 5, caption: 'défi réussi 🔥'),
    (author: 'Nora', minutes: 9, caption: 'la table du fond'),
    (author: 'Sacha', minutes: 14, caption: 'premier verre'),
    (author: 'Jade', minutes: 21, caption: 'photo floue validée'),
    (author: 'Yanis', minutes: 33, caption: 'ça commence'),
  ];

  static const challenges = <String>[
    'La photo la plus floue du bar',
    'Trinque avec un inconnu',
    'Le meilleur pas de danse',
  ];
}
