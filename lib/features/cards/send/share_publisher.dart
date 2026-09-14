import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/content/saved_store.dart';
import '../../../core/models/card.dart';
import '../../conversations/conversations_repository.dart';
import '../../library/library_repository.dart';
import '../../library_vibes/library_vibes_repository.dart';
import '../../proximity/net/crossed_repository.dart';
import '../../stories/stories_repository.dart';
import '../cards_repository.dart';
import 'share_plan.dart';
import 'vibe_draft.dart';

/// Le sort d'UNE destination.
class ShareOutcome {
  const ShareOutcome({required this.cle, required this.label, this.erreur});

  /// **Quelle destination**, sans ambiguïté — c'est ce que « Réessayer »
  /// renvoie au plan (voir [SharePlan.restreintA]). Le libellé, lui, est fait
  /// pour être lu, pas pour être comparé.
  final String cle;

  /// Ce que l'utilisateur a coché, dit avec ses mots.
  final String label;

  /// `null` = parti.
  final Object? erreur;

  bool get reussi => erreur == null;
}

/// Ce qui est parti, et ce qui ne l'est pas.
///
/// ⚠️ **On rend une LISTE, pas un booléen.** Un envoi vers quatre destinations
/// peut réussir trois fois et échouer une : répondre « ça a échoué » ferait
/// renvoyer les trois qui sont déjà parties, et répondre « ça a marché »
/// perdrait la quatrième en silence. Les deux sont faux.
class ShareResult {
  const ShareResult(this.outcomes);

  final List<ShareOutcome> outcomes;

  List<ShareOutcome> get reussites => [
    for (final o in outcomes)
      if (o.reussi) o,
  ];
  List<ShareOutcome> get echecs => [
    for (final o in outcomes)
      if (!o.reussi) o,
  ];

  bool get toutEstParti => echecs.isEmpty && outcomes.isNotEmpty;
  bool get rienNEstParti => reussites.isEmpty;
}

/// Reçoit chaque destination dès qu'elle est réglée — c'est ce qui fait
/// avancer le bandeau « Envoi… 1/3 » pendant que l'utilisateur est déjà
/// revenu à la caméra.
typedef ShareProgress = void Function(ShareOutcome outcome);

/// **Exécute un [SharePlan] : un geste, plusieurs objets.**
///
/// ## 🔴 Ce que ça remplace
///
/// Quatre écrans de paramétrage qui envoyaient chacun le leur, avec quatre
/// gestions d'erreur, quatre navigations de sortie et quatre messages de
/// succès. Envoyer la même prise en story ET à deux amis demandait de refaire
/// tout le parcours — capture comprise, puisque chaque envoi ramenait à
/// l'accueil.
///
/// ## ⚠️ Ce que cette classe ne fait PAS, et c'est délibéré
///
/// Elle ne **décide** rien. Les règles de cohérence vivent dans
/// [SharePlan.problemes], qui est pur et éprouvé ; ici il ne reste que
/// l'exécution. Mélanger les deux, c'est se retrouver avec une règle qu'on ne
/// peut vérifier qu'en envoyant vraiment quelque chose.
///
/// ## ⚠️ Un objet par contexte, jamais un fichier partagé
///
/// Chaque destination crée **son** objet, avec **ses** octets et **sa** clé.
/// C'est le prix de la séparation du 2026-08-11, assumé par Jay le 2026-08-30
/// (*« on garde l'option 1 comme aujourd'hui »*), et [SharePlan.televersements]
/// le dit à l'utilisateur avant qu'il appuie.
///
/// Depuis le 2026-09-14 elle tourne **en arrière-plan** (voir `ShareQueue`) :
/// elle ne navigue pas, ne dessine pas, et rapporte chaque destination au fil
/// de l'eau par [ShareProgress].
class SharePublisher {
  const SharePublisher(this.ref);
  final Ref ref;

