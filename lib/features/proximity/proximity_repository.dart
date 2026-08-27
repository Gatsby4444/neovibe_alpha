import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/connection_request.dart';
import '../../core/clock.dart';
import '../../core/derived_list.dart';
import '../../core/supabase_providers.dart';
import 'nearby_people.dart';

/// Les demandes de connexion, **et il n'y a plus qu'un seul endroit où elles
/// vivent** : la table `connection_requests`.
///
/// ⚠️ **Ce commentaire affirmait le contraire jusqu'au 2026-08-27** — « les
/// demandes de proximité passent d'appareil à appareil (co-signées) [...] ce
/// canal serveur ne sert plus qu'aux recommandations A→B→C ». C'était vrai
/// depuis le 2026-07-13 ; ça a cessé de l'être quand le transport BLE a été
/// supprimé et que `request_connection_from_proximity` est devenu le seul
/// chemin. Un commentaire périmé est indiscernable d'un commentaire juste.

/// Demandes de connexion reçues, en attente et non expirées (temps réel).
final incomingRequestsProvider = StreamProvider<List<ConnectionRequest>>((ref) {
  // ⚠️ Fait repartir l'abonnement quand le jeton temps réel est renouvelé.
  // Sans ça, le socket garde le jeton avec lequel il s'est ouvert et tombe
  // au bout d'une heure — sans le moindre symptôme (2026-08-17).
  ref.watch(realtimeEpochProvider);
  final client = ref.watch(supabaseProvider);
  final me = ref.watch(currentUserIdProvider);
  if (me == null) return const Stream.empty();
  return client
      .from('connection_requests')
      .stream(primaryKey: ['id'])
      .eq('receiver_id', me)
      // ⚠️ **Ne filtre plus sur `isActive`** (2026-08-25, checkup #52) :
      // `isActive` dépend de `DateTime.now()`, donc de l'HEURE, une source que
      // ce flux n'observe pas. Une demande expirée restait affichée jusqu'à ce
      // qu'un événement sans rapport passe. La péremption est appliquée en aval,
      // adossée à l'horloge.
      .map(
        (rows) => rows.map(ConnectionRequest.fromJson).toList(growable: false),
      );
});

/// Mes demandes sortantes en attente (pour l'état des boutons + heartbeat).
final outgoingRequestsProvider = StreamProvider<List<ConnectionRequest>>((ref) {
  // ⚠️ Fait repartir l'abonnement quand le jeton temps réel est renouvelé.
  // Sans ça, le socket garde le jeton avec lequel il s'est ouvert et tombe
  // au bout d'une heure — sans le moindre symptôme (2026-08-17).
  ref.watch(realtimeEpochProvider);
  final client = ref.watch(supabaseProvider);
  final me = ref.watch(currentUserIdProvider);
  if (me == null) return const Stream.empty();
  return client
      .from('connection_requests')
      .stream(primaryKey: ['id'])
      .eq('sender_id', me)
      // ⚠️ **Ne filtre plus sur `isActive`** (2026-08-25, checkup #52) :
      // `isActive` dépend de `DateTime.now()`, donc de l'HEURE, une source que
      // ce flux n'observe pas. Une demande expirée restait affichée jusqu'à ce
      // qu'un événement sans rapport passe. La péremption est appliquée en aval,
      // adossée à l'horloge.
      .map(
        (rows) => rows.map(ConnectionRequest.fromJson).toList(growable: false),
      );
});

// ---------------------------------------------------------------------------
// L'USAGE — les demandes ENCORE VALIDES, à l'heure qu'il est
// ---------------------------------------------------------------------------

/// Les demandes reçues encore en attente **maintenant**.
class _LiveIncoming extends Notifier<List<ConnectionRequest>>
    with DerivedList<ConnectionRequest> {
  @override
  List<ConnectionRequest> build() {
    final now = ref.watch(expiryClockProvider);
    return (ref.watch(incomingRequestsProvider).value ?? const [])
        .where(
          (r) => r.status == RequestStatus.pending && r.expiresAt.isAfter(now),
        )
        .toList(growable: false);
  }
}

final liveIncomingRequestsProvider =
    NotifierProvider<_LiveIncoming, List<ConnectionRequest>>(_LiveIncoming.new);

/// Mes demandes sortantes encore en attente **maintenant**.
class _LiveOutgoing extends Notifier<List<ConnectionRequest>>
    with DerivedList<ConnectionRequest> {
  @override
  List<ConnectionRequest> build() {
    final now = ref.watch(expiryClockProvider);
    return (ref.watch(outgoingRequestsProvider).value ?? const [])
        .where(
          (r) => r.status == RequestStatus.pending && r.expiresAt.isAfter(now),
        )
        .toList(growable: false);
  }
}

final liveOutgoingRequestsProvider =
    NotifierProvider<_LiveOutgoing, List<ConnectionRequest>>(_LiveOutgoing.new);

// ---------------------------------------------------------------------------
// L'état d'UNE demande, pour UNE tuile
// ---------------------------------------------------------------------------

