import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/models/event.dart';
import '../../core/supabase_providers.dart';
import '../auth/auth_repository.dart';
import '../events/events_providers.dart';
import '../profile/avatar_service.dart';
import '../profile/profile_repository.dart';
import 'arrival_permissions.dart';

/// **L'arrivée en soirée** — le parcours d'entrée dans NeoVibe (2026-09-24).
///
/// Né comme interface de test (Développeur › Outils), validé par Jay le même
/// jour et devenu **la vraie inscription** : *« l'UI de test est validée, on
/// l'implémente »*.
///
/// ## Deux modes, deux mémoires — jamais la même
///
/// | | [ArrivalMode.test] | [ArrivalMode.real] |
/// |---|---|---|
/// | ouvert par | Développeur › Outils | `RootGate` : pas de compte, ou pas de profil |
/// | écrit | **rien** | le compte, le profil, la photo |
/// | après les autorisations | radar et soirée **simulés** | la vraie app, puis le vrai radar (`EventFinderScreen`) |
///
/// Chaque mode a SA mémoire (`arrivalFlowProvider(mode)`) : un test lancé
/// depuis les réglages ne peut pas toucher à une inscription, ni l'inverse
/// (règle 2 : deux objets aux règles différentes ne partagent pas le même
/// rangement).
enum ArrivalMode { test, real }

enum ArrivalStep {
  /// L'accroche : « ce soir, ça se passe ici ».
  threshold,

  /// Le username (obligatoire, unique) et le pseudo (facultatif) —
  /// 2026-09-24 : c'était « le prénom » jusqu'à ce que Jay tranche.
  name,

  /// Le selfie, obligatoire — la photo de profil temporaire.
  selfie,

  /// Le compte (simulé dans le test ; sauté si on a déjà un compte).
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
    this.username = '',
    this.pseudo = '',
    this.selfie,
    this.location,
    this.bluetooth,
    this.notifications,
    this.venue,
    this.searching = false,
    this.active = false,
    this.hasAccount = false,
    this.busy = false,
    this.error,
  });

  final ArrivalStep step;

  /// Le username, déjà au format (`Username.normalize`).
  final String username;

  /// Le pseudo, facultatif ; vide = pas de pseudo.
  final String pseudo;

  /// Le nom par lequel l'accueillir : le pseudo s'il y en a un.
  String get greetingName => pseudo.isNotEmpty ? pseudo : username;

  /// Le selfie pris, ou `null`. **Obligatoire** pour passer l'étape.
  final File? selfie;

  /// `null` = pas encore lue.
  final ArrivalGrant? location;
  final ArrivalGrant? bluetooth;
  final ArrivalGrant? notifications;

  final ArrivalVenue? venue;
  final bool searching;

  /// **Mode réel** : une inscription est en cours. Tant que c'est vrai,
  /// `RootGate` garde ce parcours à l'écran, même quand le compte puis le
  /// profil apparaissent — sans ça, l'app basculerait vers l'accueil au milieu
  /// de l'inscription et les autorisations ne seraient jamais demandées.
  final bool active;

  /// On arrive déjà connecté (compte sans profil) : pas d'étape « compte ».
  final bool hasAccount;

  /// Une écriture est en cours (compte, profil, photo).
  final bool busy;

  /// Ce que le serveur a répondu de travers, en une phrase lisible.
  final String? error;

  String get initial =>
      greetingName.isEmpty ? '' : greetingName.characters.first.toUpperCase();

  ArrivalState copyWith({
    ArrivalStep? step,
    String? username,
    String? pseudo,
    File? selfie,
    bool clearSelfie = false,
    ArrivalGrant? location,
    ArrivalGrant? bluetooth,
    ArrivalGrant? notifications,
    ArrivalVenue? venue,
    bool? searching,
    bool? active,
    bool? hasAccount,
    bool? busy,
    String? error,
    bool clearError = false,
  }) => ArrivalState(
    step: step ?? this.step,
    username: username ?? this.username,
    pseudo: pseudo ?? this.pseudo,
    selfie: clearSelfie ? null : (selfie ?? this.selfie),
    location: location ?? this.location,
    bluetooth: bluetooth ?? this.bluetooth,
    notifications: notifications ?? this.notifications,
    venue: venue ?? this.venue,
    searching: searching ?? this.searching,
    active: active ?? this.active,
    hasAccount: hasAccount ?? this.hasAccount,
    busy: busy ?? this.busy,
    error: clearError ? null : (error ?? this.error),
  );
}

