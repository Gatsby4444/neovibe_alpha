import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Préférences locales à l'appareil (UI uniquement — rien de social ici).

/// Thème clair ou sombre (demande de Jay 2026-08-10).
///
/// Le **sombre reste le défaut** : NeoVibe est une app caméra-first, et les
/// écrans de prise comme la visionneuse de Cards restent noirs quoi qu'il
/// arrive — c'est le contenu qui doit porter la lumière, pas l'habillage.
/// Le clair vaut pour tout le reste de l'app.
class LightTheme extends Notifier<bool> {
  static const _key = 'light_theme';

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

final lightThemeProvider = NotifierProvider<LightTheme, bool>(LightTheme.new);

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

/// Miroir de la caméra frontale dans l'APERÇU (consigne Jay 2026-07-25).
/// `true` = on se voit comme dans un miroir, comme la plupart des apps —
/// c'est le défaut. `false` = on se voit comme les autres nous voient
/// (lettres lisibles). Ne concerne QUE l'aperçu : la photo enregistrée n'est
/// jamais mirrorée, quel que soit ce réglage.
class SelfieMirror extends Notifier<bool> {
  static const _key = 'selfie_mirror';

  @override
  bool build() {
    _load();
    return true;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool(_key) ?? true;
  }

  Future<void> set(bool value) async {
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, value);
  }
}

final selfieMirrorProvider = NotifierProvider<SelfieMirror, bool>(
  SelfieMirror.new,
);

/// Grille de cadrage de l'écran de capture (consigne Jay 2026-07-26).
/// « L'état de la grille est conservé tout le temps jusqu'à son changement » :
/// c'est donc une préférence, pas un état d'écran — elle survit à la fermeture
/// de la capture et au redémarrage de l'app.
class CaptureGrid extends Notifier<bool> {
  static const _key = 'capture_grid';

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

final captureGridProvider = NotifierProvider<CaptureGrid, bool>(
  CaptureGrid.new,
);

/// Calibrage du FLASH FRONTAL (lueur d'écran, consigne Jay 2026-07-26) :
/// chaleur de la lumière et intensité, réglées aux deux curseurs.
///
/// Seul le CALIBRAGE est mémorisé, pas l'allumage : on ne règle sa lampe
/// qu'une fois, mais un flash s'allume à la demande — comme le flash arrière,
/// qui repart éteint à chaque ouverture de la capture.
class ScreenFlashSettings {
  const ScreenFlashSettings({required this.warmth, required this.intensity});

  /// 0 = blanc pur, 1 = beige chaud (lampe de créateur de contenu).
  final double warmth;

  /// 0 = fin liseré sur le contour, 1 = écran entièrement illuminé.
  final double intensity;

  ScreenFlashSettings copyWith({double? warmth, double? intensity}) =>
      ScreenFlashSettings(
        warmth: warmth ?? this.warmth,
        intensity: intensity ?? this.intensity,
      );
}

class ScreenFlash extends Notifier<ScreenFlashSettings> {
  static const _warmthKey = 'screen_flash_warmth';
  static const _intensityKey = 'screen_flash_intensity';

  @override
  ScreenFlashSettings build() {
    _load();
    // Défaut : blanc franc, intensité moyenne — un éclairage utile dès le
    // premier allumage, sans avoir à toucher les curseurs.
    return const ScreenFlashSettings(warmth: 0, intensity: 0.5);
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = ScreenFlashSettings(
      warmth: prefs.getDouble(_warmthKey) ?? 0,
      intensity: prefs.getDouble(_intensityKey) ?? 0.5,
    );
  }

  Future<void> set(ScreenFlashSettings value) async {
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_warmthKey, value.warmth);
    await prefs.setDouble(_intensityKey, value.intensity);
  }
}

final screenFlashProvider = NotifierProvider<ScreenFlash, ScreenFlashSettings>(
  ScreenFlash.new,
);

