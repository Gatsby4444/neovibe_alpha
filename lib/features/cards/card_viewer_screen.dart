import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/card.dart';
import '../../core/prefs.dart';
import '../../core/supabase_providers.dart';
import 'cards_repository.dart';
import 'flippable_card.dart';

/// Visionnage d'une Card : recto/verso (tap pour retourner), avec les règles
/// par type — Oneshot : minuteur visible puis destruction définitive ;
/// Hot : fenêtre courte (l'aperçu s'estompe sans destruction).
class CardViewerScreen extends ConsumerStatefulWidget {
  const CardViewerScreen({super.key, required this.card});
  final CardModel card;

  @override
  ConsumerState<CardViewerScreen> createState() => _CardViewerScreenState();
}

class _CardViewerScreenState extends ConsumerState<CardViewerScreen> {
  var _showFront = true;
  String? _frontUrl;
  String? _backUrl;
  CardDelivery? _delivery;
  var _destroyed = false;

  /// Oneshot : secondes restantes. Hot : fenêtre avant estompage.
  Timer? _timer;
  int _remaining = 0;
  double _hotOpacity = 1.0;

  bool get _isRecipient {
    final me = ref.read(currentUserIdProvider);
    return me != null && me != widget.card.ownerId;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = ref.read(cardsRepositoryProvider);
    try {
      final front = await repo.imageUrl(widget.card.frontPath);
      final back = await repo.imageUrl(widget.card.backPath);
      if (!mounted) return;
      setState(() {
        _frontUrl = front;
        _backUrl = back;
      });

      if (_isRecipient) {
        _delivery = await repo.myDelivery(widget.card.id);
        if (_delivery != null) {
          await repo.markViewed(_delivery!.id);
        }
        _startTypeRules();
      }
    } catch (e) {
      if (mounted) setState(() => _destroyed = true);
    }
  }

  void _startTypeRules() {
    switch (widget.card.type) {
      case CardType.oneshot:
        _remaining = widget.card.viewDurationSeconds ?? 3;
        _timer = Timer.periodic(const Duration(seconds: 1), (_) async {
          if (!mounted) return;
          setState(() => _remaining--);
          if (_remaining <= 0) {
            _timer?.cancel();
            await _destroyOneshot();
          }
        });
      case CardType.hot:
        // Fenêtre courte : 8 s puis l'aperçu s'estompe, sans destruction.
        _timer = Timer(const Duration(seconds: 8), () {
          if (mounted) setState(() => _hotOpacity = 0.15);
        });
      default:
        break;
    }
  }

  Future<void> _destroyOneshot() async {
    if (_delivery == null) return;
    try {
      await ref.read(cardsRepositoryProvider).destroyOneshot(_delivery!.id);
    } catch (_) {}
    if (mounted) {
      setState(() => _destroyed = true);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    // Oneshot : fermer l'écran avant la fin du minuteur détruit aussi la Card
    if (_isRecipient &&
        widget.card.type == CardType.oneshot &&
        !_destroyed &&
        _delivery != null) {
      ref.read(cardsRepositoryProvider).destroyOneshot(_delivery!.id);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final type = widget.card.type;

    if (_destroyed) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.local_fire_department, size: 64, color: type.color),
              const SizedBox(height: 16),
              const Text(
                'Cette Card a été détruite.\nElle n\'existe plus, nulle part.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            border: Border.all(color: type.color, width: 2),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            type.tag,
            style: TextStyle(
              color: type.color,
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
        ),
        actions: [
          if (type == CardType.oneshot && _isRecipient && _remaining > 0)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text(
                  '$_remaining s',
                  style: TextStyle(
                    color: type.color,
                    fontWeight: FontWeight.bold,
                    fontSize: 20,
                  ),
                ),
              ),
            ),
        ],
      ),
      body: Center(
        child: _frontUrl == null || _backUrl == null
            ? const CircularProgressIndicator()
            : AnimatedOpacity(
                duration: const Duration(milliseconds: 600),
                opacity: type == CardType.hot ? _hotOpacity : 1.0,
                // Retournement physique : le doigt incline la carte,
                // un swipe (ou un angle suffisant) la retourne (consigne Jay)
                child: FlippableCard(
                  invertDrag: ref.watch(flipDirectionInvertedProvider),
                  onSideChanged: (front) => setState(() => _showFront = front),
                  front: _CardFace(url: _frontUrl!, type: type),
                  back: _CardFace(url: _backUrl!, type: type),
                ),
              ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            _showFront
                ? 'Recto — fais glisser pour retourner la carte'
                : 'Verso — fais glisser pour revenir au recto',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54),
          ),
        ),
      ),
    );
  }
}

/// Une face de la carte : image + cadre au liseré du type (embarqué dans la
/// face pour que le cadre se retourne avec la carte).
class _CardFace extends StatelessWidget {
  const _CardFace({required this.url, required this.type});
  final String url;
  final CardType type;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: type.color,
          width: type == CardType.oneOfOne ? 4 : 2,
        ),
        boxShadow: type == CardType.oneOfOne
            ? [
                BoxShadow(
                  color: type.color.withValues(alpha: 0.4),
                  blurRadius: 24,
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Image.network(url, fit: BoxFit.contain),
      ),
    );
  }
}
