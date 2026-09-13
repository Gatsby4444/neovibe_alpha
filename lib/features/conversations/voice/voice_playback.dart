import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../conversations_repository.dart';
import 'voice_media_cache.dart';

/// Ce qu'il faut au lecteur natif pour écouter un vocal : où sont les blocs,
/// avec quoi les lire, et où garder ceux qui ont servi.
class VoiceSource {
  const VoiceSource({
    required this.url,
    required this.key,
    required this.cachePath,
  });
  final String url;
  final String key;
  final String cachePath;
}

/// Identité d'un vocal à ouvrir : le message, et le chemin de son média.
typedef VoiceRef = ({String messageId, String mediaPath});

/// **Le serveur** entre le dépôt et la bulle : prépare une écoute.
///
/// Trois choses, dans l'ordre : le balayage du cache (ce qui a plus de 24 h
/// s'en va), la clé (`open_voice_message` — refusée si on n'est plus membre ou
/// si le message a expiré), l'URL signée du bucket `media`. La bulle ne parle
/// ni au réseau, ni au disque : elle demande ceci, et joue.
///
/// `autoDispose` : la clé n'a pas à rester en mémoire après l'écran. Elle
/// n'est jamais écrite sur le disque.
final voiceSourceProvider = FutureProvider.autoDispose
    .family<VoiceSource, VoiceRef>((ref, voice) async {
      final repo = ref.watch(conversationsRepositoryProvider);
      final cache = ref.watch(voiceMediaCacheProvider);
      await cache.sweep();
      final key = await repo.voiceKey(voice.messageId);
      final url = await repo.mediaUrl(voice.mediaPath);
      return VoiceSource(
        url: url,
        key: key,
        cachePath: await cache.pathFor(voice.messageId),
      );
    });
