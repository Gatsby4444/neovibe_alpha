import 'peer_session.dart';

/// **Une présence passée : avec quelqu'un, de quand à quand.**
///
/// ⚠️ **Ce n'est PAS une « connexion ».** Depuis le 2026-08-27 les téléphones
/// ne se connectent plus — le Bluetooth ne fait que prouver la proximité. Une
/// présence commence quand on entend l'autre et se termine
/// [PresenceRules.forgetAfter] après qu'on cesse de l'entendre.
///
/// ⚠️ **Conséquence à garder en tête pour toute règle posée dessus** : ces
/// 30 secondes de tolérance décident des BORNES de l'objet. Deux amis qui
/// s'éloignent 25 s font **une** présence ; 35 s, **deux**. Un seuil plus court
/// que la tolérance (les 20 s du presque) mesure donc un objet dont il ne
/// contrôle pas le découpage — arbitrage assumé avec Jay le 2026-08-30.
class Presence {
  const Presence({required this.debut, required this.fin});

  final DateTime debut;
  final DateTime fin;

  Duration get duree => fin.difference(debut);

  /// Cette présence recouvre-t-elle un morceau de `[a, b]` ?
  bool chevauche(DateTime a, DateTime b) => fin.isAfter(a) && debut.isBefore(b);

  @override
  bool operator ==(Object other) =>
      other is Presence && other.debut == debut && other.fin == fin;

  @override
  int get hashCode => Object.hash(debut, fin);

  @override
  String toString() =>
      'Presence(${debut.toIso8601String()} -> ${fin.toIso8601String()}, '
      '${duree.inSeconds}s)';
}

/// **Les deux jugements du croisement manqué, et rien d'autre.**
///
/// ## 🔴 Le défaut que ces règles suppriment — raisonnement de Jay, 2026-08-30
///
/// > *« il peut y avoir plein de cas où deux utilisateurs sont ensemble puis se
/// > séparent temporairement etc… mais ils passent un vrai moment ensemble. Et
/// > si on ne prend pas cela en compte, wave devient un spam incessant de
/// > proximité. »*
///
/// La règle d'avant ne regardait **qu'une présence isolée** : elle ne pouvait
/// donc pas faire la différence entre *« on s'est ratés »* et *« on s'est
/// quittés cinq minutes »*. Un presque est un jugement sur **une demi-journée**,
/// pas sur un instant.
///
/// ## Deux notifications, deux questions, deux jugements INDÉPENDANTS
///
/// | | Question | Quand on peut répondre |
/// |---|---|---|
/// | **« ton ami est tout près »** | *est-il là, alors qu'on ne s'est pas vus ?* | **tout de suite** |
/// | **« le presque »** | *vous êtes-vous vraiment ratés ?* | **une heure après** |
///
/// ⚠️ **Indépendants — décidé par Jay le 2026-08-30.** L'un n'est pas la
/// promotion de l'autre : un presque peut partir sans que « tout près » soit
/// parti. Le cas exact qui les sépare — trois minutes ensemble il y a une
/// demi-heure, puis dix secondes de croisement : « tout près » est bloqué (plus
/// de 2 min dans l'heure), le presque passe (3 min < 5 min sur 2 h). Les traiter
/// comme un seul jugement à deux étages aurait fait disparaître ce cas sans que
/// rien ne le signale.
///
/// ## ⚠️ Classe PURE
///
/// Aucun réseau, aucun disque, aucune horloge, aucun Riverpod : on lui donne un
/// historique et un contact, elle répond. C'est ce qui rend les deux jeux de
/// conditions éprouvables **sans Bluetooth**, avec des heures fabriquées — ce
/// qui manquait totalement à la version précédente, dont la règle vivait à
/// moitié dans le contrôleur et n'était couverte par aucun test.
abstract final class WaveRules {
  // ------------------------------------------------------------------
  // Le presque
  // ------------------------------------------------------------------

  /// Au-delà, le contact n'est plus un « on s'est ratés ».
  static const contactBref = Duration(seconds: 20);

  /// Fenêtre regardée **avant** le contact, et le temps qui la disqualifie.
  static const avantFenetre = Duration(hours: 2);
  static const avantSeuil = Duration(minutes: 5);

  /// Fenêtre regardée **après** le contact, et le temps qui la disqualifie.
  ///
  /// ⚠️ **C'est elle qui rend le presque forcément tardif** : on ne peut pas
  /// savoir avant qu'elle soit écoulée. Le presque arrive donc au plus tôt une
  /// heure après le croisement — et c'est la raison pour laquelle le délai de
  /// palier a déménagé sur « ton ami est tout près » (décision de Jay,
  /// 2026-08-30). Un délai de 45 minutes posé sur une notification déjà en
  /// retard d'une heure ne se serait jamais vu.
  static const apresFenetre = Duration(hours: 1);
  static const apresSeuil = Duration(minutes: 2);

