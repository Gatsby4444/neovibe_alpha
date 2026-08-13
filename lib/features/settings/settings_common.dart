import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Titre de groupe **à l'intérieur** d'un écran de réglages.
///
/// À ne pas confondre avec [SettingsCategoryTile], qui mène à un autre écran :
/// ici on reste sur place, il s'agit seulement de séparer deux sujets voisins.
class SettingsHeader extends StatelessWidget {
  const SettingsHeader(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(title, style: Theme.of(context).textTheme.titleMedium),
  );
}

/// Une **catégorie** de réglages : une porte vers un autre écran.
///
/// ### Pourquoi les réglages sont en dossiers
///
/// Jusqu'au 2026-08-13, tout tenait sur un seul écran de près de 300 lignes —
/// l'apparence, la caméra, la confidentialité et les outils de développement
/// se suivaient, séparés par de simples traits. Demande de Jay : « réorganise
/// les paramètres en plusieurs sections et sous-sections, pas tout mélangé
/// dans la même interface mais des dossiers et sous-dossiers ».
///
/// Le bénéfice n'est pas seulement visuel : un interrupteur de développement
/// perdu au milieu des réglages d'un utilisateur est un interrupteur qu'on
/// oublie de retirer avant la prod (`RAPPELS.md`, avant-prod #4).
class SettingsCategoryTile extends StatelessWidget {
  const SettingsCategoryTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.builder,
    this.dense = false,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final WidgetBuilder builder;
  final bool dense;

  @override
  Widget build(BuildContext context) => ListTile(
    dense: dense,
    leading: Icon(icon),
    title: Text(title),
    subtitle: Text(subtitle),
    trailing: const Icon(Icons.chevron_right),
    onTap: () =>
        Navigator.of(context).push(MaterialPageRoute(builder: builder)),
  );
}

/// Texte explicatif discret, sous un réglage ou en tête d'un groupe.
class SettingsNote extends StatelessWidget {
  const SettingsNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
    child: Text(
      text,
      style: Theme.of(
        context,
      ).textTheme.bodySmall?.copyWith(color: context.muted),
    ),
  );
}
