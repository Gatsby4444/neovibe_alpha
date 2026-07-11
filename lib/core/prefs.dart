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
