import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/diagnostics/card_rules_trace.dart';

/// **Inspecteur de règles** — ce que le serveur dit, ce que l'écran a décidé,
/// et ce qui s'est réellement passé.
///
/// Demande de Jay le 2026-08-13 : pouvoir « voir pour une card ses règles et
/// comparer avec mes actions et ce que je vois, pour vérifier si elles sont
/// respectées ».
///
/// ### Ce qu'il faut regarder en premier
///
/// La ligne de verdict. Une ouverture doit consommer **exactement une** vue :
/// `0` signifierait que la limite n'est pas une garantie, `2` qu'elle se
/// consomme deux fois plus vite que promis. Tout le reste est du contexte pour
/// comprendre un verdict rouge.
///
/// ⚠️ **Outil de développement** — à retirer avec la section Développeur avant
/// la prod (voir `RAPPELS.md`, avant-prod #4).
class RulesInspectorScreen extends StatefulWidget {
  const RulesInspectorScreen({super.key});

  @override
  State<RulesInspectorScreen> createState() => _RulesInspectorScreenState();
}

class _RulesInspectorScreenState extends State<RulesInspectorScreen> {
  Future<void> _copy() async {
    final text = CardRulesTrace.records.map((r) => r.describe()).join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Règles copiées')));
  }

  @override
  Widget build(BuildContext context) {
    final records = CardRulesTrace.records;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Règles des Vibes'),
        actions: [
          IconButton(
            tooltip: 'Copier',
            icon: const Icon(Icons.copy_all),
            onPressed: records.isEmpty ? null : _copy,
          ),
          IconButton(
            tooltip: 'Vider',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => setState(CardRulesTrace.clear),
          ),
          IconButton(
            tooltip: 'Rafraîchir',
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() {}),
          ),
        ],
      ),
      body: records.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Aucune ouverture.\n\nOuvre une Vibe reçue en conversation, '
                  'ferme l\'écran, puis reviens ici.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                for (final record in records) _RecordCard(record: record),
              ],
            ),
    );
  }
}

class _RecordCard extends StatelessWidget {
  const _RecordCard({required this.record});

  final CardRulesTrace record;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final verdict = record.countingOk;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  verdict == null
                      ? Icons.remove_circle_outline
                      : verdict
                      ? Icons.verified
                      : Icons.error,
                  size: 18,
                  color: verdict == null
                      ? null
                      : verdict
                      ? Colors.green
                      : Colors.red,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    record.cardType,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                Text(record.phase ?? '—', style: theme.textTheme.bodySmall),
              ],
            ),
            Text(record.cardId, style: theme.textTheme.bodySmall),
            const Divider(height: 16),

            _Line(
              'Serveur',
              'max ${record.maxViews ?? '∞'} vue(s) · '
                  '${record.viewDurationSeconds ?? '∞'} s/face · '
                  'enregistrable ${_yn(record.saveable)} · '
                  'scrub ${_yn(record.scrubbable)} · '
                  'chiffrée ${_yn(record.encrypted)}',
            ),
            _Line(
              'Livraison',
              'vues ${record.viewCountBefore ?? '?'} → '
                  '${record.viewCountAfter ?? '?'}'
                  '${record.consumed == null ? '' : '  (consommé ${record.consumed})'}'
                  '${record.replayGranted == true ? ' · replay accordé' : ''}'
                  '${record.destroyed == true ? ' · DÉTRUITE' : ''}',
            ),
            _Line(
              'Écran',
              'limites ${_yn(record.limitsApply)} · '
                  'restant avant ${record.remainingBefore ?? '∞'}',
            ),
            if (record.faceMs.isNotEmpty)
              _Line(
                'Observé',
                record.faceMs.entries
                    .map(
                      (e) =>
                          '${e.key} ${(e.value / 1000).toStringAsFixed(1)} s',
                    )
                    .join(' · '),
              ),

            if (verdict != null) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: (verdict ? Colors.green : Colors.red).withValues(
                    alpha: 0.12,
                  ),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  verdict
                      ? '✅ Décompte conforme — 1 vue pour 1 ouverture'
                      : '❌ Décompte anormal — ${record.consumed} vue(s) pour '
                            'une seule ouverture',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],

            if (record.events.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Déroulé', style: theme.textTheme.labelSmall),
              for (final event in record.events)
                Padding(
                  padding: const EdgeInsets.only(left: 8, top: 2),
                  child: Text(
                    '${event.at.toIso8601String().substring(11, 19)}  '
                    '${event.label}'
                    '${event.detail == null ? '' : ' — ${event.detail}'}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  static String _yn(bool? value) =>
      value == null ? '?' : (value ? 'oui' : 'non');
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 74,
          child: Text(label, style: Theme.of(context).textTheme.labelSmall),
        ),
        Expanded(
          child: Text(value, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    ),
  );
}
