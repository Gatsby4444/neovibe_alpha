import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';

/// **Le fond de carte, et les bornes de zoom.** Un seul endroit.
///
/// ## 🔴 Ce que les captures de Jay du 2026-09-22 montraient
///
/// Quatre défauts distincts, tous dans `events_map_screen.dart` :
///
/// | Ce qu'on voyait | La cause |
/// |---|---|
/// | une carte **claire et chargée** (numéros de rue, pharmacies, hôtels) dans une app sombre et épurée | le style par défaut d'`openstreetmap.org`, fait pour une carte de référence, pas pour un fond |
/// | tout **flou** | les tuiles font 256 px et l'écran en affiche ~3 par point : on étirait une image trop petite |
/// | des **motifs géants** (un chemin pointillé devenu une file de ronds) | on pouvait zoomer **au-delà** du dernier niveau de tuile : le moteur agrandissait la dernière image |
/// | du **gris vide** | encore plus loin : plus aucune tuile n'existe à ce niveau |
///
/// ## Ce qu'on fait à la place, sans rien payer
///
/// Le fond vient des **basemaps CARTO** (données OpenStreetMap), en deux
/// variantes — claire et sombre — choisies selon le thème de l'app. Ce style
/// est fait pour être un **fond** : peu d'étiquettes, couleurs sourdes, et il
/// existe en **@2x** (tuiles de 512 px), ce qui supprime le flou sur un écran
/// dense.
///
/// ⚠️ **Toujours pas un fond de production** (RAPPELS #157, inchangé) : c'est
/// un service gratuit sans clé, toléré à faible volume. Il faudra un
/// fournisseur avec contrat (ou nos propres tuiles) avant la mise en ligne.
/// L'attribution des deux — OpenStreetMap **et** CARTO — est obligatoire et
/// affichée par l'écran.
class MapTiles {
  const MapTiles._();

  /// Le dernier niveau où des tuiles existent vraiment.
  ///
  /// ⚠️ **C'est la borne qui manquait.** Sans elle, `flutter_map` laisse
  /// zoomer indéfiniment et **agrandit** la dernière image disponible : la
  /// carte devient floue, puis absurde, puis vide — sans la moindre erreur, et
  /// sans que rien ne dise à l'utilisateur qu'il est allé trop loin.
  static const maxZoom = 19.0;

  /// Assez large pour voir un pays, pas le monde entier : en dessous, la carte
  /// se répète et le doigt se perd.
  static const minZoom = 4.0;

  /// Le zoom d'arrivée : la rue et ce qu'il y a autour.
  static const initialZoom = 16.0;

  static String _url(bool dark) =>
      'https://{s}.basemaps.cartocdn.com/rastertiles/'
      '${dark ? 'dark_all' : 'light_all'}/{z}/{x}/{y}{r}.png';

  /// La couche de tuiles, prête à poser.
  ///
  /// [dark] : la carte suit le thème de l'app. Une carte claire dans une app
  /// sombre, la nuit, éblouit — et c'est exactement ce que montrait la capture
  /// de 21:43.
  static TileLayer layer(BuildContext context, {required bool dark}) =>
      TileLayer(
        urlTemplate: _url(dark),
        subdomains: const ['a', 'b', 'c'],
        userAgentPackageName: 'com.neovibe.neovibe',
        // ⚠️ **Le flou se corrige ICI, pas dans le style.** En mode rétine, la
        // couche demande la tuile du niveau au-dessus, en 512 px (`{r}` vaut
        // alors `@2x`), et la dessine sur la même surface : deux fois plus de
        // points pour la même rue.
        retinaMode: RetinaMode.isHighDensity(context),
        maxNativeZoom: maxZoom.toInt(),
      );
}