/// Le serveur du parcours : il enchaîne les étapes et demande à la cuisine
/// ([ArrivalPermissions], les soirées autour). **Il ne dessine rien.**
class ArrivalFlow extends Notifier<ArrivalState> {
  ArrivalFlow(this.mode);

  final ArrivalMode mode;

  bool get _real => mode == ArrivalMode.real;

  @override
  ArrivalState build() {
    // Le selfie est un fichier temporaire de la caméra : il ne survit pas au
    // parcours. Lu au moment de la fermeture, pas à la construction — c'est
    // le dernier pris qui compte.
    ref.onDispose(() => _discard(_selfie));
    return const ArrivalState();
  }

  /// Le profil a déjà été créé pendant ce passage : une nouvelle tentative
  /// (photo qui a échoué) ne doit pas le recréer.
  var _profileCreated = false;

  /// Le test repart de zéro à chaque ouverture (sa mémoire vit plus longtemps
  /// que l'écran : elle est partagée par mode, pas par écran).
  void startTest() {
    assert(!_real);
    reset();
  }

  /// Remet le parcours à son début et efface le selfie.
  void reset() {
    _discard(_selfie);
    _selfie = null;
    _profileCreated = false;
    state = const ArrivalState();
  }

  /// **Mode réel** : l'inscription commence. [hasAccount] : on est déjà
  /// connecté (compte sans profil) — on part du prénom, sans étape compte.
  void begin({required bool hasAccount}) {
    assert(_real);
    if (state.active) return;
    state = state.copyWith(
      active: true,
      hasAccount: hasAccount,
      step: ArrivalStep.name,
      clearError: true,
    );
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
  ///
  /// En mode réel, jamais non plus en deçà de ce qui est déjà écrit : une fois
  /// le compte et le profil créés (étape autorisations), revenir au selfie ou
  /// au compte n'aurait plus de sens. Et quand on arrive déjà connecté, le
  /// prénom est la première étape.
  bool back() {
    if (state.busy) return true;
    final i = state.step.index;
    if (i == 0 || state.step == ArrivalStep.inside) return false;
    if (_real) {
      if (state.step == ArrivalStep.permissions) return false;
      if (state.hasAccount && state.step == ArrivalStep.name) return false;
      if (state.step == ArrivalStep.name) {
        // Retour à l'accroche : l'inscription n'est plus en cours.
        state = state.copyWith(
          step: ArrivalStep.threshold,
          active: false,
          clearError: true,
        );
        return true;
      }
    }
    // La recherche se relance d'elle-même : on revient aux autorisations.
    goTo(ArrivalStep.values[i - 1]);
    return true;
  }

  // ─── Mode réel : les écritures ─────────────────────────────────────────

  /// « Je garde » sur le selfie. Déjà connecté : le profil se crée maintenant.
  /// Sinon, direction le compte.
  Future<void> keepSelfie() async {
    if (!_real) {
      goTo(ArrivalStep.account);
      return;
    }
    if (!state.hasAccount) {
      goTo(ArrivalStep.account);
      return;
    }
    await _write(() async {
      await _createProfile();
      state = state.copyWith(step: ArrivalStep.permissions);
    });
  }

  /// Crée le compte, puis le profil (prénom + selfie). **Le serveur borne les
  /// comptes par téléphone** (`hook_before_user_created`) : son refus devient
  /// [ArrivalState.error].
  Future<void> createAccount({
    required String email,
    required String password,
  }) async {
    if (!_real) {
      state = state.copyWith(busy: true);
      // Le test n'écrit rien : le temps d'un vrai aller-retour, pour sentir
      // le rythme.
      await Future<void>.delayed(const Duration(milliseconds: 700));
      state = state.copyWith(busy: false, step: ArrivalStep.permissions);
      return;
    }
    await _write(() async {
      final outcome = await ref
          .read(authRepositoryProvider)
          .signUp(email: email, password: password);
      if (outcome == SignUpOutcome.mustConfirmEmail) {
        throw const _Readable(
          'Compte créé, mais le serveur demande de confirmer le mail. '
          'Confirme-le, puis connecte-toi.',
        );
      }
      // Le compte existe désormais : si le profil échoue (prénom déjà pris),
      // on ne repasse PAS par l'inscription — elle répondrait « déjà
      // inscrit ». Le selfie gardé créera le profil (voir [keepSelfie]).
      state = state.copyWith(hasAccount: true);
      await _createProfile();
      state = state.copyWith(step: ArrivalStep.permissions);
    });
  }

  /// Le profil : le prénom, puis le selfie comme **photo de profil
  /// temporaire** (Jay, 2026-09-24). Même ordre que l'ancien écran : la ligne
  /// d'abord, la photo ensuite (`AvatarService.upload` met à jour la ligne).
  Future<void> _createProfile() async {
    final userId = ref.read(supabaseProvider).auth.currentUser?.id;
    if (userId == null) throw const _Readable('Pas de session ouverte.');
    if (!_profileCreated) {
      await ref
          .read(profileRepositoryProvider)
          .create(
            userId: userId,
            displayName: state.username,
            tagName: state.pseudo,
          );
      _profileCreated = true;
    }
    final selfie = state.selfie;
    if (selfie != null) {
      final avatars = ref.read(avatarServiceProvider);
      await avatars.upload(await avatars.squareFromPhoto(selfie));
    }
    ref.invalidate(myProfileProvider);
  }

  /// **Mode réel** : fin du parcours. `RootGate` reprend la main (l'accueil),
  /// et le vrai radar s'ouvre par-dessus ([arrivalWantsFinderProvider]).
  void finish() {
    assert(_real);
    ref.read(arrivalWantsFinderProvider.notifier).request();
    reset();
  }

  Future<void> _write(Future<void> Function() body) async {
    state = state.copyWith(busy: true, clearError: true);
    try {
      await body();
      state = state.copyWith(busy: false);
    } catch (e) {
      // ⚠️ **Le nom affiché est UNIQUE dans NeoVibe** (index
      // `profiles_username_unique` sur `lower(display_name)`, relevé en base
      // le 2026-09-24). Avec un prénom, c'est fréquent : on renvoie au prénom,
      // compte et selfie conservés.
      if ('$e'.contains('profiles_username_unique')) {
        state = state.copyWith(
          busy: false,
          step: ArrivalStep.name,
          error:
              '« @${state.username} » est déjà pris. Essaie par exemple '
              '« ${_suggestion(state.username)} ».',
        );
        return;
      }
      state = state.copyWith(busy: false, error: _readable(e));
    }
  }

  static String _readable(Object e) {
    if (e is _Readable) return e.message;
    if (e is AuthException) {
      final m = e.message.toLowerCase();
      if (m.contains('already registered') || m.contains('already exists')) {
        return 'Ce mail a déjà un compte : connecte-toi.';
      }
      if (m.contains('password')) {
        return 'Mot de passe refusé : 6 caractères au moins.';
      }
      // Les refus du plafond par téléphone arrivent déjà en français.
      return e.message;
    }
    return 'Ça n\'a pas marché : $e';
  }

  void setUsername(String value) =>
      state = state.copyWith(username: value.trim(), clearError: true);

  void setPseudo(String value) =>
      state = state.copyWith(pseudo: value.trim(), clearError: true);

  /// Une proposition quand le username est pris : le même, suivi d'un
  /// chiffre, dans la limite de 20 caractères. (Le serveur dira s'il est
  /// libre : on ne peut pas le vérifier avant d'avoir un compte.)
  static String _suggestion(String taken) {
    final base = taken.length > 19 ? taken.substring(0, 19) : taken;
    return '${base}2';
  }

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

/// **Une mémoire par mode** (voir [ArrivalMode]). Pas d'`autoDispose` : en
/// mode réel, le parcours doit survivre aux reconstructions de `RootGate`
/// (le compte, puis le profil, apparaissent pendant l'inscription).
final arrivalFlowProvider =
    NotifierProvider.family<ArrivalFlow, ArrivalState, ArrivalMode>(
      ArrivalFlow.new,
    );

/// Le parcours réel vient de se terminer : ouvrir le vrai radar par-dessus
/// l'accueil, une fois. Lu et remis à zéro par `RootGate`.
class ArrivalWantsFinder extends Notifier<bool> {
  @override
  bool build() => false;

  void request() => state = true;

  /// Rend vrai une seule fois.
  bool take() {
    if (!state) return false;
    state = false;
    return true;
  }
}

final arrivalWantsFinderProvider = NotifierProvider<ArrivalWantsFinder, bool>(
  ArrivalWantsFinder.new,
);

/// Une erreur dont le message est déjà écrit pour Jay.
class _Readable implements Exception {
  const _Readable(this.message);
  final String message;
}

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
