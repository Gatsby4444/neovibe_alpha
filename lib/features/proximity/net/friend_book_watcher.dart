import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../cards/cards_repository.dart';
import '../../connections/connections_repository.dart';
import 'proximity_sync.dart';

/// **La règle unique : quand le graphe d'amis change, tout ce qui en dépend
/// suit.**
///
/// ## 🔴 Le défaut du 2026-08-28, et pourquoi il ne pouvait pas être vu
///
/// Le carnet local porte les clés publiques sans lesquelles un ami n'est **ni
/// reconnu, ni émis** en Bluetooth. Il ne se remplit qu'à la demande. Or les
/// **sept** appels qui le remplissaient étaient tous accrochés à une **écriture
/// locale** : accepter, retirer, bloquer, débloquer, démarrer le ping.
///
/// ⚠️ **Une amitié change sur DEUX appareils et ne s'écrit que sur UN.** Celui
/// qui a *envoyé* la demande n'avait donc aucun déclencheur au moment où elle
/// était acceptée.
///
/// Relevé en base ce jour-là : mimi envoie la demande à 12:21:43, Charles
/// accepte à 12:21:47, et à 12:36 le compteur `synchros du carnet réussies` de
/// mimi vaut toujours **0**. Deux constats de croisement côté Charles, **zéro**
/// côté mimi, **aucune ligne dans `encounters`** — un croisement exige les deux.
/// Rejoué sous son identité (`set local role authenticated`), le serveur lui
/// rendait bien la clé de Charles : **l'app n'avait jamais posé la question.**
///
/// ⚠️ **Et l'état se verrouillait tout seul.** Le seul déclencheur restant — le
/// balayage de constats — n'appelle la synchro que **s'il y a des constats**, et
/// il n'y en a pas sans carnet. Carnet vide → pas de constat → pas de synchro →
/// carnet vide. Seul un redémarrage de l'app en sortait : le contournement que
/// Jay avait trouvé seul (*« j'ai désactivé et réactivé le ping et là ça
/// remarche »*).
///
/// ## Ce qui remplace les sept appels
///
/// | Rôle | Qui | Ce qu'il fait |
/// |---|---|---|
/// | **l'écriture** | `accept`, `remove`, `block`… | dit « la vérité a changé, relis-la » |
/// | **la règle** | ce fichier | voit l'ENSEMBLE des amis changer, et agit |
///
/// C'est la règle de `CLAUDE.md` appliquée sans exception : *un chemin, une
/// donnée*. Chaque écriture tenait auparavant **sa propre liste** de ce qu'il
/// fallait rafraîchir — et les trois listes n'étaient pas les mêmes. C'est
/// exactement ce qui a laissé le compteur d'amis figé après un retrait alors
/// qu'il était corrigé pour le blocage la veille.
///
/// ## ⚠️ Pourquoi un filet périodique EN PLUS des événements
///
/// Le graphe arrive en temps réel — sauf les **suppressions**. Une ligne
/// `connections` effacée n'est pas toujours diffusée par le temps réel Postgres
/// (constaté le 2026-08-27, déjà noté dans `moderation.dart`), parce que la RLS
/// n'a pas de quoi s'évaluer sur un enregistrement supprimé.
///
/// Or `block_user` **supprime** la connexion : sans filet, celui qui se fait
/// bloquer garderait l'autre dans son carnet jusqu'au prochain lancement.
///
/// C'est le modèle de tout le monde — *pousser pour la vitesse, tirer pour la
/// justesse*. Les événements donnent la seconde ; le filet garantit qu'on
/// converge même quand un événement s'est perdu.
///
/// ⚠️ **Ce n'est PAS le retour du sondage supprimé le même jour.** Celui-là
/// tournait toutes les **2 secondes** en croyant réagir à quelque chose. Celui-ci
/// est nommé, dimensionné, et coûte deux requêtes par quart d'heure.
///
/// ## ⚠️ Ce qui reste protégé même quand le carnet est en retard
///
/// Un secret par paire ne se dérive qu'avec les **deux** clés. Celui qui bloque
/// écrit sur SON appareil : son carnet perd l'autre immédiatement, donc il cesse
/// aussitôt d'émettre le jeton de la paire. L'autre, même avec un carnet périmé,
/// n'a **plus rien à entendre** — il continue seulement de crier un jeton que
/// personne n'écoute. Le retard coûte de la radio, jamais de la vie privée.
class FriendBookWatcher extends Notifier<Set<String>> {
  /// Cadence du filet. Un quart d'heure : le créneau des jetons, et deux
  /// requêtes toutes les quinze minutes — huit par heure.
  static const filet = Duration(minutes: 15);

