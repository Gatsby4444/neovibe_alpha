/// Où en est la navigation principale : l'onglet **visé** et l'onglet
/// **affiché**.
///
/// ## Pourquoi cet objet existe
///
/// La bascule d'une section à l'autre s'anime : la sortante s'efface, puis
/// l'entrante arrive. Pendant ce temps, la barre de navigation désigne déjà la
/// destination alors que l'écran montre encore l'origine. **Il faut donc bien
/// deux valeurs**, et c'est normal.
///
/// 🔴 **Ce qui ne l'est pas, c'est de pouvoir en changer une sans l'autre.**
/// Constaté chez Jay le 2026-08-29, sur téléphone ET sur tablette : l'onglet de
/// démarrage réglé sur « Profil » posait la barre sur Profil et laissait
/// l'écran sur le Cercle — la préférence écrivait la valeur visée, et rien ne
/// recalait l'affichage parce qu'aucune animation ne tournait. Le glissement
/// suivant partait alors de Profil (donc vers Jeux) tandis que l'écran montrait
/// le Cercle.
///
/// L'ancien code portait ces deux valeurs dans deux champs libres du `State`.
/// **Un seul des trois chemins qui posent une section les tenait ensemble.**
/// Ici, il n'y a plus de champ à écrire : il y a trois gestes nommés, et chacun
/// dit ce qu'il fait des deux valeurs.
///
/// ⚠️ **Ce défaut ne lève aucune erreur** — les deux valeurs restent des
/// entiers valides, l'écran s'affiche, rien ne plante. Il ne se voit qu'en
/// comparant les deux. C'est ce que fait `test/section_cursor_test.dart`.
class SectionCursor {
  SectionCursor(int depart) : _vise = depart, _affiche = depart;

  int _vise;
  int _affiche;

  /// Ce que la **barre de navigation** désigne, et le point de départ du
  /// prochain glissement.
  int get vise => _vise;

  /// Ce que l'**écran** montre.
  int get affiche => _affiche;

  /// Vrai pendant une bascule, entre le départ et le relais.
  bool get enTransit => _vise != _affiche;

  /// **Poser** une section sans animation — au lancement, ou quand il n'y a
  /// rien à faire glisser. Les deux valeurs bougent ensemble.
  void poser(int section) {
    _vise = section;
    _affiche = section;
  }

  /// **Viser** une section : la barre y va tout de suite, l'écran suivra.
  ///
  /// Renvoie `false` si l'on y est déjà — l'appelant n'a alors aucune
  /// animation à lancer.
  bool viser(int section) {
    if (section == _vise) return false;
    _vise = section;
    return true;
  }

  /// Le **relais**, au creux de la bascule : l'écran rattrape la barre.
  ///
  /// Renvoie `false` s'il n'y avait rien à rattraper, pour éviter une
  /// reconstruction inutile.
  bool relayer() {
    if (_affiche == _vise) return false;
    _affiche = _vise;
    return true;
  }
}
