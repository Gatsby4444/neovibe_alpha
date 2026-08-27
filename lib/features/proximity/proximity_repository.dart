import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/connection_request.dart';
import '../../core/clock.dart';
import '../../core/derived_list.dart';
import '../../core/supabase_providers.dart';

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

// ⚠️ **`liveOutgoingRequestsProvider` a été SUPPRIMÉ le 2026-08-27**, avec le
// battement de cœur qui était son unique lecteur — et encore, par un `ref.read`,
// donc sans même s'y abonner.
//
// Ce que l'interface a besoin de savoir d'une demande sortante, c'est **son
// état pour UNE personne**, pas la liste entière : c'est [etatDemandeProvider],
// juste en dessous. Garder les deux aurait fait deux vues dérivées de la même
// source, avec deux définitions de « encore valide » à tenir d'accord.

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

/// Répondre à une demande de connexion. **Il ne reste que ça.**
///
/// ## ⚠️ Le battement de cœur a été SUPPRIMÉ le 2026-08-27 — décision de Jay
///
/// Un minuteur de 30 secondes réécrivait `expires_at = now() + 90 s` pour toute
/// demande sortante dont le destinataire était à portée. Son commentaire disait
/// *« on prolonge »* : il **raccourcissait**, de sept jours à une minute et
/// demie, dans les trente secondes suivant l'envoi.
///
/// ⚠️ **Et il ne masquait pas — il détruisait.** Le cron `neovibe_purge` passe
/// toutes les cinq minutes et fait basculer en `expired` toute demande `pending`
/// dont l'échéance est passée. Une demande était donc **perdue définitivement**
/// 90 secondes après que les deux personnes se soient séparées.
///
/// ⚠️ **La prémisse était morte, pas la règle.** « La demande expire à la sortie
/// de portée » (spec 4.2) était juste tant qu'il fallait **être à portée pour
/// répondre** — la réponse voyageait dans le canal BLE co-signé. Répondre est
/// maintenant un appel serveur : on accepte de n'importe où, n'importe quand.
///
/// ⚠️ **La barrière de présence physique n'est pas affaiblie** : elle est
/// vérifiée **à l'émission** par `request_connection_from_proximity`, qui exige
/// une paire mutuelle de moins de dix minutes. Ce qui a changé n'est pas qui
/// peut demander, c'est le temps laissé pour répondre.
class ProximityRepository {
  const ProximityRepository(this.ref);

  final Ref ref;

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
