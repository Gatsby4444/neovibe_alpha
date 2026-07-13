import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Préférences locales à l'appareil (UI uniquement — rien de social ici).

/// Sens du retournement des Cards au swipe (consigne Jay : le sens naturel
/// varie selon les personnes, donc paramétrable). false = sens par défaut.
class FlipDirectionInverted extends Notifier<bool> {
  static const _key = 'flip_direction_inverted';

  @override
  bool build() {
    _load();
    return false;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool(_key) ?? false;
  }

  Future<void> set(bool value) async {
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, value);
  }
}

final flipDirectionInvertedProvider =
    NotifierProvider<FlipDirectionInverted, bool>(FlipDirectionInverted.new);

/// Nombre de vues appliqué par défaut aux nouvelles Cards (1-5, consigne : 2).
class DefaultMaxViews extends Notifier<int> {
  static const _key = 'default_max_views';

  @override
  int build() {
    _load();
    return 2;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getInt(_key) ?? 2;
  }

  Future<void> set(int value) async {
    state = value.clamp(1, 5);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_key, state);
  }
}

final defaultMaxViewsProvider = NotifierProvider<DefaultMaxViews, int>(
  DefaultMaxViews.new,
);

/// Durée de lecture appliquée par défaut aux nouvelles Cards, en secondes.
/// 1-20 s ; 0 = illimitée (au-delà de 20 s). Consigne : 10 s.
class DefaultViewDuration extends Notifier<int> {
  static const _key = 'default_view_duration';
  static const unlimited = 0;

  @override
  int build() {
    _load();
    return 10;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getInt(_key) ?? 10;
  }

  Future<void> set(int value) async {
    state = value == unlimited ? unlimited : value.clamp(1, 20);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_key, state);
  }
}

final defaultViewDurationProvider = NotifierProvider<DefaultViewDuration, int>(
  DefaultViewDuration.new,
);

/// Popup d'explication des règles de visionnage, montré une seule fois
/// au premier envoi de Card.
class CardsExplainerShown extends Notifier<bool> {
  static const _key = 'cards_explainer_shown';

  @override
  bool build() {
    _load();
    return true; // évite de re-montrer pendant le chargement
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool(_key) ?? false;
  }

  Future<void> markShown() async {
    state = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, true);
  }
}

final cardsExplainerShownProvider = NotifierProvider<CardsExplainerShown, bool>(
  CardsExplainerShown.new,
);

/// Espace local alloué à MES cards, en Mo (consigne Jay 2026-07-13 :
/// paramétrable par l'utilisateur ; au-delà, les plus anciennes repassent
/// en cloud). Défaut : 2 Go.
class OwnCardsQuotaMb extends Notifier<int> {
  static const prefsKey = 'own_cards_quota_mb';
  static const _key = prefsKey;
  static const choices = [512, 1024, 2048, 4096, 8192];

  @override
  int build() {
    _load();
    return 2048;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getInt(_key) ?? 2048;
  }

  Future<void> set(int value) async {
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_key, value);
  }
}

final ownCardsQuotaMbProvider = NotifierProvider<OwnCardsQuotaMb, int>(
  OwnCardsQuotaMb.new,
);

/// Anti-capture : FLAG_SECURE est ACTIF par défaut (screenshots bloqués,
/// écran noir en partage d'écran). Cette option DÉVELOPPEUR le désactive
/// pour permettre les captures pendant le dev (consigne Jay 2026-07-13) —
/// à retirer avec la section Développeur.
class DevSecureDisabled extends Notifier<bool> {
  static const prefsKey = 'dev_secure_disabled';

  @override
  bool build() {
    _load();
    return false;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool(prefsKey) ?? false;
  }

  Future<void> set(bool value) async {
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefsKey, value);
  }
}

final devSecureDisabledProvider = NotifierProvider<DevSecureDisabled, bool>(
  DevSecureDisabled.new,
);

/// Diagnostic caméra (DÉVELOPPEUR) : affiche sur l'aperçu la résolution du
/// buffer, la rotation annoncée par CameraX et l'état du double flux — de
/// quoi identifier une distorsion d'aperçu sans deviner. À retirer avec la
/// section Développeur.
class DevCameraHud extends Notifier<bool> {
  static const prefsKey = 'dev_camera_hud';

  @override
  bool build() {
    _load();
    return false;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool(prefsKey) ?? false;
  }

  Future<void> set(bool value) async {
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefsKey, value);
  }
}

final devCameraHudProvider = NotifierProvider<DevCameraHud, bool>(
  DevCameraHud.new,
);