  Future<ShareResult> run(
    VibeDraft draft,
    SharePlan plan, {
    ShareProgress? onProgress,
  }) async {
    final outcomes = <ShareOutcome>[];
    void note(ShareOutcome o) {
      outcomes.add(o);
      onProgress?.call(o);
    }

    // La copie locale (« Enregistrer pour moi ») est rangée sous un
    // identifiant local : elle prend le premier vrai identifiant créé, pour que
    // la révocation de modération puisse la retrouver.
    String? premierId;
    Future<void> rekey(String id) async {
      if (premierId != null) return;
      premierId = id;
      try {
        await ref.read(savedStoreProvider).rekey(draft.localId, id);
        ref.invalidate(savedItemsProvider);
      } catch (_) {
        // Une copie locale qui garde son identifiant local reste lisible ;
        // elle échappe seulement à la révocation par identifiant serveur.
      }
    }

    // ⚠️ **La story d'abord, puis la bibliothèque, puis les gens.** L'ordre
    // n'est pas cosmétique : si le réseau lâche en route, ce qui est parti est
    // ce qui coûte le plus cher à refaire à la main. Un envoi à un ami se
    // recommence en deux gestes depuis le chat ; une story se recommence par
    // une capture.
    final story = plan.story;
    if (story != null) {
      note(
        await _tente(SharePlan.cleStory, 'Ma story', () async {
          final id = await ref
              .read(storiesRepositoryProvider)
              .publish(
                front: draft.front,
                back: draft.back,
                type: draft.type,
                frontIsVideo: draft.frontIsVideo,
                backIsVideo: draft.backIsVideo,
                shareable: story.shareable,
                saveable: story.saveable && draft.type.canBeSaveable,
                minTier: story.tier,
              );
          await rekey(id);
        }),
      );
    }

    final library = plan.library;
    if (library != null) {
      note(
        await _tente(SharePlan.cleLibrary, 'Ma bibliothèque', () async {
          final id = await ref
              .read(libraryRepositoryProvider)
              .publish(
                front: draft.front,
                back: draft.back,
                type: draft.type,
                frontIsVideo: draft.frontIsVideo,
                backIsVideo: draft.backIsVideo,
                caption: library.caption,
                isPublic: library.isPublic,
                shareable: library.shareable,
                saveable: library.saveable && draft.type.canBeSaveable,
              );
          await rekey(id);
        }),
      );
    }

    // ⚠️ **UNE Card par LOT DE RÉGLAGES**, pas une par personne ni une pour
    // tout le monde. Une Card ne porte qu'un `saveable` : deux personnes qui
    // n'ont pas le même en demandent deux, et c'est exactement ce que
    // [SharePlan.televersements] a annoncé à l'utilisateur avant qu'il appuie.
    //
    // ⚠️ **Les croisés voyagent gratuitement dans le lot non sauvegardable** :
    // ils n'ont droit à aucune sauvegarde, donc ils n'ouvrent jamais un lot à
    // eux seuls quand un ami non sauvegardable existe déjà.
    final cards = ref.read(cardsRepositoryProvider);
    for (final lot in plan.lotsDeCercle) {
      final CardModel card;
      try {
        card = await cards.create(
          front: draft.front,
          back: draft.back,
          type: draft.type,
          maxViews: plan.regles.maxViews,
          // Pas de face photo, ou Oneshot = pas de limite de durée, quel que
          // soit le défaut des Réglages. Une durée absente = illimitée pour
          // le visionneur, rien à changer de son côté.
          viewDurationSeconds: draft.acceptsDuration
              ? plan.regles.viewDurationSeconds
              : null,
          saveable: lot.saveable && draft.type.canBeSaveable,
          imported: draft.imported,
          frontIsVideo: draft.frontIsVideo,
          backIsVideo: draft.backIsVideo,
          scrubbable: draft.hasVideo && plan.regles.scrubbable,
        );
        await rekey(card.id);
      } catch (e) {
        // La Card n'existe pas : personne de ce lot ne peut être servi. On le
        // dit une fois par destination, pas une fois pour tout l'envoi — sinon
        // l'utilisateur ne saurait pas QUI n'a rien reçu.
        for (final c in lot.conversations) {
          note(ShareOutcome(cle: c.cleChat, label: c.label, erreur: e));
        }
        for (final c in lot.crossed) {
          note(ShareOutcome(cle: c.cle, label: c.label, erreur: e));
        }
        continue;
      }
      for (final conv in lot.conversations) {
        note(
          await _tente(conv.cleChat, conv.label, () async {
            await cards.sendToConversation(
              card,
              await _conversationDe(conv),
              conv.memberIds,
            );
          }),
        );
      }
      for (final croise in lot.crossed) {
        note(
          await _tente(croise.cle, croise.label, () async {
            await cards.sendToCrossed(card, croise.userId);
          }),
        );
      }
    }

    // 📚 La bibliothèque d'une conversation : un objet de plus, avec ses
    // propres octets — que la ligne ait aussi la cible 💬 ou non.
    for (final conv in plan.conversations.where(
      (c) => c.aussiDansLaBibliotheque,
    )) {
      note(
        await _tente(conv.cleLibrary, '${conv.label} · Drop', () async {
          await ref
              .read(libraryVibesRepositoryProvider)
              .addVibe(
                conversationId: await _conversationDe(conv),
                type: draft.type,
                source: draft.front,
                isVideo: draft.frontIsVideo,
                back: draft.back,
                backIsVideo: draft.backIsVideo,
                saveableByOthers: conv.saveable,
              );
        }),
      );
    }

    // ⚠️ **L'invalidation appartient à l'ÉCRITURE, jamais à l'appelant**
    // (`CLAUDE.md`, 2026-08-25). Envoyer à un croisé crée une demande d'ami :
    // sa ligne doit désormais dire « demande déjà envoyée ». Laisser l'écran
    // s'en charger ferait dépendre l'état affiché de QUI a écrit — et le jour
    // où un second écran enverra à un croisé, l'un montrerait du périmé.
    if (plan.crossed.isNotEmpty) ref.invalidate(crossedRecentlyProvider);
    return ShareResult(outcomes);
  }

  /// La conversation d'une ligne — ouverte à l'instant s'il s'agit d'un ami
  /// avec qui on n'a jamais discuté. Même DM d'une fois sur l'autre :
  /// `get_or_create_direct_conversation` est idempotente.
  Future<String> _conversationDe(ConversationShare conv) async =>
      conv.conversationId ??
      await ref
          .read(conversationsRepositoryProvider)
          .getOrCreateDirect(conv.peerId!);

  /// ⚠️ **Chaque destination échoue SEULE.** Une exception qui remonterait
  /// abandonnerait les destinations suivantes sans les tenter — et
  /// l'utilisateur croirait que rien n'est parti alors que sa story est en
  /// ligne.
  Future<ShareOutcome> _tente(
    String cle,
    String label,
    Future<void> Function() geste,
  ) async {
    try {
      await geste();
      return ShareOutcome(cle: cle, label: label);
    } catch (e) {
      return ShareOutcome(cle: cle, label: label, erreur: e);
    }
  }
}

final sharePublisherProvider = Provider((ref) => SharePublisher(ref));
