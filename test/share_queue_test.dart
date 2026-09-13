import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neovibe/core/models/card.dart';
import 'package:neovibe/features/cards/send/share_plan.dart';
import 'package:neovibe/features/cards/send/share_publisher.dart';
import 'package:neovibe/features/cards/send/share_queue.dart';
import 'package:neovibe/features/cards/send/vibe_draft.dart';

/// Ce que ces tests défendent : **l'envoi en arrière-plan rend la main tout de
/// suite, avance destination par destination, et « Réessayer » ne rejoue QUE
/// la destination qui a échoué.**
///
/// Rejouer les autres, c'est publier une story deux fois — ça se voit. Ne pas
/// rejouer du tout, c'est perdre un envoi en silence. Les deux sont faux.
void main() {
  VibeDraft brouillon() => VibeDraft(
    front: File('front.jpg'),
    back: null,
    type: CardType.standard,
    imported: false,
    frontIsVideo: false,
    backIsVideo: false,
  );

  SharePlan plan() => SharePlan(
    story: const StoryShare(),
    conversations: const [
      ConversationShare(conversationId: 'c1', memberIds: ['a'], label: 'Léa'),
      ConversationShare(conversationId: 'c2', memberIds: ['b'], label: 'Max'),
    ],
  );

  /// Un publieur factice : règle chaque destination, échoue celles dont la
  /// clé est dans [echoue], et note tout ce qu'on lui a demandé.
  ShareRunner faux(
    List<SharePlan> demandes, {
    Set<String> echoue = const {},
    Completer<void>? attendre,
  }) => (draft, plan, {onProgress}) async {
    demandes.add(plan);
    if (attendre != null) await attendre.future;
    final outcomes = <ShareOutcome>[];
    void regle(String cle, String label) {
      final o = ShareOutcome(
        cle: cle,
        label: label,
        erreur: echoue.contains(cle) ? StateError('panne $label') : null,
      );
      outcomes.add(o);
      onProgress?.call(o);
    }

    if (plan.story != null) regle(SharePlan.cleStory, 'Ma story');
    for (final c in plan.conversations) {
      if (c.dansLeChat) regle(c.cleChat, c.label);
      if (c.aussiDansLaBibliotheque) regle(c.cleLibrary, '${c.label} · bib');
    }
    return ShareResult(outcomes);
  };

  ProviderContainer conteneur(ShareRunner runner) {
    final c = ProviderContainer(
      overrides: [
        shareQueueProvider.overrideWith(() => ShareQueue(runner: runner)),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('déposer rend la main tout de suite, puis ça avance', () async {
    final porte = Completer<void>();
    final demandes = <SharePlan>[];
    final c = conteneur(faux(demandes, attendre: porte));
    final queue = c.read(shareQueueProvider.notifier);

    final id = queue.enqueue(brouillon(), plan());
    // Rien n'est encore réglé : le publieur attend derrière la porte.
    var job = c.read(shareQueueProvider).single;
    expect(job.id, id);
    expect(job.total, 3);
    expect(job.done, 0);
    expect(job.finished, isFalse);

    porte.complete();
    await Future<void>.delayed(Duration.zero);
    job = c.read(shareQueueProvider).single;
    expect(job.done, 3);
    expect(job.toutEstParti, isTrue);
    expect(demandes, hasLength(1));
  });

  test('🔴 Réessayer ne rejoue QUE la destination en échec', () async {
    final demandes = <SharePlan>[];
    var echoue = {'conv:c2:chat'};
    final c = conteneur(
      (draft, plan, {onProgress}) =>
          faux(demandes, echoue: echoue)(draft, plan, onProgress: onProgress),
    );
    final queue = c.read(shareQueueProvider.notifier);

    final id = queue.enqueue(brouillon(), plan());
    await Future<void>.delayed(Duration.zero);
    var job = c.read(shareQueueProvider).single;
    expect(job.aEchoue, isTrue);
    expect(job.echecs.map((e) => e.label), ['Max']);

    // La panne est réparée : on ne renvoie que Max.
    echoue = {};
    queue.retry(id, 'conv:c2:chat');
    await Future<void>.delayed(Duration.zero);
    job = c.read(shareQueueProvider).single;
    expect(job.toutEstParti, isTrue, reason: 'Max est parti cette fois');
    expect(job.done, 3, reason: 'les deux premières n\'ont pas été refaites');

    final rejoue = demandes.last;
    expect(rejoue.story, isNull, reason: 'la story n\'est PAS republiée');
    expect(rejoue.conversations.map((x) => x.label), ['Max']);
  });

  test('deux envois se suivent, jamais en même temps', () async {
    final porte = Completer<void>();
    final demandes = <SharePlan>[];
    var premier = true;
    final c = conteneur((draft, plan, {onProgress}) {
      final attend = premier ? porte : null;
      premier = false;
      return faux(demandes, attendre: attend)(
        draft,
        plan,
        onProgress: onProgress,
      );
    });
    final queue = c.read(shareQueueProvider.notifier);

    queue.enqueue(brouillon(), plan());
    queue.enqueue(brouillon(), const SharePlan(story: StoryShare()));
    await Future<void>.delayed(Duration.zero);
    expect(demandes, hasLength(1), reason: 'le second attend le premier');

    porte.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(demandes, hasLength(2));
    expect(c.read(shareQueueProvider).every((j) => j.toutEstParti), isTrue);
  });

  test('ranger un travail terminé le retire de la file', () async {
    final c = conteneur(faux([]));
    final queue = c.read(shareQueueProvider.notifier);
    final id = queue.enqueue(brouillon(), const SharePlan(story: StoryShare()));
    await Future<void>.delayed(Duration.zero);
    queue.dismiss(id);
    expect(c.read(shareQueueProvider), isEmpty);
  });
}
