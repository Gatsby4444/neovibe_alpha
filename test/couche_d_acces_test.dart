import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/api/supabase_gestes.dart';

/// **La couche d'accès** (`lib/core/api/`, docs/serveur-rust.md étape 11) —
/// trois garde-fous qu'aucune compilation ne tient :
///
/// 1. seule la couche d'accès parle à Supabase : un dépôt qui l'appellerait
///    en direct échapperait au serveur Rust sans que rien ne le signale ;
/// 2. chaque opération demandée par l'app EXISTE des deux côtés — une
///    fonction SQL ou un geste Supabase, ET une opération du serveur Rust.
///    Une faute de frappe dans un nom ne se verrait sinon qu'à l'usage, et
///    d'un seul côté ;
/// 3. chaque appel envoie exactement les champs que son guichet Rust
///    accepte et exige — le contrat entre l'app et le serveur, tant qu'il
///    n'est pas généré (docs/serveur-rust.md, annexe B).
void main() {
  Iterable<File> dart(String dossier) => Directory(dossier)
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'));

  String chemin(File f) => f.path.replaceAll(r'\', '/');

  test('seule la couche d\'accès parle à Supabase', () {
    final fautes = [
      for (final f in dart('lib'))
        if (!chemin(f).startsWith('lib/core/api/') &&
            f.readAsStringSync().contains('package:supabase_flutter'))
          chemin(f),
    ];
    expect(
      fautes,
      isEmpty,
      reason: 'ces fichiers parlent à Supabase en direct',
    );
  });

  test('chaque opération de l\'app existe côté Supabase et côté Rust', () {
    // Les opérations demandées par l'app : `.op('nom'` (Dart) et le natif.
    // (Les guichets propres au branchement Rust — ses fichiers, son direct —
    // n'ont pas d'équivalent Supabase : ils ne comptent que côté Rust.)
    final demande = RegExp(r"""\.op\(\s*'([a-z_0-9]+)'""");
    final demandees = <String>{
      for (final f in dart('lib'))
        if (!chemin(f).startsWith('lib/core/api/rust_'))
          for (final m in demande.allMatches(f.readAsStringSync())) m.group(1)!,
    };
    final propresAuRust = <String>{
      for (final f in dart('lib/core/api'))
        if (chemin(f).startsWith('lib/core/api/rust_'))
          for (final m in demande.allMatches(f.readAsStringSync())) m.group(1)!,
    };
    final natif = RegExp(r'rpc(?:Text)?\("([a-z_0-9]+)"');
    for (final f
        in Directory('android/app/src/main/kotlin')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.kt'))) {
      for (final m in natif.allMatches(f.readAsStringSync())) {
        demandees.add(m.group(1)!);
      }
    }
    expect(demandees.length, greaterThan(100));

    // Côté Supabase : une fonction SQL publique, ou un geste direct.
    final fonction = RegExp(
      r'function\s+public\.([a-z_0-9]+)\s*\(',
      caseSensitive: false,
    );
    final sql = <String>{
      for (final f in Directory(
        'supabase/migrations',
      ).listSync().whereType<File>())
        for (final m in fonction.allMatches(f.readAsStringSync()))
          m.group(1)!.toLowerCase(),
    };
    final sansSupabase = demandees
        .where((n) => !sql.contains(n) && !gestesSupabase.containsKey(n))
        .toList();
    expect(sansSupabase, isEmpty, reason: 'absentes côté Supabase');

    // Côté Rust : le registre des guichets (`nom => fonction,` des `ops!`).
    final guichet = RegExp(
      r'(?:^\s+|ops!\[)([a-z_0-9]+) => [a-z_0-9:]+[,\]]',
      multiLine: true,
    );
    final rust = <String>{
      for (final f
          in Directory('server/crates/nv-app/src')
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.rs')))
        for (final m in guichet.allMatches(f.readAsStringSync())) m.group(1)!,
    };
    final sansRust = {
      ...demandees,
      ...propresAuRust,
    }.where((n) => !rust.contains(n)).toList();
    expect(sansRust, isEmpty, reason: 'absentes du serveur Rust');
  });

  // 3. Chaque appel ENVOIE ce que son guichet Rust ACCEPTE. Le serveur refuse
  //    tout champ inconnu (`deny_unknown_fields`) et exige les siens : un nom
  //    changé d'un seul côté passerait `flutter analyze` ET `cargo test`, et
  //    ne se verrait que sur le téléphone, à l'usage. (Les appels du natif
  //    sont éprouvés contre le vrai serveur : RustHttpEssaiTest.kt.)
  test('chaque appel envoie exactement les champs que son guichet Rust '
      'accepte', () {
    final rs = <String, String>{
      for (final f
          in Directory('server/crates/nv-app/src')
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.rs')))
        chemin(f): f.readAsStringSync(),
    };
    final contrats = _contratsRust(rs);
    expect(contrats.length, greaterThan(150));

    final fautes = <String>[];
    var compares = 0;
    final appel = RegExp(r"""\.op\(\s*'([a-z_0-9]+)'""");
    for (final f in dart('lib')) {
      final t = f.readAsStringSync();
      for (final m in appel.allMatches(t)) {
        final op = m.group(1)!;
        final lieu = '${chemin(f)}:${_ligne(t, m.start)} $op';
        final contrat = contrats[op];
        if (contrat is! _Contrat) {
          fautes.add('$lieu : ${contrat ?? 'aucun guichet Rust de ce nom'}');
          continue;
        }
        var i = m.end;
        while (t[i].trim().isEmpty) {
          i++;
        }
        if (t[i] == ',') {
          i++;
          while (t[i].trim().isEmpty) {
            i++;
          }
        }
        final _Envoi envoi;
        if (t[i] == ')') {
          envoi = _Envoi({}, {});
        } else if (t[i] == '{') {
          final lu = _lireMap(t, i);
          if (lu == null) {
            fautes.add('$lieu : map illisible par ce test (for, ...) ');
            continue;
          }
          envoi = lu;
        } else {
          fautes.add(
            '$lieu : les arguments doivent être une map écrite à l\'appel, '
            'pour que ce contrat reste vérifiable',
          );
          continue;
        }
        compares++;
        final inconnus = envoi.toutes.difference(contrat.champs);
        if (inconnus.isNotEmpty) {
          fautes.add(
            '$lieu : champs REFUSÉS par le guichet Rust : $inconnus '
            '(il accepte ${contrat.champs})',
          );
        }
        final manquants = contrat.exiges.difference(envoi.sures);
        if (manquants.isNotEmpty) {
          fautes.add(
            '$lieu : champs EXIGÉS par le guichet Rust et pas toujours '
            'envoyés : $manquants',
          );
        }
      }
    }
    expect(fautes, isEmpty, reason: fautes.join('\n'));
    expect(
      compares,
      greaterThan(150),
      reason: 'le test ne lit plus les appels',
    );
  });
}

/// Ce qu'un guichet Rust accepte, et ce qu'il exige.
class _Contrat {
  _Contrat(this.champs, this.exiges);
  final Set<String> champs;
  final Set<String> exiges;
}

/// Ce qu'un appel de l'app envoie : toutes ses clés, et celles qui partent
/// à coup sûr (ni `'cle': ?valeur`, ni sous un `if`).
class _Envoi {
  _Envoi(this.toutes, this.optionnelles);
  final Set<String> toutes;
  final Set<String> optionnelles;
  Set<String> get sures => toutes.difference(optionnelles);
}

int _ligne(String t, int i) => '\n'.allMatches(t.substring(0, i)).length + 1;

/// Rend l'indice juste après la chaîne Dart qui commence en [i]
/// (interpolations `${…}` comprises).
int _finDeChaine(String t, int i) {
  final q = t[i];
  final triple = t.startsWith(q * 3, i);
  var j = i + (triple ? 3 : 1);
  while (j < t.length) {
    final c = t[j];
    if (c == r'\') {
      j += 2;
    } else if (triple ? t.startsWith(q * 3, j) : c == q) {
      return j + (triple ? 3 : 1);
    } else if (c == r'$' && j + 1 < t.length && t[j + 1] == '{') {
      j = _finDeBloc(t, j + 1);
    } else {
      j++;
    }
  }
  return j;
}

/// [i] pointe une ouvrante `{`, `[` ou `(` : rend l'indice juste après sa
/// fermante (chaînes et commentaires sautés).
int _finDeBloc(String t, int i) {
  var prof = 0;
  var j = i;
  while (j < t.length) {
    final c = t[j];
    if (c == "'" || c == '"') {
      j = _finDeChaine(t, j);
      continue;
    }
    if (t.startsWith('//', j)) {
      final fin = t.indexOf('\n', j);
      j = fin < 0 ? t.length : fin;
      continue;
    }
    if ('{[('.contains(c)) {
      prof++;
    } else if ('}])'.contains(c)) {
      prof--;
      if (prof == 0) return j + 1;
    }
    j++;
  }
  return j;
}

/// Les entrées de premier niveau d'une map Dart qui commence en [i] ; null
/// si l'une d'elles n'est pas lisible (`for`, `...`).
_Envoi? _lireMap(String t, int i) {
  final fin = _finDeBloc(t, i) - 1;
  final entrees = <String>[];
  var debut = i + 1;
  var j = i + 1;
  while (j < fin) {
    final c = t[j];
    if (c == "'" || c == '"') {
      j = _finDeChaine(t, j);
    } else if ('{[('.contains(c)) {
      j = _finDeBloc(t, j);
    } else if (t.startsWith('//', j)) {
      final n = t.indexOf('\n', j);
      j = n < 0 ? fin : n;
    } else if (c == ',') {
      entrees.add(t.substring(debut, j));
      debut = ++j;
    } else {
      j++;
    }
  }
  entrees.add(t.substring(debut, fin));
  final toutes = <String>{};
  final optionnelles = <String>{};
  final cle = RegExp(r"""^['"]([a-z_0-9]+)['"]\s*:\s*(\?)?""");
  for (var e in entrees) {
    e = e.replaceAll(RegExp(r'//[^\n]*'), '').trim();
    if (e.isEmpty) continue;
    var conditionnelle = false;
    if (e.startsWith('if')) {
      final p = e.indexOf('(');
      e = e.substring(_finDeBloc(e, p)).trim();
      conditionnelle = true;
    }
    final m = cle.firstMatch(e);
    if (m == null) return null;
    toutes.add(m.group(1)!);
    if (conditionnelle || m.group(2) != null) optionnelles.add(m.group(1)!);
  }
  return _Envoi(toutes, optionnelles);
}

/// Chaque opération du serveur Rust → ce que son guichet accepte : les
/// champs de la structure qu'il lit (`parse::<S>(args)` ou
/// `let a: S = parse(args)`), ou, pour les guichets qui lisent des colonnes
/// une à une (`profile_update`, `card_create`), les noms de sa liste. Quand
/// le guichet n'est pas lisible, la valeur est la RAISON (un texte).
Map<String, Object> _contratsRust(Map<String, String> rs) {
  // Les fonctions : nom → (fichier, corps jusqu'à la suivante).
  final fonctions = <String, List<(String, String)>>{};
  final fn = RegExp(r'(?:pub(?:\([a-z]+\))?\s+)?async fn (\w+)\s*\(');
  rs.forEach((f, t) {
    final ms = fn.allMatches(t).toList();
    for (var k = 0; k < ms.length; k++) {
      final fin = k + 1 < ms.length ? ms[k + 1].start : t.length;
      (fonctions[ms[k].group(1)!] ??= []).add((
        f,
        t.substring(ms[k].start, fin),
      ));
    }
  });

  // Une structure : cherchée dans le guichet, puis son fichier, puis partout.
  // Rend le contrat, ou la raison pour laquelle il n'y en a pas.
  Object structure(String nom, List<String> textes) {
    final debut = RegExp(
      r'(?:pub(?:\([a-z]+\))?\s+)?struct\s+' + nom + r'\s*\{',
    );
    for (final t in textes) {
      final m = debut.firstMatch(t);
      if (m == null) continue;
      // Les attributs de la structure : les lignes `#[…]` au-dessus (les
      // commentaires de doc peuvent s'y intercaler).
      final avant = t.substring(0, m.start).split('\n').reversed;
      final attributs = StringBuffer();
      for (final l in avant.skip(1)) {
        final s = l.trim();
        if (s.startsWith('#[')) {
          attributs.write(s);
        } else if (!s.startsWith('//')) {
          break;
        }
      }
      final attr = attributs.toString();
      if (!attr.contains('deny_unknown_fields')) {
        return 'la structure $nom ne refuse pas les champs inconnus '
            '(#[serde(deny_unknown_fields)], nv-core/src/args.rs)';
      }
      final defautPartout = RegExp(
        r'serde\((?:[^)]*,\s*)?default\b',
      ).hasMatch(attr);
      final corps = t.substring(m.end, _finDeBlocRust(t, m.end - 1) - 1);
      final champs = <String>{};
      final exiges = <String>{};
      var attente = '';
      final champ = RegExp(r'^(?:pub(?:\([a-z]+\))?\s+)?(\w+)\s*:\s*(.+?),?$');
      for (final l in corps.split('\n')) {
        final s = l.trim();
        if (s.startsWith('#[')) {
          attente += s;
          continue;
        }
        if (s.isEmpty || s.startsWith('//')) continue;
        final c = champ.firstMatch(s);
        if (c == null) continue;
        if (attente.contains('flatten')) {
          return 'la structure $nom est « à plat » (flatten) : ce test ne '
              'sait pas la lire';
        }
        final renomme = RegExp(r'rename\s*=\s*"(\w+)"').firstMatch(attente);
        final n = renomme?.group(1) ?? c.group(1)!;
        champs.add(n);
        for (final a in RegExp(r'alias\s*=\s*"(\w+)"').allMatches(attente)) {
          champs.add(a.group(1)!);
        }
        final optionnel =
            c.group(2)!.startsWith('Option<') ||
            attente.contains('default') ||
            defautPartout;
        if (!optionnel) exiges.add(n);
        attente = '';
      }
      return _Contrat(champs, exiges);
    }
    return 'structure $nom introuvable';
  }

  final contrats = <String, Object>{};
  final registre = RegExp(r'ops!\[(.*?)\]', dotAll: true);
  final entree = RegExp(r'([a-z_0-9]+)\s*=>\s*([a-z_0-9:]+)');
  rs.forEach((f, t) {
    for (final bloc in registre.allMatches(t)) {
      for (final e in entree.allMatches(bloc.group(1)!)) {
        final op = e.group(1)!;
        final segments = e.group(2)!.split('::');
        final candidats = fonctions[segments.last] ?? const [];
        final module = segments.length > 1
            ? segments[segments.length - 2]
            : null;
        final choisi =
            candidats.where((c) => c.$1 == f).firstOrNull ??
            candidats
                .where((c) => module != null && c.$1.endsWith('/$module.rs'))
                .firstOrNull ??
            (candidats.length == 1 ? candidats.single : null);
        if (choisi == null) {
          contrats[op] = 'guichet ${e.group(2)} introuvable';
          continue;
        }
        final (fichier, corps) = choisi;
        final lu = RegExp(
          r'parse::<(\w+)>\s*\(\s*args|:\s*(\w+)\s*=\s*parse\s*\(\s*args',
        ).firstMatch(corps);
        if (lu != null) {
          final nom = lu.group(1) ?? lu.group(2)!;
          contrats[op] = nom == 'NoArgs'
              ? _Contrat({}, {})
              : structure(nom, [corps, rs[fichier]!, ...rs.values]);
          continue;
        }
        // Un guichet qui lit ses colonnes une à une : sa liste de noms.
        final noms = {
          for (final m in RegExp(
            r'"(\w+)"\s*=>|\(\s*"(\w+)"\s*,\s*"',
          ).allMatches(corps))
            m.group(1) ?? m.group(2)!,
        };
        contrats[op] = noms.isNotEmpty
            ? _Contrat(noms, {})
            : 'guichet ${e.group(2)} : ni parse(args), ni liste de colonnes '
                  '— ce test ne sait pas le lire';
      }
    }
  });
  return contrats;
}

/// [i] pointe une accolade ouvrante d'un texte Rust : rend l'indice juste
/// après sa fermante (les chaînes `"…"` sautées).
int _finDeBlocRust(String t, int i) {
  var prof = 0;
  var j = i;
  while (j < t.length) {
    final c = t[j];
    if (c == '"') {
      j++;
      while (j < t.length && t[j] != '"') {
        if (t[j] == r'\') j++;
        j++;
      }
    } else if (c == '{') {
      prof++;
    } else if (c == '}') {
      prof--;
      if (prof == 0) return j + 1;
    }
    j++;
  }
  return j;
}
