import 'package:flutter/material.dart';
import '../../core/theme.dart';

/// Onglet **Jeux** — emplacement réservé au chantier « quiz et mini-jeux entre
/// amis » (décidé par Jay le 2026-07-26, RAPPELS.md chantier #11).
///
/// L'onglet est créé AVANT son contenu, volontairement : la barre de
/// navigation est passée à cinq onglets le 2026-08-01 pour que les deux
/// chantiers décidés aient leur place dès maintenant, plutôt que de refaire la
/// navigation une deuxième fois quand ils arriveront.
///
/// Rappel des deux règles de conception à tenir quand ce chantier s'ouvrira :
/// 1. entre amis uniquement — pas d'inconnus, pas de classement mondial ;
/// 2. le jeu est un tremplin vers le réel, pas une fin en soi.
class PlayScreen extends StatelessWidget {
  const PlayScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Jeux')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.sports_esports_outlined,
                size: 64,
                color: context.ghost,
              ),
              const SizedBox(height: 20),
              const Text(
                'Bientôt ici',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              Text(
                'Quiz, mini-jeux et compatibilité — avec tes amis, et '
                'seulement eux.\nDe quoi passer un moment ensemble, et '
                'trouver une raison de se voir pour de vrai.',
                textAlign: TextAlign.center,
                style: TextStyle(color: context.muted, height: 1.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
