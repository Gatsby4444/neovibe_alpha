import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_log.dart';

/// Capte **tous les échecs de providers**.
///
/// C'est le gros du travail fait gratuitement : dans cette app, presque chaque
/// appel serveur passe par un `FutureProvider` ou un `StreamProvider`. Une
/// erreur réseau, un refus de RLS, une exception de RPC — tout remonte ici sans
/// qu'il faille toucher au moindre appel.
/// `final` parce que `ProviderObserver` est `base` en Riverpod 3 : la
/// hiérarchie doit rester close.
final class AppLogProviderObserver extends ProviderObserver {
  const AppLogProviderObserver();

  @override
  void providerDidFail(
    ProviderObserverContext context,
    Object error,
    StackTrace stackTrace,
  ) {
    final name =
        context.provider.name ?? context.provider.runtimeType.toString();
    AppLog.instance.error('Provider en échec : $name', _short(error));
  }

  /// Un message d'erreur Supabase tient en une ligne ; une pile en fait
  /// cinquante et noie le journal. On garde la première ligne, qui porte le
  /// message utile, et on borne la longueur.
  static String _short(Object error) {
    final text = error.toString().split('\n').first.trim();
    return text.length > 300 ? '${text.substring(0, 300)}…' : text;
  }
}

/// Capte le **parcours de l'utilisateur** : chaque écran ouvert et refermé.
///
/// Sans cela, une erreur dans le journal n'a pas de contexte — on voit le
/// symptôme sans savoir d'où l'utilisateur venait.
class AppLogNavigatorObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    AppLog.instance.action('Écran ouvert : ${_name(route)}');
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    AppLog.instance.action(
      'Écran fermé : ${_name(route)}',
      previousRoute == null ? null : 'retour vers ${_name(previousRoute)}',
    );
  }

  /// Les écrans sont poussés en `MaterialPageRoute` sans nom : on affiche le
  /// type du widget construit, qui est bien plus parlant qu'un « / » anonyme.
  static String _name(Route<dynamic> route) {
    final settingsName = route.settings.name;
    if (settingsName != null && settingsName.isNotEmpty) return settingsName;
    if (route is MaterialPageRoute) {
      try {
        return route.builder(route.navigator!.context).runtimeType.toString();
      } catch (_) {
        // Construire le widget hors de son cycle de vie peut lever : le nom
        // n'est qu'un confort, il ne doit rien casser.
      }
    }
    return route.runtimeType.toString();
  }
}
