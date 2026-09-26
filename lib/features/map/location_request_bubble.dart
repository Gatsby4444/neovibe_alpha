import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/message.dart';
import '../connections/connections_repository.dart';
import '../../core/theme.dart';
import '../../core/utils/erreur_serveur.dart';
import '../../core/widgets/top_banner.dart';
import '../events/events_map_screen.dart';
import '../proximity/geo/live_position.dart';
import 'friends_map.dart';

/// **La demande de position, dans le chat** (Jay, 2026-09-26 : *« il doit
/// accepter pour révéler »*). Le message porte l'identifiant de la demande ;
/// son état vient du SERVEUR (`location_request_state`) — un message écrit
/// à la main ne fabrique pas de demande (le serveur le refuse).
///
/// - chez l'ami demandé, tant qu'il peut répondre : **Refuser** / **Accepter**
///   (accepter envoie sa position actuelle au seul demandeur, pour 1 h) ;
/// - chez le demandeur : où en est la demande, et, acceptée, un raccourci
///   vers la carte.
class LocationRequestBubble extends ConsumerStatefulWidget {
  const LocationRequestBubble({
    super.key,
    required this.message,
    required this.isMine,
  });

  final Message message;
  final bool isMine;

  @override
  ConsumerState<LocationRequestBubble> createState() =>
      _LocationRequestBubbleState();
}

class _LocationRequestBubbleState extends ConsumerState<LocationRequestBubble> {
  var _busy = false;

  String? get _id => widget.message.body;

  Future<void> _repondre(bool accepter) async {
    final id = _id;
    if (id == null || _busy) return;
    setState(() => _busy = true);
    try {
      double? lat, lon;
      var acc = 0.0;
      if (accepter) {
        final fix = await ref.read(livePositionProvider.notifier).current();
        if (fix == null) {
          if (mounted) {
            TopBanner.show(
              context,
              'Pas de position : active la localisation.',
              tone: TopBannerTone.already,
            );
          }
          return;
        }
        lat = fix.latitude;
        lon = fix.longitude;
        acc = fix.accuracy;
      }
      await ref
          .read(friendsMapRepositoryProvider)
          .answerLocationRequest(
            id,
            accept: accepter,
            lat: lat,
            lon: lon,
            acc: acc,
          );
      ref.invalidate(locationRequestStateProvider(id));
    } catch (e) {
      if (mounted) {
        TopBanner.show(context, messageServeur(e), tone: TopBannerTone.already);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final id = _id;
    final etat = id == null
        ? null
        : ref.watch(locationRequestStateProvider(id)).value;
    final autre = widget.isMine
        ? null
        : ref.watch(profileByIdProvider(widget.message.senderId)).value;
    final prenom = (autre?.displayName ?? '').split(' ').first;

    final titre = widget.isMine
        ? 'Tu as demandé sa position'
        : '${prenom.isEmpty ? 'Un ami' : prenom} te demande ta position';
    final sous = switch (etat?.etat) {
      null => 'Demande introuvable',
      LocationRequestEtat.enAttente =>
        widget.isMine ? 'En attente de sa réponse' : 'Elle expire dans 15 min',
      LocationRequestEtat.acceptee =>
        widget.isMine
            ? 'Acceptée : sa position est sur ta carte pendant 1 h'
            : 'Tu as partagé ta position (visible 1 h)',
      LocationRequestEtat.refusee => 'Refusée',
      LocationRequestEtat.expiree => 'Expirée',
    };
    final peutRepondre =
        !widget.isMine && etat?.etat == LocationRequestEtat.enAttente;

    return Container(
      constraints: const BoxConstraints(maxWidth: 280),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.action.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.my_location_rounded, color: p.action, size: 20),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  titre,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(sous, style: TextStyle(color: p.inkMuted, fontSize: 13)),
          if (peutRepondre) ...[
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _busy ? null : () => _repondre(false),
                  child: const Text('Refuser'),
                ),
                const SizedBox(width: 4),
                FilledButton(
                  onPressed: _busy ? null : () => _repondre(true),
                  child: const Text('Accepter'),
                ),
              ],
            ),
          ],
          if (widget.isMine && etat?.etat == LocationRequestEtat.acceptee)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const EventsMapScreen(),
                  ),
                ),
                icon: const Icon(Icons.map_outlined, size: 18),
                label: const Text('Voir sur la carte'),
              ),
            ),
        ],
      ),
    );
  }
}
