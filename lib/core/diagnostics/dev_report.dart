import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../supabase_providers.dart';
import 'diagnostic_bundle.dart';

/// Envoi d'un rapport de diagnostic au serveur.
///
/// ## Pourquoi ça existe
///
/// Demande de Jay, 2026-08-16 : *« au lieu de te copier dans le prompt,
/// j'envoie manuellement avec un bouton […] dans un paquet daté, versionné et
/// identifié sur Supabase, d'où tu récupères cela »*.
///
/// Le gain de temps est le motif visible. Les trois vrais bénéfices sont
/// ailleurs :
///
/// 1. **La version est attachée par l'app**, jamais recopiée. On a perdu un
///    aller-retour le 2026-08-16 parce qu'une app se disait `0.9.95` alors
///    qu'elle était en `0.9.98` : un rapport qui porte sa version ne peut plus
///    mentir sur ce qu'il décrit.
/// 2. **Rien n'est tronqué.** Un journal caméra passé par un presse-papiers se
///    coupe et se reformate ; ici les octets arrivent tels quels.
/// 3. **Les rapports se comparent.** Deux envois du même test à deux versions,
///    et la différence saute aux yeux — sans redemander la manipulation.
///
/// ⚠️ **Rien ne part jamais tout seul.** Chaque envoi est déclenché par un
/// geste explicite. Une app qui téléverserait ses journaux d'elle-même serait
/// exactement ce que NeoVibe prétend ne pas être — et le fait que ce soit « pour
/// aider au débogage » ne change rien à ce que ça installe comme habitude.
///
/// ⚠️ **Outil de développement** — à retirer avec la section Développeur avant
/// la prod (`RAPPELS.md`).
class DevReport {
  const DevReport(this.ref);

  final Ref ref;

  /// Au-delà, on tronque : Postgres encaisse, mais un rapport de plusieurs Mo
  /// ne se lit plus et n'apporte rien de plus que ses dernières lignes.
  ///
  /// On garde la **FIN** du texte : un journal se lit par ce qui vient de se
  /// passer, pas par son démarrage.
  ///
  /// ## ⚠️ Ce n'est plus qu'un FILET depuis le 2026-09-11
  ///
  /// Les envois réels étaient à **408 125 caractères sur 409 600** — 99,6 %.
  /// Et couper ici aurait supprimé **le début** du paquet, c'est-à-dire les
  /// sections courtes et décisives (radio, présences, connexions, position) que
  /// [DiagnosticBundle] place délibérément en tête. Deux règles justes chacune
  /// de son côté, qui se contredisaient en silence.
  ///
  /// La place est désormais bornée **par journal** et à la source
  /// (`DiagnosticBundle.maxLogChars`). Ce plafond-ci ne devrait plus jamais
  /// servir : s'il sert, c'est qu'une section structurée a grossi anormalement,
  /// et **c'est ça qu'il faut aller regarder**.
  static const maxBodyChars = 400 * 1024;

  /// Envoie une section, ou le paquet complet.
  ///
  /// [kind] nomme ce qu'on envoie (`all`, `camera`, `video`, `app`, `ping`…) —
  /// c'est ce qui permet de retrouver un envoi précis sans lire les autres.
  Future<void> send({
    required String kind,
    required String body,
    String? note,
    Map<String, dynamic>? data,
  }) async {
    final client = ref.read(supabaseProvider);
    final me = ref.read(currentUserIdProvider);
    if (me == null) throw StateError('Connecte-toi pour envoyer un rapport.');

    final device = await DiagnosticBundle.deviceInfo();
    final trimmed = body.length > maxBodyChars
        ? '[…] ${body.length - maxBodyChars} caractères plus anciens retirés\n'
              '${body.substring(body.length - maxBodyChars)}'
        : body;

    await client.from('dev_reports').insert({
      'author_id': me,
      'kind': kind,
      // ⚠️ Depuis le PAQUET Android (`appVersion`/`appBuild` viennent de
      // `PackageManager`), jamais d'une constante Dart. C'est toute la raison
      // d'être de ce champ : une version recopiée à la main ment tôt ou tard,
      // et un mauvais numéro fait chercher le défaut dans la mauvaise version.
      'app_version': '${device['appVersion']} (${device['appBuild']})',
      'device': '${device['model']} · ${device['android']}',
      'note': note,
      'body': trimmed,
      'data': data,
    });
  }

  /// Le paquet complet, **collecté et rendu tel quel**.
  ///
  /// ⚠️ **C'est ce que l'écran doit appeler, jamais [DiagnosticBundle]
  /// directement.** Règle du projet : un écran ne parle ni au disque, ni au
  /// natif, ni au réseau — il demande à un dépôt. Et surtout, ça garantit que
  /// le bouton « tout copier » et le bouton « tout envoyer » rendent
  /// **exactement le même texte** : deux collectes qui divergent, c'est un
  /// rapport collé qui ne correspond pas au rapport envoyé, et deux heures
  /// perdues à chercher pourquoi.
  Future<String> collect() => DiagnosticBundle.everything(ref);

  /// Le paquet complet — l'équivalent du bouton « Tout copier », mais envoyé.
  Future<void> sendEverything({String? note}) async {
    String body;
    try {
      // ⚠️ **[DiagnosticBundle.everything], jamais [DiagnosticBundle.build].**
      // `build` prend ses sections en OPTION : une zone oubliee ici serait
      // simplement absente du rapport, sans que rien ne le signale — et on
      // conclurait sur un paquet incomplet en le croyant complet. `everything`
      // ne laisse rien a choisir, et c'est le seul endroit a toucher quand une
      // nouvelle zone de diagnostic apparait.
      body = await DiagnosticBundle.everything(ref);
    } catch (e) {
      // Même en échec, on envoie de quoi comprendre l'échec : un rapport vide
      // n'apprend rien, un rapport qui dit pourquoi il est vide, si.
      body = 'La collecte a échoué : $e';
    }
    await send(kind: 'all', body: body, note: note);
  }
}

final devReportProvider = Provider((ref) => DevReport(ref));
