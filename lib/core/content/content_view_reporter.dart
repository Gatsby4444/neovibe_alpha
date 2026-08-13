import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../supabase_providers.dart';

/// Déclare au serveur qu'un contenu a été **réellement regardé**.
///
/// ### Pourquoi ce n'est plus le serveur qui décide
///
/// Jusqu'au 2026-08-13, `open_content_media` enregistrait la vue **en rendant
/// la clé**. Précharger un contenu — donc aller chercher sa clé d'avance —
/// aurait inscrit au journal de propagation des contenus que personne n'a
/// regardés. Or on ne peut pas se permettre de données faussées.
///
/// Décision de Jay : séparer les deux, et déclarer la vue **après un temps
/// d'affichage réel**.
///
/// > « quand le client regarde disons 3 s le contenu, alors il envoie au
/// > serveur qu'il l'a vu. »
///
/// ### Ce que ce choix coûte, assumé
///
/// L'enregistrement dépend désormais du client. Un client modifié pourrait ne
/// rien déclarer. C'est acceptable **ici et seulement ici** : un contenu du
/// socle n'a aucun budget de vues, donc **aucune promesse faite à son auteur
/// n'en dépend**. `content_views` est un journal de propagation, pas une
/// garantie.
///
/// ⚠️ **Rien de tout cela ne vaut pour les Vibes en DM** : leur décompte reste
/// indissociable de la remise de la clé, côté serveur, dans une transaction
/// unique.
///
/// ### Pourquoi un seuil, et pourquoi côté client
///
/// Sans seuil, faire défiler un feed enregistrerait une vue par contenu
/// traversé — le journal deviendrait un compteur de défilement. Le seuil est
/// une notion d'**interface** (« regarder »), pas une règle de sécurité : le
/// serveur ne peut de toute façon pas observer ce qui est à l'écran.
class ContentViewReporter {
  ContentViewReporter(this._ref);

  final Ref _ref;

  /// Le temps d'affichage au-delà duquel on considère que le contenu a été
  /// regardé (consigne de Jay).
  static const threshold = Duration(seconds: 3);

  /// Contenus déjà déclarés pendant cette session, pour ne pas répéter l'appel
  /// à chaque réaffichage. Le serveur est de toute façon idempotent par couple
  /// (contenu, spectateur) — c'est un confort réseau, pas une règle.
  final _reported = <String>{};

  final _timers = <String, Timer>{};

  /// Le contenu [contentId] est à l'écran. Au bout de [threshold], la vue part.
  void watching(String contentId) {
    if (_reported.contains(contentId) || _timers.containsKey(contentId)) return;
    _timers[contentId] = Timer(threshold, () {
      _timers.remove(contentId);
      _report(contentId);
    });
  }

  /// Le contenu a quitté l'écran avant le seuil : ce n'était pas un
  /// visionnage. C'est ce qui distingue « regarder » de « faire défiler ».
  void stopped(String contentId) {
    _timers.remove(contentId)?.cancel();
  }

  Future<void> _report(String contentId) async {
    if (!_reported.add(contentId)) return;
    try {
      await _ref
          .read(supabaseProvider)
          .rpc('record_content_view', params: {'p_content_id': contentId});
    } catch (_) {
      // Un journal qui échoue ne doit jamais faire tomber un écran. On
      // réautorise simplement une tentative ultérieure.
      _reported.remove(contentId);
    }
  }

  void dispose() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
  }

  /// À la déconnexion : la session suivante n'hérite pas de ces déclarations.
  void clear() {
    dispose();
    _reported.clear();
  }
}

final contentViewReporterProvider = Provider<ContentViewReporter>((ref) {
  final reporter = ContentViewReporter(ref);
  ref.onDispose(reporter.dispose);
  return reporter;
});
