import 'package:flutter/material.dart';

import '../../core/models/profile.dart';
import 'user_library_screen.dart';

/// Les profils actuellement **dans la pile**. Il ne sert qu'à [openProfile]
/// et se tient tout seul : une route retirée se retire d'ici, quelle qu'en
/// soit la raison — la flèche, le bouton retour d'Android, un geste.
final _ouverts = <String>{};

/// **Le seul chemin vers le profil de quelqu'un.**
///
/// Il était écrit neuf fois, à l'identique, dans neuf écrans — la story, le
/// chat, le ping, la liste d'amis, la constellation, le fil, le plein écran…
/// Neuf copies, c'est neuf endroits à retrouver le jour où ouvrir un profil
/// demandera autre chose (une garde, une trace, un écran différent selon le
/// palier d'amitié). Ici, c'est un.
///
/// Jay, 2026-09-17 : *« de manière générale, rends cliquables l'username et
/// la pp pour rediriger vers la page profil »* — « de manière générale » veut
/// dire : partout où une personne est **nommée**, pas seulement là où on y a
/// pensé.
/// ### ⚠️ Un profil n'est jamais empilé deux fois
///
/// Jay, 2026-09-17 : *« le bouton retour me fait revenir sur toutes mes
/// actions une par une comme pour les sites web […] alors qu'il aurait
/// simplement dû me faire retourner sur ma page profil »*.
///
/// Ce qu'il décrit est une pile qui enfle : depuis le profil de quelqu'un on
/// ouvre son fil, une Vibe, on revient, on touche son pseudo — et **le même
/// profil s'empile une deuxième fois**, puis une troisième. Le retour les
/// dépile ensuite un par un, en redonnant à voir des écrans qu'on croyait
/// fermés : chaque aller-retour laissait une trace, et la trace se rejouait.
///
/// Ici, un profil déjà ouvert n'est pas rouvert : **on redescend jusqu'à
/// lui**. La pile ne peut donc plus contenir deux fois la même personne.
void openProfile(BuildContext context, Profile profile) {
  final nom = 'profil/${profile.id}';
  final navigator = Navigator.of(context);

  if (_ouverts.contains(profile.id)) {
    // La garde `isFirst` évite de vider la pile au cas — improbable — où le
    // registre se serait désaccordé de la réalité.
    navigator.popUntil((r) => r.settings.name == nom || r.isFirst);
    return;
  }

  _ouverts.add(profile.id);
  navigator
      .push(
        MaterialPageRoute<void>(
          settings: RouteSettings(name: nom),
          builder: (_) => UserLibraryScreen(profile: profile),
        ),
      )
      .whenComplete(() => _ouverts.remove(profile.id));
}
