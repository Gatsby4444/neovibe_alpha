import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/api/nv_api.dart';
import 'package:neovibe/core/api/rust_backend.dart';
import 'package:neovibe/core/session_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// **La couche d'accès de l'app contre le VRAI serveur Rust** (étape 11 de
/// docs/serveur-rust.md) : le code même que l'app utilise, sans téléphone.
///
/// Ne tourne que si un serveur d'essai est indiqué :
///
/// ```
/// NV_SERVEUR_ESSAI=http://127.0.0.1:8787 flutter test test/serveur_rust_bout_en_bout_test.dart
/// ```
///
/// (le serveur lancé sur le PC contre la base locale : `server/outils/`), ou
/// `NV_SERVEUR_ESSAI=https://api.neovibe.fun` : le serveur du VPS.
/// Deux comptes neufs, amis le temps de l'essai ; tout est effacé à la fin.
void main() {
  final url = Platform.environment['NV_SERVEUR_ESSAI'];
  final ignore = url == null
      ? 'NV_SERVEUR_ESSAI non défini : pas de serveur Rust à éprouver'
      : null;
  // La base que l'essai prépare et nettoie est TOUJOURS celle du serveur
  // éprouvé : un seul réglage, l'adresse, décide des deux.
  final surLeVps = url != null && Uri.parse(url).host == 'api.neovibe.fun';

  /// Une requête SQL sur la base du serveur éprouvé : mise en place et
  /// ménage. Sur le PC : `nv_serveur` (jamais la référence de la preuve).
  /// Sur le VPS (docs/serveur-rust.md « Le VPS ») : la base `neovibe`, par
  /// SSH (la machine de server/outils/vps/deployer.sh), la requête passant
  /// par l'entrée de psql.
  Future<String> sql(String requete) async {
    if (surLeVps) {
      final home =
          Platform.environment['HOME'] ?? Platform.environment['USERPROFILE']!;
      final p = await Process.start('ssh', [
        '-i',
        '$home/.ssh/neovibe_vps',
        '-o',
        'BatchMode=yes',
        'root@2.24.162.2',
        'sudo -u postgres psql -At -v ON_ERROR_STOP=1 -d neovibe',
      ]);
      p.stdin.write(requete);
      await p.stdin.close();
      final sortie = await p.stdout.transform(utf8.decoder).join();
      final erreur = await p.stderr.transform(utf8.decoder).join();
      if (await p.exitCode != 0) throw StateError('sql (vps) : $erreur');
      return sortie.trim();
    }
    final r = await Process.run('docker', [
      'exec',
      '-i',
      'nv_rust_db',
      'psql',
      '-At',
      '-v',
      'ON_ERROR_STOP=1',
      '-U',
      'postgres',
      '-d',
      'nv_serveur',
      '-c',
      requete,
    ]);
    if (r.exitCode != 0) throw StateError('sql : ${r.stderr}');
    return (r.stdout as String).trim();
  }

  String hasard() =>
      List.generate(8, (_) => Random().nextInt(16).toRadixString(16)).join();

  test(
    'la couche d\'accès de l\'app, contre le serveur Rust',
    () async {
      final a = RustBackend.pour(url!, coffre: CoffreEnMemoire());
      final b = RustBackend.pour(url, coffre: CoffreEnMemoire());
      final idA = <String>[];
      try {
        // ─── La connexion ───────────────────────────────────────────────
        final mail = 'essai.${hasard()}@essai.fr';
        expect(
          await a.auth.inscription(
            email: mail,
            password: 'secret123',
            empreinte: hasard() * 8,
          ),
          isTrue,
        );
        await b.auth.inscription(
          email: 'essai.${hasard()}@essai.fr',
          password: 'secret123',
          empreinte: hasard() * 8,
        );
        final moiA = a.auth.compte!;
        final moiB = b.auth.compte!;
        idA.addAll([moiA, moiB]);
        await a.api.op('profile_create', {
          'id': moiA,
          'display_name': 'essai_a_${hasard()}',
        });
        await b.api.op('profile_create', {
          'id': moiB,
          'display_name': 'essai_b_${hasard()}',
        });
        // Une déconnexion puis une reconnexion : la session se rouvre.
        await a.auth.deconnexion();
        expect(a.auth.compte, isNull);
        await a.auth.connexion(email: mail, password: 'secret123');
        expect(a.auth.compte, moiA);

        // Un refus du serveur arrive en phrase, avec son code.
        await expectLater(
          a.api.op('card_get', {'id': 'pas-un-identifiant'}),
          throwsA(isA<NvApiException>()),
        );

        // ─── Amis (mis en place en base : il faudrait se croiser) ─────────
        await sql(
          "insert into public.connections (user_low, user_high, status, origin) "
          "values (least('$moiA'::uuid, '$moiB'::uuid), greatest('$moiA'::uuid, '$moiB'::uuid), 'full', 'proximity')",
        );
        final conv =
            await a.api.op('get_or_create_direct_conversation', {'peer': moiB})
                as String;

        // ─── Le direct : une liste suivie, un message, une diffusion ─────
        final recus = <List<Map<String, dynamic>>>[];
        final suivi = b.direct
            .lignes(
              'messages',
              cle: const ['id'],
              colonne: 'conversation_id',
              valeur: conv,
              ordre: 'created_at',
            )
            .listen(recus.add);
        final canalB = b.direct.canal('typing:$conv');
        final diffusions = <Map<String, dynamic>>[];
        final ecoute = canalB.diffusions.listen(diffusions.add);
        final canalA = a.direct.canal('typing:$conv');

        Future<void> attendre(bool Function() fait, String quoi) async {
          final fin = DateTime.now().add(const Duration(seconds: 10));
          while (!fait()) {
            if (DateTime.now().isAfter(fin)) fail('rien reçu : $quoi');
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }

        await attendre(() => recus.isNotEmpty, 'l\'état initial');
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final ecrit =
            await a.api.op('message_send', {
                  'conversation_id': conv,
                  'sender_id': moiA,
                  'kind': 'text',
                  'body': 'bonjour du bout en bout',
                })
                as Map<String, dynamic>;
        expect(ecrit['body'], 'bonjour du bout en bout');
        await attendre(
          () => recus.last.any((m) => m['body'] == 'bonjour du bout en bout'),
          'le message chez B',
        );
        canalA.diffuser({'user_id': moiA, 'name': 'A'});
        await attendre(() => diffusions.isNotEmpty, '« en train d\'écrire »');
        expect(diffusions.first['name'], 'A');

        // ─── Les fichiers : dépôt, lien, lecture, suppression ────────────
        final octets = Uint8List.fromList(List.generate(4096, (i) => i % 251));
        final chemin = '$moiA/essai_${hasard()}.bin';
        await a.fichiers.deposerOctets(
          'media',
          chemin,
          octets,
          type: 'application/octet-stream',
        );
        expect(await a.fichiers.telecharger('media', chemin), octets);
        await expectLater(
          b.fichiers.lien('media', chemin),
          throwsA(isA<NvApiException>()),
          reason: 'B ne lit pas un fichier qui ne lui est pas destiné',
        );
        await a.fichiers.supprimer('media', [chemin]);
        await expectLater(
          a.fichiers.telecharger('media', chemin),
          throwsA(anything),
        );

        await suivi.cancel();
        await ecoute.cancel();
        await canalA.fermer();
        await canalB.fermer();
      } finally {
        if (idA.isNotEmpty) {
          final ids = idA.map((i) => "'$i'").join(', ');
          await sql(
            'delete from public.conversations c where exists (select 1 from public.conversation_members m '
            'where m.conversation_id = c.id and m.user_id in ($ids)); '
            'delete from public.connections where user_low in ($ids) or user_high in ($ids); '
            'delete from public.profiles where id in ($ids); '
            'delete from private.device_signups where user_id in ($ids); '
            'delete from auth.users where id in ($ids);',
          );
        }
      }
    },
    skip: ignore,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  // Panne vue par Jay dans l'app d'essai (2026-09-28, revue le 2026-09-29) :
  // « Pas de session ouverte. » en créant un compte. Le compte ET sa session
  // existaient sur le serveur, pas le profil : l'inscription finie, le
  // parcours lisait aussitôt « qui est connecté ? » (`currentUserIdProvider`)
  // et recevait encore « personne ».
  test(
    'le compte connecté se lit dès la fin de l\'inscription',
    () async {
      final backend = RustBackend.pour(url!, coffre: CoffreEnMemoire());
      final c = ProviderContainer(
        overrides: [nvBackendProvider.overrideWithValue(backend)],
      );
      // Comme dans l'app : quelqu'un écoute déjà la session.
      c.listen(currentUserIdProvider, (_, _) {});
      await Future<void>.delayed(Duration.zero);
      expect(c.read(currentUserIdProvider), isNull);
      String? id;
      try {
        await c
            .read(nvAuthProvider)
            .inscription(
              email: 'essai.${hasard()}@essai.fr',
              password: 'secret123',
              empreinte: hasard() * 8,
            );
        id = backend.auth.compte;
        expect(id, isNotNull);
        // Aussitôt, sans attendre : c'est ce que fait le parcours d'arrivée.
        expect(c.read(currentUserIdProvider), id);
      } finally {
        c.dispose();
        if (id != null) {
          await sql(
            "delete from private.device_signups where user_id = '$id'; "
            "delete from auth.users where id = '$id';",
          );
        }
      }
    },
    skip: ignore,
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
