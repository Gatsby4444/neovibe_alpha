import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../content/moderation.dart';
import '../theme.dart';

/// Feuille de signalement, commune aux contenus et aux profils.
///
/// Trois principes tenus ici :
/// - **un signalement doit être rapide** — cinq motifs, un champ libre
///   facultatif, deux touches suffisent ;
/// - **on ne dit jamais à l'auteur qu'il a été signalé**, ni combien de fois ;
/// - **on propose le blocage dans la foulée**, parce que signaler sans pouvoir
///   se protéger tout de suite laisse la personne exposée en attendant qu'un
///   humain regarde.
Future<void> showReportSheet(
  BuildContext context,
  WidgetRef ref, {
  String? contentId,
  required String targetUserId,
  String? targetName,
}) async {
  final result = await showModalBottomSheet<({ReportReason r, String d})>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF16161C),
    builder: (_) => _ReportSheet(isContent: contentId != null),
  );
  if (result == null || !context.mounted) return;

  final repo = ref.read(moderationRepositoryProvider);
  try {
    if (contentId != null) {
      await repo.reportContent(contentId, result.r, details: result.d);
    } else {
      await repo.reportProfile(targetUserId, result.r, details: result.d);
    }
  } catch (e) {
    if (!context.mounted) return;
    // Un doublon (déjà signalé) n'est pas une erreur pour l'utilisateur : son
    // signalement est bien enregistré, c'est tout ce qui l'intéresse.
    final already = e.toString().contains('duplicate');
    if (!already) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
      return;
    }
  }
  if (!context.mounted) return;

  final blockToo = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Signalement envoyé'),
      content: Text(
        'Merci. Personne ne saura que ça vient de toi.\n\n'
        'Veux-tu aussi bloquer ${targetName ?? 'cette personne'} ? '
        'Vous ne verrez plus vos contenus respectifs, et aucun partage ne '
        'pourra vous relier.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Non, merci'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Bloquer aussi'),
        ),
      ],
    ),
  );
  if (blockToo != true || !context.mounted) return;

  await ref.read(moderationRepositoryProvider).block(targetUserId);
  ref.invalidate(blockedProfilesProvider);
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${targetName ?? 'Cette personne'} est bloquée.')),
    );
  }
}

class _ReportSheet extends StatefulWidget {
  const _ReportSheet({required this.isContent});
  final bool isContent;

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  ReportReason? _reason;
  final _details = TextEditingController();

  @override
  void dispose() {
    _details.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
              child: Text(
                widget.isContent ? 'Signaler ce contenu' : 'Signaler ce profil',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                'Ton signalement est anonyme.',
                style: TextStyle(fontSize: 12.5, color: context.muted),
              ),
            ),
            // `RadioGroup` et non `groupValue`/`onChanged` par radio : ces
            // deux-là sont dépréciés depuis Flutter 3.32, et le reste du
            // projet emploie déjà la nouvelle forme (`settings_screen`).
            RadioGroup<ReportReason>(
              groupValue: _reason,
              onChanged: (v) => setState(() => _reason = v),
              child: Column(
                children: [
                  for (final reason in ReportReason.values)
                    RadioListTile<ReportReason>(
                      dense: true,
                      value: reason,
                      title: Text(reason.label),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: TextField(
                controller: _details,
                maxLines: 3,
                maxLength: 500,
                decoration: const InputDecoration(
                  hintText: 'Préciser (facultatif)',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _reason == null
                      ? null
                      : () => Navigator.pop(context, (
                          r: _reason!,
                          d: _details.text.trim(),
                        )),
                  child: const Text('Envoyer le signalement'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