/// Onglet ouvert au lancement de l'app (consigne Jay 2026-08-01 : l'utilisateur
/// choisit son écran de démarrage).
///
/// `card` est un cas à part, ajouté à la demande de Jay le 2026-08-02 : ce
/// n'est pas un onglet où l'app se pose mais un écran plein — l'app démarre
/// alors sur le Cercle avec la capture ouverte par-dessus, comme Snapchat qui
/// s'ouvre sur l'appareil photo. Fermer la capture laisse donc sur le Cercle.
///
/// Stocké par NOM et jamais par index : la barre de navigation va encore bouger
/// pendant la réorganisation, un index mémorisé désignerait ensuite le mauvais
/// onglet sur les appareils déjà installés.
enum StartupTab {
  ping,
  circle,
  card,
  play,
  profile;

  static StartupTab fromKey(String? value) => switch (value) {
    'ping' => StartupTab.ping,
    'card' => StartupTab.card,
    'play' => StartupTab.play,
    'profile' => StartupTab.profile,
    _ => StartupTab.circle,
  };

  String get label => switch (this) {
    StartupTab.ping => 'Ping',
    StartupTab.circle => 'Cercle',
    StartupTab.card => 'Vibe',
    StartupTab.play => 'Jeux',
    StartupTab.profile => 'Profil',
  };
}

class StartupTabPref extends Notifier<StartupTab> {
  static const prefsKey = 'startup_tab';

  @override
  StartupTab build() {
    _load();
    // Défaut : le Cercle — l'écran où l'on revient (consigne Jay 2026-07-26,
    // maintenue le 2026-08-01 au passage à cinq onglets).
    return StartupTab.circle;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = StartupTab.fromKey(prefs.getString(prefsKey));
  }

  Future<void> set(StartupTab value) async {
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsKey, value.name);
  }
}

final startupTabProvider = NotifierProvider<StartupTabPref, StartupTab>(
  StartupTabPref.new,
);

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

/// Anti-capture (FLAG_SECURE) : **DÉSACTIVÉ par défaut pendant le
/// développement** (consigne Jay 2026-07-14 : il doit pouvoir prendre des
/// captures d'écran pour montrer les bugs). Interrupteur dans Réglages →
/// Développeur pour l'activer et le tester. ⚠️ À RÉACTIVER PAR DÉFAUT avant
/// la production (inscrit dans RAPPELS.md).
class DevSecureEnabled extends Notifier<bool> {
  static const prefsKey = 'dev_secure_enabled';

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

final devSecureEnabledProvider = NotifierProvider<DevSecureEnabled, bool>(
  DevSecureEnabled.new,
);

/// Compte à rebours « disparaît dans … » sous chaque message (DÉVELOPPEUR).
/// Retiré de l'affichage courant le 2026-08-01 (consigne Jay) : l'éphémère est
/// une règle du produit, pas un chronomètre à surveiller message par message.
/// Conservé derrière cet interrupteur pour vérifier le TTL en test.
class DevShowExpiry extends Notifier<bool> {
  static const prefsKey = 'dev_show_expiry';

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

final devShowExpiryProvider = NotifierProvider<DevShowExpiry, bool>(
  DevShowExpiry.new,
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

/// Double flux Oneshot en Camera2 brut (EXPÉRIMENTAL, DÉVELOPPEUR).
/// Désactivé par défaut : le moteur Camera2 dual peut planter/verrouiller la
/// caméra sur certains appareils (crash remonté par Jay le 2026-07-14). Par
/// défaut le Oneshot reste sur le mode simple fiable (une caméra affichée,
/// les deux faces capturées). Interrupteur pour tester le double flux.
class DevDualOneshot extends Notifier<bool> {
  static const prefsKey = 'dev_dual_oneshot';

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

final devDualOneshotProvider = NotifierProvider<DevDualOneshot, bool>(
  DevDualOneshot.new,
);
