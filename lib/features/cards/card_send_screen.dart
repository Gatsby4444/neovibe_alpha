import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/card.dart';
import '../../core/prefs.dart';
import '../../core/supabase_providers.dart';
import '../connections/connections_repository.dart';
import 'cards_repository.dart';

/// Destination et paramètres d'une Card.
/// - classique/1of1/oneshot : vues (1-5, défaut selon réglages) et durée de
///   lecture (1-20 s ou illimitée, défaut selon réglages) choisies par le
///   créateur pour CETTE card ;
/// - Hot : figée à 1 vue, temps limité, aucune trace ;
/// - bibliothèque : lecture toujours illimitée (limites appliquées en chat
///   uniquement).
class CardSendScreen extends ConsumerStatefulWidget {
  const CardSendScreen({
    super.key,
    required this.front,
    required this.back,
    required this.type,
  });

  final File front;
  final File back;
  final CardType type;

  @override
  ConsumerState<CardSendScreen> createState() => _CardSendScreenState();
}

class _CardSendScreenState extends ConsumerState<CardSendScreen> {
  final _selected = <String>{};
  var _publish = false;
  var _loading = false;

  /// Les destinataires pourront l'enregistrer dans leurs Enregistrements.
  var _saveable = false;

  /// Copie privée dans MES Enregistrements (bibliothèque privée).
  var _saveForMe = false;

  /// Vues par card (1-5). Initialisé depuis les réglages.
  late int _maxViews = ref.read(defaultMaxViewsProvider);

  /// Durée de lecture : 1-20 s ; 21 = illimitée. Initialisé depuis les réglages.
  late int _durationSlider = _fromPref(ref.read(defaultViewDurationProvider));

  static int _fromPref(int pref) =>
      pref == DefaultViewDuration.unlimited ? 21 : pref;

  bool get _canPublish =>
      widget.type != CardType.oneOfOne && widget.type != CardType.hot;

