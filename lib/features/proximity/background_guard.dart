import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// **Ce que le téléphone accorde à l'app pour vivre en arrière-plan.**
///
/// ## Pourquoi ce fichier existe : l'après-midi du 2026-09-21
///
/// Le carnet du service radio montre le service mort à ~13:45, sur batterie,
/// sans relance ni réveil jusqu'à 21:41. Les captures de Jay du lendemain
/// disent pourquoi : sur son Xiaomi, l'économiseur de batterie était sur
/// « recommandé » et le démarrage automatique désactivé — MIUI tue alors
/// l'app comme un « forcer l'arrêt », et rien ne peut la relancer.
///
/// Aucune ligne de code ne change ces réglages à la place de l'utilisateur.
/// Ce fichier **constate** ce qui est lisible et **emmène** au bon endroit ;
/// la vue décide quand déranger (`background_guard_screen.dart`).
///
/// Pont natif : `android/.../BackgroundGuard.kt`, canal
/// `neovibe/background_guard`.
class BackgroundGuardState {
  const BackgroundGuardState({
    required this.manufacturer,
    required this.model,
    required this.batteryExempt,
    required this.autostartPage,
    required this.batterySaverPage,
  });

  /// Le fabricant, tel qu'Android le donne (`Build.MANUFACTURER`).
  final String manufacturer;
  final String model;

  /// Vrai si l'app est exemptée de l'optimisation de batterie — **lisible**
  /// (`PowerManager.isIgnoringBatteryOptimizations`). Sur MIUI, c'est le même
  /// interrupteur que « Pas de restriction ».
  final bool batteryExempt;

  /// La page MIUI « Démarrage automatique » existe sur cet appareil.
  ///
  /// ⚠️ Son **état** n'est pas lisible (aucune API publique) : on peut
  /// l'ouvrir et le dire, pas le vérifier.
  final bool autostartPage;

  /// La page MIUI « Économiseur de batterie » de l'app existe.
  final bool batterySaverPage;

  /// Un constructeur qui pose ses propres gardiens au-dessus d'Android.
  bool get miui => autostartPage || batterySaverPage;

  /// Tout ce qui est **lisible** est en ordre.
  bool get ok => batteryExempt;

  static const inconnu = BackgroundGuardState(
    manufacturer: '?',
    model: '?',
    batteryExempt: true,
    autostartPage: false,
    batterySaverPage: false,
  );

  @override
  bool operator ==(Object other) =>
      other is BackgroundGuardState &&
      other.manufacturer == manufacturer &&
      other.model == model &&
      other.batteryExempt == batteryExempt &&
      other.autostartPage == autostartPage &&
      other.batterySaverPage == batterySaverPage;

  @override
  int get hashCode => Object.hash(
    manufacturer,
    model,
    batteryExempt,
    autostartPage,
    batterySaverPage,
  );
}

/// L'acquisition. **Publie ce qu'elle constate, ne décide de rien.**
class BackgroundGuard {
  const BackgroundGuard();

  static const _channel = MethodChannel('neovibe/background_guard');

  /// Les faits. ⚠️ En cas d'échec du canal (autre plateforme, pont absent),
  /// on répond « tout va bien » : un doute ne doit pas se transformer en
  /// reproche permanent à l'utilisateur (même règle que `CoarseLocation`).
  Future<BackgroundGuardState> state() async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('state');
      if (m == null) return BackgroundGuardState.inconnu;
      return BackgroundGuardState(
        manufacturer: m['manufacturer'] as String? ?? '?',
        model: m['model'] as String? ?? '?',
        batteryExempt: m['batteryExempt'] as bool? ?? true,
        autostartPage: m['autostartPage'] as bool? ?? false,
        batterySaverPage: m['batterySaverPage'] as bool? ?? false,
      );
    } catch (_) {
      return BackgroundGuardState.inconnu;
    }
  }

  /// La boîte de dialogue standard d'Android. Rend vrai si elle s'est ouverte
  /// (ou si l'exemption est déjà accordée).
  Future<bool> requestBatteryExemption() => _bool('requestBatteryExemption');

  Future<bool> openAutostart() => _bool('openAutostart');

  Future<bool> openBatterySaver() => _bool('openBatterySaver');

  Future<bool> openAppDetails() => _bool('openAppDetails');

  Future<bool> _bool(String method) async {
    try {
      return await _channel.invokeMethod<bool>(method) ?? false;
    } catch (_) {
      return false;
    }
  }
}

/// L'état, relu à la demande (`ref.invalidate`) — après un retour des
/// réglages, l'utilisateur a peut-être changé quelque chose.
final backgroundGuardProvider = FutureProvider<BackgroundGuardState>(
  (ref) => const BackgroundGuard().state(),
);