/// Où en est **ma** demande vers quelqu'un, du point de vue de l'interface.
///
/// ⚠️ **Trois états, et pas la ligne elle-même.** C'est délibéré, et c'est la
/// même règle que `PeerView` : *ce qu'on compare doit être ce que l'œil voit*.
/// Rendre le `ConnectionRequest` ferait reconstruire la tuile à chaque battement
/// de cœur du dépôt, qui réécrit `expires_at` toutes les 30 secondes — pour un
/// bouton qui n'aurait pas bougé d'un pixel.
enum EtatDemande {
  /// Rien de parti. Le bouton propose de demander.
  aucune,

  /// Partie, en attente de réponse.
  envoyee,

  /// La personne a dit non. On peut redemander — le serveur l'autorise
  /// explicitement (`request_connection_from_proximity` ne cherche qu'une
  /// demande `pending`, vérifié en base le 2026-08-27).
  declinee,
}

/// L'état de ma demande vers [userId] — **et rien d'autre**.
///
/// ## Pourquoi ce provider existe : le défaut du 2026-08-17, deux fois
///
/// Jay a cliqué plusieurs fois sur « demander » et lu « Demande envoyée » à
/// chaque fois : l'app ne gardait aucune trace de ce qu'elle venait de faire.
/// La réponse d'alors fut un **journal local** de demandes sortantes — qui n'a
/// jamais eu de sens que parce qu'une demande voyageait d'appareil à appareil,
/// sans ligne serveur. Ce journal est parti avec le transport BLE le
/// 2026-08-27, et le défaut est revenu à l'identique.
///
/// ⚠️ **La bonne réponse n'était pas de refaire le journal.** Une demande est
/// une ligne de `connection_requests` : c'est le serveur qui s'en souvient, et
/// deux mémoires d'un même fait finissent toujours par se contredire — c'est
/// l'écran qui affiche alors quelque chose que le serveur dément.
///
/// ⚠️ **Aucune requête nouvelle.** Cette vue se dérive du flux temps réel qui
/// existait déjà ; un second chemin vers la même donnée, c'est deux caches et un
/// désaccord futur que rien ne signalerait.
final etatDemandeProvider = Provider.family<EtatDemande, String>((ref, userId) {
  // ⚠️ Le temps est une SOURCE : une demande périmée cesse d'être « envoyée »
  // au moment exact où elle expire, pas au prochain événement sans rapport.
  final now = ref.watch(expiryClockProvider);
  final toutes =
      ref.watch(outgoingRequestsProvider).value ?? const <ConnectionRequest>[];

  var declinee = false;
  for (final r in toutes) {
    if (r.receiverId != userId) continue;
    // Une demande vivante l'emporte sur un ancien refus : on a redemandé.
    if (r.status == RequestStatus.pending && r.expiresAt.isAfter(now)) {
      return EtatDemande.envoyee;
    }
    if (r.status == RequestStatus.declined) declinee = true;
  }
  return declinee ? EtatDemande.declinee : EtatDemande.aucune;
});

class ProximityRepository {
  ProximityRepository(this.ref) {
    // Heartbeat : tant que le destinataire d'une demande sortante reste en
    // portée BLE, on prolonge expires_at. Sortie de portée → la demande
    // expire d'elle-même (spec 4.2 : pas de connexion en attente indéfinie).
    _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) => _refresh());
    ref.onDispose(() => _heartbeat.cancel());
  }

  final Ref ref;
  late final Timer _heartbeat;

  Future<void> _refresh() async {
    final nearby = ref.read(nearbyUserIdsProvider);
    // Le battement de cœur ne prolonge que des demandes ENCORE valides.
    final outgoing = ref.read(liveOutgoingRequestsProvider);
    final client = ref.read(supabaseProvider);
    for (final request in outgoing) {
      final inRange = nearby.contains(request.receiverId);
      if (inRange) {
        await client
            .from('connection_requests')
            .update({
              'expires_at': DateTime.now()
                  .add(const Duration(seconds: 90))
                  .toUtc()
                  .toIso8601String(),
            })
            .eq('id', request.id);
      }
    }
  }

  // ⚠️ `sendRequest` a été supprimée le 2026-08-16 : plus aucun appelant.
  //
  // ⚠️ **Elle n'est pas revenue, et c'est voulu.** Une demande de proximité
  // part par `PingRepository.requestConnection`, qui appelle
  // `request_connection_from_proximity` — la fonction qui **vérifie la
  // barrière** (paire mutuelle fraîche de moins de 10 minutes). Une insertion
  // directe dans `connection_requests` la contournerait, et la politique
  // `requests_insert_sender` l'autorise encore : voir `RAPPELS.md` #70.
  // **Ne pas rouvrir ce chemin ici.**

  Future<void> accept(String requestId) => ref
      .read(supabaseProvider)
      .rpc('accept_connection_request', params: {'req_id': requestId});

  Future<void> decline(String requestId) => ref
      .read(supabaseProvider)
      .rpc('decline_connection_request', params: {'req_id': requestId});
}

final proximityRepositoryProvider = Provider((ref) => ProximityRepository(ref));
