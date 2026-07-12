import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/card.dart';
import '../../core/prefs.dart';
import '../../core/supabase_providers.dart';
import 'cards_repository.dart';
import 'flippable_card.dart';

/// Étapes d'affichage d'une Card.
enum _Phase { loading, error, viewing, exhausted, destroyed }

/// Visionnage d'une Card.
/// - En chat (destinataire) : chaque ouverture consomme une vue, jauge de
///   lecture qui s'écoule si la durée est limitée, replay sur consentement.
/// - Hot : une seule vue, puis destruction et disparition du chat sans trace.
/// - En bibliothèque ou pour l'émetteur : lecture illimitée, sans jauge.
class CardViewerScreen extends ConsumerStatefulWidget {
  const CardViewerScreen({
    super.key,
    required this.card,
    this.fromLibrary = false,
  });

  final CardModel card;

  /// Ouvert depuis une bibliothèque : visionnage illimité (consigne Jay).
  final bool fromLibrary;

  @override
  ConsumerState<CardViewerScreen> createState() => _CardViewerScreenState();
}

class _CardViewerScreenState extends ConsumerState<CardViewerScreen> {
  var _phase = _Phase.loading;
  var _showFront = true;
  String? _frontUrl;
  String? _backUrl;
  String _error = '';
  CardDelivery? _delivery;

  /// Jauge de lecture : 1 → 0, s'écoule proportionnellement à la durée.
  Timer? _gaugeTimer;
  double _gauge = 1.0;
  int _elapsedMs = 0;
  var _hotFinished = false;

  bool get _isRecipient {
    final me = ref.read(currentUserIdProvider);
    return me != null && me != widget.card.ownerId;
  }