  bool get _configurable => widget.type.hasConfigurableViews;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowExplainer());
  }

  /// Popup de première utilisation : règles de visionnage (consigne Jay).
  Future<void> _maybeShowExplainer() async {
    if (ref.read(cardsExplainerShownProvider)) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Comment vivent tes Cards'),
        content: const SingleChildScrollView(
          child: Text(
            'Dans les chats, une Card se voit un nombre limité de fois '
            '(2 par défaut) et pendant une durée limitée par vue (10 s par '
            'défaut) — tu choisis ces limites pour chaque Card, et tes '
            'défauts se règlent dans Réglages > Cards.\n\n'
            'Une trace reste dans le chat 24 h et le destinataire peut te '
            'demander un replay : rien ne se revoit sans ton accord.\n\n'
            'La Hot, elle, se voit UNE fois, un court instant, puis disparaît '
            'du chat sans laisser de trace.\n\n'
            'Dans ta bibliothèque, ce que tu publies se regarde sans limite.',
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Compris'),
          ),
        ],
      ),
    );
    await ref.read(cardsExplainerShownProvider.notifier).markShown();
  }

  Future<void> _send() async {
    if (_selected.isEmpty && !_publish && !_saveForMe) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Choisis au moins un destinataire, publie ou enregistre pour toi.',
          ),
        ),
      );
      return;
    }
    setState(() => _loading = true);
    try {
      final repo = ref.read(cardsRepositoryProvider);
      final card = await repo.create(
        front: widget.front,
        back: widget.back,
        type: widget.type,
        viewDurationSeconds: _durationSlider == 21 ? null : _durationSlider,
        maxViews: _maxViews,
        saveable: _saveable,
      );
      if (_selected.isNotEmpty) {
        await repo.send(card, _selected.toList());
      }
      if (_publish) {
        await repo.publishToLibrary(card);
      }
      if (_saveForMe) {
        await repo.saveCard(card.id);
      }
      if (mounted) {
        Navigator.of(context).popUntil((r) => r.isFirst);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Card envoyée ✓')));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(currentUserIdProvider)!;
    final connections = ref.watch(fullConnectionsProvider);
    final singleRecipient = widget.type == CardType.oneOfOne;
    final type = widget.type;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('Envoyer '),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                gradient: type.gradient,
                border: type.gradient == null
                    ? Border.all(color: type.color)
                    : null,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                type.tag,
                style: TextStyle(
                  color: type.gradient == null ? type.color : Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          if (singleRecipient)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Card exclusive : un seul destinataire, pour toujours.',
                style: TextStyle(color: Color(0xFFD4AF37)),
              ),
            ),
          if (type == CardType.hot)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'Hot : une seule vue, temps limité, aucune trace après.',
                style: TextStyle(color: type.color),
              ),
            ),
          if (_configurable) ...[
            ListTile(
              dense: true,
              title: Text('Visionnages : $_maxViews'),
              subtitle: Slider(
                value: _maxViews.toDouble(),
                min: 1,
                max: 5,
                divisions: 4,
                label: '$_maxViews',
                onChanged: (v) => setState(() => _maxViews = v.round()),
              ),
            ),
            ListTile(
              dense: true,
              title: Text(
                _durationSlider == 21
                    ? 'Durée de lecture : illimitée'
                    : 'Durée de lecture : $_durationSlider s',
              ),
              subtitle: Slider(
                value: _durationSlider.toDouble(),
                min: 1,
                max: 21,
                divisions: 20,
                label: _durationSlider == 21 ? '∞' : '$_durationSlider s',
                onChanged: (v) => setState(() => _durationSlider = v.round()),
              ),
            ),
          ],
          if (_canPublish)
            SwitchListTile(
              title: const Text('Publier dans ma bibliothèque'),
              subtitle: const Text(
                'Là-bas, lecture illimitée — visible selon tes règles d\'accès',
              ),
              value: _publish,
              onChanged: (v) => setState(() => _publish = v),
            ),
          if (type.canBeSaveable)
            SwitchListTile(
              title: const Text('Sauvegardable'),
              subtitle: const Text(
                'Les destinataires pourront la garder dans leurs Enregistrements',
              ),
              value: _saveable,
              onChanged: (v) => setState(() => _saveable = v),
            ),
          if (type != CardType.hot)
            SwitchListTile(
              title: const Text('Enregistrer pour moi'),
              subtitle: const Text(
                'Copie privée dans mes Enregistrements, visible de moi seul',
              ),
              value: _saveForMe,
              onChanged: (v) => setState(() => _saveForMe = v),
            ),
          const Divider(),
          Expanded(
            child: connections.isEmpty
                ? const Center(
                    child: Text(
                      'Aucune connexion à qui envoyer.',
                      style: TextStyle(color: Colors.white54),
                    ),
                  )
                : ListView(
                    children: [
                      for (final connection in connections)
                        _RecipientTile(
                          peerId: connection.peerIdFor(me),
                          selected: _selected.contains(
                            connection.peerIdFor(me),
                          ),
                          onChanged: (checked) => setState(() {
                            final id = connection.peerIdFor(me);
                            if (checked) {
                              if (singleRecipient) _selected.clear();
                              _selected.add(id);
                            } else {
                              _selected.remove(id);
                            }
                          }),
                        ),
                    ],
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton(
                onPressed: _loading ? null : _send,
                child: _loading
                    ? const SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Envoyer'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RecipientTile extends ConsumerWidget {
  const _RecipientTile({
    required this.peerId,
    required this.selected,
    required this.onChanged,
  });
  final String peerId;
  final bool selected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileByIdProvider(peerId)).value;
    return CheckboxListTile(
      value: selected,
      onChanged: (v) => onChanged(v ?? false),
      title: Text(profile?.displayName ?? '…'),
      secondary: CircleAvatar(
        backgroundImage: profile?.avatarUrl == null
            ? null
            : NetworkImage(profile!.avatarUrl!),
        child: profile?.avatarUrl == null
            ? Text((profile?.displayName ?? '?').characters.first.toUpperCase())
            : null,
      ),
    );
  }
}
