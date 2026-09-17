import 'package:flutter/material.dart';

import '../../core/models/profile.dart';
import 'user_library_screen.dart';

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
void openProfile(BuildContext context, Profile profile) {
  Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => UserLibraryScreen(profile: profile)),
  );
}
