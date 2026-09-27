import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api/nv_api.dart';

/// **La cuisine de la console** : les RPC `admin_*`, et rien d'autre. Aucun
/// écran ne connaît un nom de fonction ; il demande ici. Chaque écriture
/// invalide ce qu'elle change.
class AdminRepository {
  AdminRepository(this.ref);
  final Ref ref;

  NvApi get _c => ref.read(nvApiProvider);

  Future<bool> amIAdmin() async =>
      (await _c.op('am_i_admin') as bool?) ?? false;

  Future<Map<String, dynamic>> stats() async {
    final rows = await _c.op('admin_stats') as List;
    return (rows.first as Map).cast<String, dynamic>();
  }

  Future<List<Map<String, dynamic>>> reports(String status) async {
    final rows = await _c.op('admin_reports', {'p_status': status}) as List;
    return [for (final r in rows) (r as Map).cast<String, dynamic>()];
  }

  /// **La preuve d'un signalement** (scellé de modération, 2026-09-25) :
  /// ses fichiers et leurs clés, tant que le signalement est ouvert. Le
  /// serveur journalise chaque ouverture (`view_evidence`).
  Future<List<Map<String, dynamic>>> evidence(String kind, String id) async {
    final rows =
        await _c.op('admin_report_evidence', {'p_kind': kind, 'p_report': id})
            as List;
    return [for (final r in rows) (r as Map).cast<String, dynamic>()];
  }

  /// Les octets SCELLÉS d'un fichier sous scellé — lisibles par un
  /// administrateur seulement (`moderation_read_held`). Déchiffrés en
  /// mémoire par l'appelant ([SealedBytes]), jamais écrits.
  Future<Uint8List> heldBytes(String bucket, String path) =>
      ref.read(nvFichiersProvider).telecharger(bucket, path);

  /// Retire l'affiche ET la description d'une soirée (2026-09-25).
  Future<void> removeEventPoster(String eventId, String reason) async {
    await _c.op('admin_remove_event_poster', {
      'p_event': eventId,
      'p_reason': reason,
    });
    _changed();
  }

  Future<void> resolveReport(
    String kind,
    String id, {
    required bool dismiss,
    String? note,
  }) async {
    await _c.op('admin_resolve_report', {
      'p_kind': kind,
      'p_report': id,
      'p_dismiss': dismiss,
      'p_note': note,
    });
    _changed();
  }

  Future<void> suspend(String userId, String reason) async {
    await _c.op('admin_suspend_user', {'p_user': userId, 'p_reason': reason});
    _changed();
  }

  Future<void> unsuspend(String userId, String? note) async {
    await _c.op('admin_unsuspend_user', {'p_user': userId, 'p_note': note});
    _changed();
  }

  Future<void> deleteContent(String contentId, String reason) async {
    await _c.op('admin_delete_content', {
      'p_content': contentId,
      'p_reason': reason,
    });
    _changed();
  }

  Future<List<Map<String, dynamic>>> events() async {
    final rows = await _c.op('admin_events') as List;
    return [for (final r in rows) (r as Map).cast<String, dynamic>()];
  }

  Future<void> closeEvent(String eventId, String reason) async {
    await _c.op('admin_close_event', {'p_event': eventId, 'p_reason': reason});
    _changed();
  }

  Future<List<Map<String, dynamic>>> actions() async {
    final rows = await _c.op('admin_actions', {'p_limit': 200}) as List;
    return [for (final r in rows) (r as Map).cast<String, dynamic>()];
  }

  Future<List<Map<String, dynamic>>> users(String? query) async {
    final rows =
        await _c.op('admin_users', {'p_query': query, 'p_limit': 100}) as List;
    return [for (final r in rows) (r as Map).cast<String, dynamic>()];
  }

  void _changed() {
    ref.invalidate(adminStatsProvider);
    ref.invalidate(adminReportsProvider);
    ref.invalidate(adminEventsProvider);
    ref.invalidate(adminActionsProvider);
    ref.invalidate(adminUsersProvider);
  }
}

final adminRepositoryProvider = Provider((ref) => AdminRepository(ref));

final amIAdminProvider = FutureProvider<bool>(
  (ref) => ref.watch(adminRepositoryProvider).amIAdmin(),
);
final adminStatsProvider = FutureProvider<Map<String, dynamic>>(
  (ref) => ref.watch(adminRepositoryProvider).stats(),
);
final adminReportsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>(
      (ref, status) => ref.watch(adminRepositoryProvider).reports(status),
    );
final adminEventsProvider = FutureProvider<List<Map<String, dynamic>>>(
  (ref) => ref.watch(adminRepositoryProvider).events(),
);
final adminActionsProvider = FutureProvider<List<Map<String, dynamic>>>(
  (ref) => ref.watch(adminRepositoryProvider).actions(),
);
final adminUsersProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>(
      (ref, q) =>
          ref.watch(adminRepositoryProvider).users(q.isEmpty ? null : q),
    );
