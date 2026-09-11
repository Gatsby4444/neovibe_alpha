import '../../core/models/card.dart';

/// Ce que le sélecteur AFFICHE, et ce que la caméra SERT réellement.
///
/// Les deux ne sont pas la même chose et ne changent pas au même moment : le
/// sélecteur suit le doigt, la caméra ne se reconfigure qu'une fois le
/// sélecteur **posé** (le `PageView` émet un changement pour chaque type
/// traversé — voir `_onTypeChanged`). D'où deux valeurs distinctes, et cette
/// classe pour les tenir ensemble.
///
/// 🔴 **Pourquoi [servi] est nullable, et pourquoi il ne doit JAMAIS recevoir
/// de valeur de départ.** `null` ne veut pas dire « type standard », il veut
/// dire **« la caméra n'a encore reçu aucune consigne »**. C'est un état réel,
/// qui dure de l'ouverture de l'écran jusqu'au premier changement de type, et
/// il doit s'énoncer positivement — sinon la comparaison « c'est déjà ce que
/// je sers » est vraie alors que rien n'a jamais été servi.
///
/// **C'est exactement le défaut trouvé le 2026-09-11** (`RAPPELS.md` #125).
/// L'écran de capture portait :
///
/// ```dart
/// late CardType _type       = widget.bereal ? bereal : standard;
/// late CardType _cameraType = _type;   // ⚠️
/// ```
///
/// Un champ `late` avec initialiseur n'est PAS évalué à la construction : il
/// l'est au **premier accès**. Et le premier accès à `_cameraType` avait lieu
/// dans la comparaison elle-même — donc **après** que le doigt de Jay avait
/// déjà fait passer `_type` à `oneshot`. `_cameraType` naissait ainsi égal à
/// `oneshot`, la comparaison sortait « rien à faire », et **le double live
/// n'était jamais demandé au premier passage**. Il fallait sortir du Oneshot
/// et y revenir pour que la caméra soit enfin prévenue.
///
/// Symptôme vu par Jay : le Oneshot s'ouvrait en vue simple, sans même l'écran
/// « Ouverture du double live… » — et le journal ne montrait rien, puisque
/// aucune demande n'était partie.
class CaptureTypeState {
  /// [affiche] : le type sur lequel le selecteur s'ouvre.
  CaptureTypeState.ouvertSur(this._affiche);

  CardType _affiche;
  CardType? _servi;

  /// Le type que le sélecteur montre en ce moment.
  CardType get affiche => _affiche;

  /// Le type que la caméra sert. `null` tant qu'elle n'a rien reçu.
  CardType? get servi => _servi;

  /// Le sélecteur s'est déplacé. Ne touche pas à la caméra.
  void poser(CardType type) => _affiche = type;

  /// Le sélecteur est posé : la caméra doit-elle être reconfigurée ?
  ///
  /// Rend `null` s'il n'y a rien à faire, sinon le type à servir et celui qui
  /// l'était avant (`precedent` vaut `null` au tout premier changement — la
  /// caméra ne sortait alors d'aucun mode).
  ///
  /// ⚠️ **Marque le type comme servi immédiatement**, avant que la caméra ne
  /// soit réellement reconfigurée : l'ouverture d'un double flux prend ~1,5 s
  /// et le sélecteur peut bouger pendant ce temps. C'est [realigner] qui
  /// rattrape ce cas à la fin de l'ouverture.
  ({CardType nouveau, CardType? precedent})? aAppliquer() {
    if (_affiche == _servi) return null;
    final precedent = _servi;
    _servi = _affiche;
    return (nouveau: _affiche, precedent: precedent);
  }

  /// Après une reconfiguration longue : le sélecteur a-t-il bougé entre-temps ?
  ///
  /// Rend `true` si ce qui est servi ne correspond plus à ce qui est affiché —
  /// l'appelant doit alors refermer ce qu'il vient d'ouvrir.
  bool realigner() {
    if (_affiche == _servi) return false;
    _servi = _affiche;
    return true;
  }
}
