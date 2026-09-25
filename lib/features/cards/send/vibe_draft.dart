import 'dart:io';

import '../../../core/content/saved_store.dart';
import '../../../core/location/anchor.dart';
import '../../../core/location/capture_places.dart';
import '../../../core/models/card.dart';
import '../../../core/utils/ids.dart';

/// **D'où vient une face** (2026-09-25).
///
/// Le Drop n'accepte que des faces prises à la caméra (Jay, 2026-08-10 :
/// « le but est de prendre de vraies photos ou vidéos »). Jusqu'ici l'app ne
/// retenait que « importée ou non » : un **fond uni** passait pour une vraie
/// photo, et la caméra principale le laissait entrer dans un Drop. Trois
/// origines, trois valeurs — le serveur reçoit la conclusion
/// (`p_camera_only`), l'écran la règle correspondante.
enum FaceOrigin {
  camera,
  gallery,

  /// Un fond uni ou dégradé composé dans l'app.
  color,
}

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
    required this.frontOrigin,
    this.backOrigin = FaceOrigin.camera,
    required this.frontIsVideo,
    required this.backIsVideo,
    this.anchor,
    DateTime? takenAt,
    String? localId,
  }) : localId = localId ?? newLocalId(),
       takenAt = takenAt ?? DateTime.now();

  /// Où la prise a été faite, gommée à 100 m ([ContentAnchor]) ; nulle si la
  /// position n'était pas disponible. Publiée SEULEMENT si l'utilisateur
  /// coche « Localiser » dans les réglages de la bibliothèque.
  final ContentAnchor? anchor;

  /// L'heure de la prise (la première face), pour la galerie (2026-09-25).
  final DateTime takenAt;

  /// Quand et où — ce que chaque objet né de cette prise note dans le
  /// journal privé des lieux ([CapturePlaces]).
  CaptureStamp get stamp => CaptureStamp(takenAt: takenAt, anchor: anchor);

  final File front;

  /// Null = Vibe à face unique (verso passé à la prise).
  final File? back;

  /// Type issu de la capture (`standard`, `oneshot` ou `bereal`). Il peut
  /// devenir `oneOfOne` **à l'envoi seulement**, et seulement dans le cercle.
  final CardType type;

  /// D'où viennent les faces. [backOrigin] n'a de sens que s'il y a un verso.
  final FaceOrigin frontOrigin;
  final FaceOrigin backOrigin;

  /// Au moins une face vient de la galerie.
  bool get imported =>
      frontOrigin == FaceOrigin.gallery ||
      (back != null && backOrigin == FaceOrigin.gallery);

  /// Toutes les faces viennent de la caméra — la condition d'entrée d'un Drop.
  bool get cameraOnly =>
      frontOrigin == FaceOrigin.camera &&
      (back == null || backOrigin == FaceOrigin.camera);

  /// Faces vidéo : la durée de visionnage ne s'applique qu'aux faces photo ;
  /// une face vidéo se lit en entier (consigne Jay 2026-07-12).
  final bool frontIsVideo;
  final bool backIsVideo;

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

  /// La même prise, sous un autre type — **à l'envoi seulement** : c'est
  /// ainsi qu'une Vibe devient 1/1 (un seul destinataire, aucune publication).
  /// Même identifiant local : la copie « Enregistrer pour moi » déjà faite
  /// reste retrouvable.
  VibeDraft withType(CardType type) => VibeDraft(
    front: front,
    back: back,
    type: type,
    frontOrigin: frontOrigin,
    backOrigin: backOrigin,
    frontIsVideo: frontIsVideo,
    backIsVideo: backIsVideo,
    anchor: anchor,
    takenAt: takenAt,
    localId: localId,
  );

  bool get hasVideo => frontIsVideo || backIsVideo;

  /// Au moins une face photo : la limite de durée de visionnage garde un sens
  /// (les faces vidéo se lisent en entier).
  bool get hasPhoto => !frontIsVideo || (back != null && !backIsVideo);

  /// La durée de lecture a-t-elle un sens pour cette Vibe ?
  ///
  /// Une face **photo** d'une Vibe standard : oui. Un **Oneshot** : jamais
  /// (Jay, 2026-09-14) — *un instant vu des deux côtés*, sa valeur est dans
  /// le retournement, pas dans le chrono ; ses seules limites sont le nombre
  /// d'ouvertures et, s'il est filmé, la barre de lecture. Les faces vidéo
  /// n'en ont jamais eu (2026-07-12). Un seul endroit décide, pour la roue
  /// ⚙︎ **et** pour l'envoi : deux avis divergents auraient laissé un
  /// curseur qui ne règle rien, ou une durée envoyée sans curseur.
  bool get acceptsDuration => acceptsViewDuration(type, hasPhoto: hasPhoto);

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