  // ------------------------------------------------------------------
  // « Ton ami est tout près »
  // ------------------------------------------------------------------

  /// Fenêtre regardée avant, et le temps qui la disqualifie.
  ///
  /// ⚠️ **L'asymétrie avec le presque est VOULUE** (confirmée par Jay le
  /// 2026-08-30) : on tolère d'avoir vu quelqu'un quatre minutes il y a une
  /// heure, mais pas trois minutes dans l'heure qui suit. Ce qui se passe
  /// **après** prouve mieux qu'on ne s'est pas ratés.
  static const presFenetre = Duration(hours: 1);
  static const presSeuil = Duration(minutes: 2);

  /// Le contact a-t-il été assez long pour dire *« il est tout près »* ?
  ///
  /// ⚠️ **C'est une borne PAR LE BAS, et le presque n'en avait aucune.** Sa
  /// règle des 20 secondes borne le haut ; sans celle-ci, un seul paquet capté
  /// par erreur — et on sait depuis le 2026-08-29 que la radio hoquette —
  /// suffirait à notifier « ton ami est tout près » toutes les heures.
  ///
  /// ⚠️ **Ce n'est PAS un nouveau réglage** : c'est [PresenceRules.minSightings],
  /// la définition déjà écrite de « ce n'est pas un passant ». En poser un
  /// second aurait fait deux définitions du même mot.
  static int get presDetectionsMin => PresenceRules.minSightings;

  // ------------------------------------------------------------------
  // Les deux jugements
  // ------------------------------------------------------------------

  /// *« Ton ami est tout près »* — répondu **à la fin du contact**.
  ///
  /// [historique] : les présences avec CETTE personne, **sans** [contact].
  /// [detections] : combien de fois la radio l'a entendu pendant [contact].
  static bool toutPres({
    required Iterable<Presence> historique,
    required Presence contact,
    required int detections,
  }) {
    if (detections < presDetectionsMin) return false;
    return !_presenceLongue(
      historique,
      depuis: contact.debut.subtract(presFenetre),
      jusqua: contact.debut,
      seuil: presSeuil,
    );
  }

  /// *« Le presque »* — répondu **[apresFenetre] après la fin du contact**.
  ///
  /// ⚠️ **Ne l'appeler que quand [verdictPret] est vrai.** Appelée trop tôt,
  /// elle répondrait « oui » à un contact que la demi-heure suivante va
  /// démentir — et elle ne peut pas le savoir, puisque l'historique de cette
  /// demi-heure n'existe pas encore. Une règle pure ne peut pas se protéger
  /// d'un appelant pressé : c'est à l'appelant de tenir le calendrier.
  static bool wave({
    required Iterable<Presence> historique,
    required Presence contact,
  }) {
    if (contact.duree >= contactBref) return false;
    if (_presenceLongue(
      historique,
      depuis: contact.debut.subtract(avantFenetre),
      jusqua: contact.debut,
      seuil: avantSeuil,
    )) {
      return false;
    }
    return !_presenceLongue(
      historique,
      depuis: contact.fin,
      jusqua: contact.fin.add(apresFenetre),
      seuil: apresSeuil,
    );
  }

  /// L'heure d'après est-elle écoulée ? Voir [wave].
  static bool verdictPret(Presence contact, DateTime maintenant) =>
      !maintenant.isBefore(contact.fin.add(apresFenetre));

  /// Combien de temps garder une présence en mémoire.
  ///
  /// La fenêtre d'avant plus celle d'après : **une seule définition de « assez
  /// vieux pour être oublié »**, sinon le journal taillerait dans ce que la
  /// règle doit encore pouvoir lire, et le presque deviendrait faux sans que
  /// rien ne lève.
  static Duration get memoire => avantFenetre + apresFenetre;

  /// Y a-t-il eu une présence de plus de [seuil] qui touche `[depuis, jusqua]` ?
  ///
  /// ⚠️ **Elle « touche », elle n'est pas « contenue ».** Une présence d'une
  /// heure qui déborde de la fenêtre compte quand même : la question posée est
  /// *« avons-nous passé du temps ensemble dans cette période »*, et une
  /// présence à cheval y répond oui.
  static bool _presenceLongue(
    Iterable<Presence> historique, {
    required DateTime depuis,
    required DateTime jusqua,
    required Duration seuil,
  }) => historique.any((p) => p.duree > seuil && p.chevauche(depuis, jusqua));
}
