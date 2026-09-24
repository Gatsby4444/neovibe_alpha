import 'package:flutter/services.dart';

/// **Le username et le pseudo — leurs règles, écrites UNE fois côté app**
/// (Jay, 2026-09-24).
///
/// | | Username | Pseudo |
/// |---|---|---|
/// | obligatoire | oui | non |
/// | unique | **oui** (`profiles_username_unique`) | non |
/// | format | comme Instagram : `a-z`, `0-9`, `.`, `_` | libre |
/// | longueur | 3 à 20 | 1 à 30 |
/// | affiché | sur les publications (Vibes, stories, profil) | aux autres et dans les groupes, s'il existe et si je le veux (`show_pseudo`) |
///
/// ⚠️ **Le serveur reste seul juge** : `profiles_display_name_check` exige le
/// même format. Ce fichier ne sert qu'à le dire AVANT l'aller-retour, et à
/// transformer la frappe (« Camille Martin » devient « camille.martin ») —
/// la même conversion que la migration du 2026-09-24.
abstract final class Username {
  static const minLength = 3;
  static const maxLength = 20;
  static const pseudoMaxLength = 30;

  static final _valid = RegExp(r'^[a-z0-9._]{3,20}$');

  static const _accents = {
    'à': 'a', 'â': 'a', 'ä': 'a', 'á': 'a', 'ã': 'a', //
    'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
    'î': 'i', 'ï': 'i', 'í': 'i',
    'ô': 'o', 'ö': 'o', 'ó': 'o', 'õ': 'o',
    'ù': 'u', 'û': 'u', 'ü': 'u', 'ú': 'u',
    'ç': 'c', 'ñ': 'n',
  };

  /// La frappe, convertie au format : minuscules, accents retirés, espaces en
  /// points, le reste retiré, pas deux points de suite. **Ne rogne pas la
  /// longueur** : c'est le champ qui la borne.
  static String normalize(String input) {
    final buffer = StringBuffer();
    var lastDot = false;
    for (final ch in input.toLowerCase().split('')) {
      var c = _accents[ch] ?? ch;
      if (c.trim().isEmpty) c = '.';
      final ok = RegExp(r'[a-z0-9._]').hasMatch(c);
      if (!ok) continue;
      if (c == '.' && lastDot) continue;
      lastDot = c == '.';
      buffer.write(c);
    }
    return buffer.toString();
  }

  static bool isValid(String username) => _valid.hasMatch(username);

  /// Ce qui ne va pas, en une phrase ; `null` si c'est bon.
  static String? problem(String username) {
    if (username.length < minLength) {
      return 'Au moins $minLength caractères.';
    }
    if (username.length > maxLength) {
      return '$maxLength caractères au plus.';
    }
    if (!isValid(username)) {
      return 'Lettres, chiffres, point et tiret bas seulement.';
    }
    return null;
  }
}

/// Convertit la frappe au format du username, pendant qu'on tape.
class UsernameInputFormatter extends TextInputFormatter {
  const UsernameInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = Username.normalize(newValue.text);
    final clipped = text.length > Username.maxLength
        ? text.substring(0, Username.maxLength)
        : text;
    return TextEditingValue(
      text: clipped,
      selection: TextSelection.collapsed(offset: clipped.length),
    );
  }
}
