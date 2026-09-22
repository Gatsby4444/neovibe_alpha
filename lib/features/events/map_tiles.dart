import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';

/// **Le fond de carte, et les bornes de zoom.** Un seul endroit.
///
/// ## 🔴 Ce que les captures de Jay du 2026-09-22 montraient
///
/// Quatre défauts, tous dans `events_map_screen.dart` :
///
/// | Ce qu'on voyait | La cause |
/// |---|---|
/// | une carte **claire et chargée** (numéros de rue, pharmacies, hôtels) dans une app sombre | le style par défaut d'`openstreetmap.org`, fait pour une carte de référence, pas pour un fond |
/// | tout **flou** | les tuiles font 256 px et l'écran en affiche ~3 par point : on étirait une image trop petite |
/// | des **motifs géants** (un chemin pointillé devenu une file de ronds) | on pouvait zoomer **au-delà** du dernier niveau de tuile : le moteur agrandissait la dernière image |
/// | du **gris vide** | encore plus loin : plus aucune tuile n'existe à ce niveau |
///
/// ## 🔴 Et le correctif du matin en a créé un cinquième
///
/// Ce fichier est passé par les basemaps CARTO, décrites ici comme
/// « gratuites sans clé ». **C'était faux, et je ne l'avais pas vérifié** :
/// chaque tuile est revenue tamponnée `API KEY REQUIRED` (capture de Jay,
/// 14:30). Une affirmation non vérifiée sur un service extérieur se paie au
/// premier écran.
///
/// ➡️ **On revient donc à OpenStreetMap**, dont on a la preuve qu'il répond
/// (la carte fonctionnait avant), et **on fait le sombre nous-mêmes** : le
/// fond est inversé puis sa teinte tournée de 180° (`darkModeTileBuilder`),
/// ce qui rend un fond sombre sans changer de fournisseur.
///
/// ⚠️ **Ce que ça ne corrige PAS** : le style reste celui de la carte de
/// référence, donc bavard. Une carte vraiment épurée demande un fournisseur
/// **avec clé et contrat** — c'est `RAPPELS.md` #157, et c'est la même
/// décision que le fond de production.
class MapTiles {
  const MapTiles._();

  /// Le dernier niveau de tuile qui existe chez OpenStreetMap.
  static const maxNativeZoom = 19;

  /// Le zoom maximum de la **caméra**.
  ///
  /// ⚠️ **Un de moins que les tuiles, et ce n'est pas une marge de
  /// prudence.** En mode rétine simulé, la couche demande le niveau
  /// **au-dessus** de celui affiché : à la caméra 18, elle télécharge les
  /// tuiles du 19. Autoriser la caméra à 19 lui ferait demander le 20, qui
  /// n'existe pas — donc réétirer la dernière image, c'est-à-dire refaire
  /// exactement le défaut qu'on corrige.
  static const maxZoom = 18.0;

  /// Assez large pour voir un pays, pas le monde entier : en dessous, la carte
  /// se répète et le doigt se perd.
  static const minZoom = 4.0;

  /// Le zoom d'arrivée : la rue et ce qu'il y a autour.
  static const initialZoom = 16.0;

  /// La couche de tuiles, prête à poser.
  ///
  /// [dark] : la carte suit le thème de l'app. Une carte claire dans une app
  /// sombre, la nuit, éblouit — et c'est ce que montrait la capture de 21:43.
  static TileLayer layer(BuildContext context, {required bool dark}) =>
      TileLayer(
        urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
        // La politique d'OpenStreetMap l'exige : une application identifiable.
        userAgentPackageName: 'com.neovibe.neovibe',
        // ⚠️ **Le flou se corrige ICI.** OpenStreetMap ne sert pas de tuiles
        // @2x ; `flutter_map` compense en demandant le niveau au-dessus et en
        // le dessinant sur la même surface — deux fois plus de points pour la
        // même rue. Voir [maxZoom] pour le décalage que ça impose.
        //
        // ⚠️ Le prix : **quatre fois plus de tuiles** téléchargées. Acceptable
        // pour un appareil de test, à revoir avec le fond de production (#157).
        retinaMode: RetinaMode.isHighDensity(context),
        maxNativeZoom: maxNativeZoom,
        // Le fond sombre, fait chez nous : inversion + rotation de teinte de
        // 180°. C'est la recette classique, et elle vit dans `flutter_map`.
        tileBuilder: dark ? darkModeTileBuilder : null,
      );
}
