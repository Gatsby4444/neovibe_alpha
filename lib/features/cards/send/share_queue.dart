import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'share_plan.dart';
import 'share_publisher.dart';
import 'vibe_draft.dart';

/// Un envoi en cours ou terminé.
@immutable
class ShareJob {
  const ShareJob({
    required this.id,
    required this.draft,
    required this.plan,
    required this.total,
    this.outcomes = const [],
    this.finished = false,
  });

  final int id;
  final VibeDraft draft;

  /// Le plan **entier**, tel que coché : c'est lui qu'on restreint pour
  /// « Réessayer » une destination.
  final SharePlan plan;

  /// Combien de destinations ce travail doit régler.
  final int total;

  /// Les destinations réglées jusqu'ici, dans l'ordre où elles l'ont été.
  final List<ShareOutcome> outcomes;

  /// Vrai quand plus rien ne tourne pour ce travail.
  final bool finished;

  int get done => outcomes.length;
  List<ShareOutcome> get echecs => [
    for (final o in outcomes)
      if (!o.reussi) o,
  ];
  bool get aEchoue => finished && echecs.isNotEmpty;
  bool get toutEstParti => finished && echecs.isEmpty;

  ShareJob copyWith({
    SharePlan? plan,
    List<ShareOutcome>? outcomes,
    bool? finished,
  }) => ShareJob(
    id: id,
    draft: draft,
    plan: plan ?? this.plan,
    total: total,
    outcomes: outcomes ?? this.outcomes,
    finished: finished ?? this.finished,
  );

  @override
  bool operator ==(Object other) =>
      other is ShareJob &&
      other.id == id &&
      other.finished == finished &&
      listEquals(other.outcomes, outcomes);

  @override
  int get hashCode => Object.hash(id, finished, Object.hashAll(outcomes));
}

/// Ce que la file sait faire d'un plan : l'exécuter. Injectable, pour que la
/// file s'éprouve sans réseau.
typedef ShareRunner =
    Future<ShareResult> Function(
      VibeDraft draft,
      SharePlan plan, {
      ShareProgress? onProgress,
    });

/// **La file d'envoi — la cuisine qui tourne pendant qu'on est déjà revenu à
/// la caméra** (Jay, 2026-09-14 : « retour à la caméra immédiat »).
///
/// Avant, l'écran de partage attendait la fin de l'envoi, un rond au milieu :
/// une vidéo de 20 Mo en story + groupe, c'est deux montées à regarder. Ici
/// l'écran dépose un travail et s'en va ; le bandeau (`ShareProgressBanner`)
/// observe la file et dit « Envoi… 1/3 », puis « Envoyé », ou nomme ce qui a
/// échoué avec un **Réessayer** pour cette destination seule.
///
/// ## Ce qu'elle ne fait pas
///
/// Elle ne navigue pas, ne dessine pas, ne décide pas si un plan est valide
/// ([SharePlan.problemes] l'a fait avant). Un travail à la fois : deux envois
/// simultanés se partageraient le réseau et finiraient tous les deux plus
/// tard. Elle ne survit pas au processus : un envoi interrompu par la mort de
/// l'app est perdu, et le bandeau ne pourra pas le dire — limite connue,
/// écrite ici pour ne pas être redécouverte.
class ShareQueue extends Notifier<List<ShareJob>> {
  ShareQueue({ShareRunner? runner}) : _runnerOverride = runner;

  final ShareRunner? _runnerOverride;
  int _nextId = 1;
  bool _running = false;
  final _pending = <ShareJob>[];

  @override
  List<ShareJob> build() => const [];

  ShareRunner get _runner =>
      _runnerOverride ?? ref.read(sharePublisherProvider).run;

  /// Dépose un envoi et rend la main **tout de suite**.
  int enqueue(VibeDraft draft, SharePlan plan) {
    final job = ShareJob(
      id: _nextId++,
      draft: draft,
      plan: plan,
      total: _compte(plan),
    );
    state = [...state, job];
    _pending.add(job);
    _pump();
    return job.id;
  }

  /// Rejoue **une** destination d'un travail terminé — jamais les autres.
  void retry(int jobId, String cle) {
    final job = state.where((j) => j.id == jobId).firstOrNull;
    if (job == null || !job.finished) return;
    final sousPlan = job.plan.restreintA({cle});
    // Le travail repart avec cette destination en attente : les autres
    // résultats restent tels quels, seule celle-ci sera remplacée.
    final restes = [
      for (final o in job.outcomes)
        if (o.cle != cle) o,
    ];
    final relance = ShareJob(
      id: job.id,
      draft: job.draft,
      plan: job.plan,
      total: job.total,
      outcomes: restes,
    );
    _replace(relance);
    _pending.add(relance.copyWith(plan: sousPlan));
    _pump();
  }

  /// Retire un travail terminé de la file (le bandeau l'a montré).
  void dismiss(int jobId) {
    state = [
      for (final j in state)
        if (j.id != jobId) j,
    ];
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      while (_pending.isNotEmpty) {
        final job = _pending.removeAt(0);
        await _run(job);
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _run(ShareJob job) async {
    // ⚠️ Le plan à EXÉCUTER peut être un sous-plan (Réessayer) ; celui à
    // afficher reste le plan entier, porté par l'état.
    final aExecuter = job.plan;
    void progress(ShareOutcome o) {
      final courant = state.where((j) => j.id == job.id).firstOrNull;
      if (courant == null) return;
      _replace(courant.copyWith(outcomes: [...courant.outcomes, o]));
    }

    try {
      await _runner(job.draft, aExecuter, onProgress: progress);
    } catch (e) {
      // Le publieur rapporte chaque destination seule ; une exception ici
      // serait un défaut du publieur lui-même. On ne perd pas le travail pour
      // autant : il est marqué terminé, et ce qui manque se voit.
      final courant = state.where((j) => j.id == job.id).firstOrNull;
      if (courant != null && courant.outcomes.length < courant.total) {
        progress(ShareOutcome(cle: 'queue', label: 'Envoi', erreur: e));
      }
    }
    final courant = state.where((j) => j.id == job.id).firstOrNull;
    if (courant != null) _replace(courant.copyWith(finished: true));
  }

  void _replace(ShareJob job) {
    state = [
      for (final j in state)
        if (j.id == job.id) job else j,
    ];
  }

  static int _compte(SharePlan plan) =>
      (plan.story != null ? 1 : 0) +
      (plan.library != null ? 1 : 0) +
      plan.conversations.where((c) => c.dansLeChat).length +
      plan.conversations.where((c) => c.aussiDansLaBibliotheque).length +
      plan.crossed.length;
}

final shareQueueProvider = NotifierProvider<ShareQueue, List<ShareJob>>(
  ShareQueue.new,
);
