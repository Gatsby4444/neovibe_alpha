import 'dart:io';

import '../../../core/content/saved_store.dart';
import '../../../core/models/card.dart';
import '../../../core/utils/ids.dart';

/// Ce qui sort de la capture et entre dans l'envoi.
///
/// **Immuable.** Aucun écran de paramétrage ne le modifie : la prise est faite,
/// elle ne se renégocie pas. Ce qui se choisit ensuite (destination, limites,
/// partage) appartient à l'écran de cette destination et n'a aucune raison de
/// remonter ici.
///
/// C'est le découpage demandé par Jay le 2026-08-14 : l'écran d'envoi unique
/// mélangeait la prise, le choix de la destination et les réglages des quatre
/// destinations dans un seul `build`. Une brouille suffisait à faire fuiter un
/// réglage d'un contexte vers un autre — un `_shareable` resté à vrai après un
/// passage par « Story » repartait avec une publication.
class VibeDraft {
  VibeDraft({
    required this.front,
    required this.back,
    required this.type,
    required this.imported,
    required this.frontIsVideo,
    required this.backIsVideo,
    this.directRecipientIds,
    this.directRecipientLabel,
    String? localId,
  }) : localId = localId ?? newLocalId();

  final File front;

  /// Null = Vibe à face unique (verso passé à la prise).
  final File? back;

  /// Type issu de la capture (`standard`, `oneshot` ou `bereal`). Il peut
  /// devenir `oneOfOne` **à l'envoi seulement**, et seulement dans le cercle.
  final CardType type;

  /// Au moins une face vient de la galerie.
  final bool imported;

  /// Faces vidéo : la durée de visionnage ne s'applique qu'aux faces photo ;
  /// une face vidéo se lit en entier (consigne Jay 2026-07-12).
  final bool frontIsVideo;
  final bool backIsVideo;

  /// **Envoi direct depuis un chat** (consigne Jay 2026-08-01). Quand elle est
  /// fournie, la destination est imposée : on saute l'étape du choix de format
  /// et on entre directement dans le paramétrage du cercle.
  ///
  /// Liste et non identifiant unique : dans un groupe, « le destinataire du
  /// chat » désigne tous les autres membres.
  final List<String>? directRecipientIds;
  final String? directRecipientLabel;

  /// Identifiant **local**, tiré dès la capture.
  ///
  /// Il existe pour une raison précise : « Enregistrer pour moi » est devenu un
  /// bouton qui agit **tout de suite** (consigne Jay 2026-08-14), donc avant
  /// l'envoi — et donc avant qu'un Content ID serveur n'existe. Sans clé
  /// stable, deux clics produiraient deux copies, et « déjà sauvegardée » ne
  /// pourrait même pas se dire.
  ///
  /// Il est remplacé par le vrai Content ID une fois l'envoi réussi
  /// (`SavedStore.rekey`) : sans quoi une copie de mon propre contenu
  /// échapperait à la révocation de modération, qui interroge le serveur par
  /// identifiant.
  final String localId;

  bool get direct => directRecipientIds != null;

  bool get hasVideo => frontIsVideo || backIsVideo;

  /// Au moins une face photo : la limite de durée de visionnage garde un sens
  /// (les faces vidéo se lisent en entier).
  bool get hasPhoto => !frontIsVideo || (back != null && !backIsVideo);

  /// Le préfixe `local-` n'est pas décoratif : il **dit** que cet identifiant
  /// ne désigne rien côté serveur, et c'est sur lui que `SavedStore` s'appuie
  /// pour ne pas aller demander au serveur si un contenu qui n'existe pas chez
  /// lui a été révoqué (voir `SavedStore.purgeRevoked`). Une règle qui s'énonce
  /// positivement — « cet identifiant est local » — plutôt qu'un UUID nu,
  /// impossible à distinguer d'un vrai Content ID.
  ///
  /// ⚠️ **À tirer une fois par prise, pas une fois par écran.** Le récap
  /// reconstruit un `VibeDraft` à chaque appui sur « Continuer » (les faces ont
  /// pu être retouchées entre-temps) ; s'il en tirait un identifiant neuf à
  /// chaque fois, partir puis revenir donnerait DEUX identités à la même prise,
  /// et « Enregistrer pour moi » pourrait en écrire deux copies sans jamais
  /// pouvoir dire « déjà sauvegardée ». C'est pourquoi il se passe en
  /// paramètre.
  static String newLocalId() => '$localIdPrefix${newUuid()}';
}