  /// Les limites (vues, durée) ne s'appliquent qu'au destinataire en chat.
  bool get _limitsApply => _isRecipient && !widget.fromLibrary;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _phase = _Phase.loading;
      _error = '';
    });
    final repo = ref.read(cardsRepositoryProvider);
    try {
      // URLs signées d'abord : c'est l'étape fragile côté réseau
      final front = await repo.imageUrl(widget.card.frontPath);
      // Mono : pas de verso
      final back = widget.card.backPath == null
          ? null
          : await repo.imageUrl(widget.card.backPath!);
      if (!mounted) return;
      _frontUrl = front;
      _backUrl = back;

      if (!_limitsApply) {
        setState(() => _phase = _Phase.viewing);
        return;
      }

      _delivery = await repo.myDelivery(widget.card.id);
      if (!mounted) return;
      if (_delivery == null) {
        // Pas de livraison pour moi (ne devrait pas arriver en chat)
        setState(() => _phase = _Phase.viewing);
        return;
      }
      if (_delivery!.destroyedAt != null) {
        setState(() => _phase = _Phase.destroyed);
        return;
      }
      final remaining = _delivery!.remainingViews(widget.card);
      if (remaining != null && remaining <= 0) {
        setState(() => _phase = _Phase.exhausted);
        return;
      }

      // Consomme une vue et démarre la lecture
      await repo.markViewed(_delivery!.id);
      if (!mounted) return;
      setState(() => _phase = _Phase.viewing);
      _startGauge();
    } catch (e) {
      if (!mounted) return;
      final text = e.toString();
      if (text.contains('Plus de visionnages')) {
        setState(() => _phase = _Phase.exhausted);
      } else if (text.contains('détruite') || text.contains('une fois')) {
        setState(() => _phase = _Phase.destroyed);
      } else {
        setState(() {
          _phase = _Phase.error;
          _error = text;
        });
      }
    }
  }

  void _startGauge() {
    final duration = widget.card.viewDurationSeconds;
    if (duration == null) return; // lecture illimitée : pas de jauge
    final totalMs = duration * 1000;
    _elapsedMs = 0;
    _gaugeTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!mounted) return;
      _elapsedMs += 50;
      setState(() => _gauge = 1.0 - (_elapsedMs / totalMs).clamp(0.0, 1.0));
      if (_elapsedMs >= totalMs) {
        _gaugeTimer?.cancel();
        _onViewTimeElapsed();
      }
    });
  }

  Future<void> _onViewTimeElapsed() async {
    if (widget.card.type == CardType.hot) {
      await _finishHot();
    } else {
      // Vue consommée : on montre l'état (vues restantes / replay)
      _delivery = await ref
          .read(cardsRepositoryProvider)
          .myDelivery(widget.card.id);
      if (!mounted) return;
      final remaining = _delivery?.remainingViews(widget.card);
      setState(
        () => _phase = (remaining != null && remaining <= 0)
            ? _Phase.exhausted
            : _Phase.viewing,
      );
      if (_phase == _Phase.viewing && mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  Future<void> _finishHot() async {
    if (_hotFinished || _delivery == null) return;
    _hotFinished = true;
    try {
      await ref.read(cardsRepositoryProvider).finishHotView(_delivery!.id);
    } catch (_) {}
    if (mounted) setState(() => _phase = _Phase.destroyed);
  }

  Future<void> _requestReplay() async {
    try {
      await ref.read(cardsRepositoryProvider).requestReplay(_delivery!.id);
      _delivery = await ref
          .read(cardsRepositoryProvider)
          .myDelivery(widget.card.id);
      if (mounted) setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
    }
  }

  @override
  void dispose() {
    _gaugeTimer?.cancel();
    // Hot : quitter l'écran, même avant la fin du temps, détruit la Card
    if (_limitsApply &&
        widget.card.type == CardType.hot &&
        !_hotFinished &&
        _delivery != null &&
        _phase == _Phase.viewing) {
      _hotFinished = true;
      ref.read(cardsRepositoryProvider).finishHotView(_delivery!.id);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final type = widget.card.type;
    final me = ref.watch(currentUserIdProvider);
    // Enregistrable : ses propres cards (Hot comprise, 1/1 exclue — le
    // créateur la rouvre depuis le chat à la place), ou une card reçue
    // marquée sauvegardable par son créateur.
    final isOwner = widget.card.ownerId == me;
    final canSave = isOwner
        ? type != CardType.oneOfOne
        : (widget.card.saveable && type.canBeSaveable);
    final isSaved = ref.watch(isCardSavedProvider(widget.card.id)).value;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: _TypeBadge(type: type),
        actions: [
          if (canSave && _phase == _Phase.viewing)
            IconButton(
              icon: Icon(
                isSaved == true ? Icons.bookmark : Icons.bookmark_border,
              ),
              tooltip: isSaved == true
                  ? 'Retirer de mes Enregistrements'
                  : 'Enregistrer pour moi',
              onPressed: () async {
                final repo = ref.read(cardsRepositoryProvider);
                try {
                  if (isSaved == true) {
                    await repo.unsaveCard(widget.card.id);
                  } else {
                    await repo.saveCard(widget.card.id);
                  }
                  ref.invalidate(isCardSavedProvider(widget.card.id));
                  ref.invalidate(savedCardsProvider);
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
                  }
                }
              },
            ),
        ],
        bottom:
            _phase == _Phase.viewing &&
                _limitsApply &&
                widget.card.viewDurationSeconds != null
            ? PreferredSize(
                preferredSize: const Size.fromHeight(6),
                // Jauge de lecture : s'écoule de gauche à droite (consigne Jay)
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: _gauge,
                    child: Container(height: 5, color: type.color),
                  ),
                ),
              )
            : null,
      ),
      body: switch (_phase) {
        _Phase.loading => const _LoadingState(),
        _Phase.error => _ErrorState(detail: _error, onRetry: _load),
        _Phase.destroyed => _EndState(
          icon: Icons.local_fire_department,
          color: type.color,
          message: type == CardType.hot
              ? 'Cette Card Hot a été vue.\nSon contenu a disparu — le container reste bloqué.'
              : 'Cette Card a été détruite.',
        ),
        _Phase.exhausted => _ExhaustedState(
          card: widget.card,
          delivery: _delivery,
          onReplayRequested: _requestReplay,
        ),
        // Mono : face unique non retournable, le jeu d'angle reste
        _Phase.viewing when _backUrl == null => Center(
          child: TiltableCard(
            child: _CardFace(url: _frontUrl!, type: type),
          ),
        ),
        _Phase.viewing => Center(
          child: FlippableCard(
            invertDrag: ref.watch(flipDirectionInvertedProvider),
            onSideChanged: (front) => setState(() => _showFront = front),
            front: _CardFace(url: _frontUrl!, type: type),
            back: _CardFace(url: _backUrl!, type: type),
          ),
        ),
      },
      bottomNavigationBar: _phase == _Phase.viewing
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  _backUrl == null
                      ? 'Face unique — fais glisser pour incliner la carte'
                      : _showFront
                      ? 'Recto — fais glisser pour retourner la carte'
                      : 'Verso — fais glisser pour revenir au recto',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white54),
                ),
              ),
            )
          : null,
    );
  }
}