  Timer? _minuteur;

  /// L'ensemble déjà pris en compte. `null` tant qu'on n'a rien vu.
  ///
  /// ⚠️ Sert à distinguer **le premier passage** (l'app démarre : il faut tirer
  /// le carnet, mais aucun cache n'est encore périmé) d'un **changement** (il
  /// faut aussi refaire les vues qui comptent les amis).
  Set<String>? _connu;

  @override
  Set<String> build() {
    // ⚠️ `friendIdsProvider` est un `DerivedSet` : il ne réveille ses lecteurs
    // que si l'ENSEMBLE change réellement. Un ami qui change d'avatar ne
    // déclenche donc aucune synchronisation.
    final amis = ref.watch(friendIdsProvider);

    ref.onDispose(() {
      _minuteur?.cancel();
      _minuteur = null;
    });
    _minuteur ??= Timer.periodic(filet, (_) => _rattrapage());

    final premier = _connu == null;
    _connu = amis;
    Future.microtask(() => _leGrapheABouge(premier: premier));
    return amis;
  }

  /// ⚠️ **L'invalidation appartient à la RÈGLE, plus à chaque appelant.**
  ///
  /// Le compteur d'amis du profil vient de `profileStatsProvider`, un
  /// `FutureProvider` **mis en cache** que seul le chemin du blocage
  /// invalidait. Retirer un ami mettait donc la liste à jour et laissait le
  /// compteur figé jusqu'au redémarrage de l'app — signalé par mimi le
  /// 2026-08-28, un jour après la correction du même défaut sur l'autre chemin.
  void _leGrapheABouge({required bool premier}) {
    unawaited(ref.read(proximitySyncProvider).pullFriendBook());
    // Rien n'est encore en cache au tout premier passage : l'invalider ne ferait
    // qu'une requête de plus au lancement.
    if (!premier) ref.invalidate(profileStatsProvider);
  }

  /// Le filet : on redemande la vérité, au cas où un événement se serait perdu.
  ///
  /// ⚠️ **Il relit la SOURCE, il ne se contente pas de retirer le carnet.** Si
  /// la suppression n'a pas été diffusée, `friendIdsProvider` croit encore
  /// l'ancienne composition — et tirer le carnet ne corrigerait que la moitié
  /// visible par le Bluetooth, en laissant l'écran mentir.
  ///
  /// Il vide aussi la file d'envoi : c'est le seul moment où un constat resté
  /// coincé faute de réseau retrouve une occasion de partir.
  void _rattrapage() {
    ref.invalidate(connectionsStreamProvider);
    unawaited(ref.read(proximitySyncProvider).pullFriendBook());
    unawaited(ref.read(proximitySyncProvider).pushOutbox());
  }
}

/// ⚠️ **À garder vivant pour toute la session** — voir `app.dart`.
///
/// Un provider Riverpod ne calcule rien tant que personne ne l'observe. Cette
/// règle-ci n'a pas d'écran : si aucun lecteur ne la tient, elle n'existe pas,
/// et le défaut du 2026-08-28 revient **sans qu'aucun test ne tombe**.
final friendBookWatcherProvider =
    NotifierProvider<FriendBookWatcher, Set<String>>(FriendBookWatcher.new);