class _TypeBadge extends StatelessWidget {
  const _TypeBadge({required this.type});
  final CardType type;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        gradient: type.gradient,
        border: type.gradient == null
            ? Border.all(color: type.color, width: 2)
            : null,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        type.tag,
        style: TextStyle(
          color: type.gradient == null ? type.color : Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: 16,
        ),
      ),
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 44,
            width: 44,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          SizedBox(height: 16),
          Text(
            'Chargement de la Card…',
            style: TextStyle(color: Colors.white54),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.detail, required this.onRetry});
  final String detail;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off, size: 56, color: Colors.white38),
            const SizedBox(height: 16),
            const Text(
              'Impossible de charger la Card.\nVérifie ta connexion.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Réessayer'),
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}

class _EndState extends StatelessWidget {
  const _EndState({
    required this.icon,
    required this.color,
    required this.message,
  });
  final IconData icon;
  final Color color;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 64, color: color),
          const SizedBox(height: 16),
          Text(message, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

/// Plus de vues disponibles : proposer la demande de replay
/// (accordée ou non par l'émetteur — jamais automatique).
class _ExhaustedState extends StatelessWidget {
  const _ExhaustedState({
    required this.card,
    required this.delivery,
    required this.onReplayRequested,
  });
  final CardModel card;
  final CardDelivery? delivery;
  final VoidCallback onReplayRequested;

  @override
  Widget build(BuildContext context) {
    final requested = delivery?.replayRequestedAt != null;
    final granted = delivery?.replayGrantedAt != null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.visibility_off, size: 56, color: card.type.color),
            const SizedBox(height: 16),
            const Text(
              'Tu as utilisé tous tes visionnages pour cette Card.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            if (granted)
              const Text(
                'Replay déjà utilisé.',
                style: TextStyle(color: Colors.white54),
              )
            else if (requested)
              const Text(
                'Replay demandé — en attente de l\'accord de l\'expéditeur.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54),
              )
            else
              FilledButton.tonal(
                onPressed: onReplayRequested,
                child: const Text('Demander un replay'),
              ),
          ],
        ),
      ),
    );
  }
}

/// Une face de la carte : image + cadre au liseré du type (dégradé pour
/// Oneshot/BeReal), avec gestion réseau propre (placeholder + erreur inline).
class _CardFace extends StatelessWidget {
  const _CardFace({required this.url, required this.type});
  final String url;
  final CardType type;

  @override
  Widget build(BuildContext context) {
    final borderWidth = type == CardType.oneOfOne ? 4.0 : 2.5;
    return Container(
      margin: const EdgeInsets.all(16),
      padding: EdgeInsets.all(borderWidth),
      decoration: BoxDecoration(
        gradient: type.gradient,
        color: type.gradient == null ? type.color : null,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(color: type.color.withValues(alpha: 0.35), blurRadius: 24),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(17),
        child: ColoredBox(
          color: Colors.black,
          child: Image.network(
            url,
            fit: BoxFit.contain,
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              return AspectRatio(
                aspectRatio: 3 / 4,
                child: Center(
                  child: CircularProgressIndicator(
                    value: progress.expectedTotalBytes == null
                        ? null
                        : progress.cumulativeBytesLoaded /
                              progress.expectedTotalBytes!,
                  ),
                ),
              );
            },
            errorBuilder: (context, error, stack) => const AspectRatio(
              aspectRatio: 3 / 4,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.broken_image, color: Colors.white38, size: 40),
                    SizedBox(height: 8),
                    Text(
                      'Image indisponible',
                      style: TextStyle(color: Colors.white54),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
