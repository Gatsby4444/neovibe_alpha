import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/card.dart';
import '../../library/library_repository.dart';
import '../../proximity/net/crossed_repository.dart';
import '../../library_vibes/library_vibes_repository.dart';
import '../../stories/stories_repository.dart';
import '../cards_repository.dart';
import 'share_plan.dart';
import 'vibe_draft.dart';

/// Le sort d'UNE destination.
class ShareOutcome {
  const ShareOutcome({required this.label, this.erreur});

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
class SharePublisher {
  const SharePublisher(this.ref);

  final Ref ref;

  Future<ShareResult> run(VibeDraft draft, SharePlan plan) async {
    final outcomes = <ShareOutcome>[];

    // ⚠️ **La story d'abord, puis la bibliothèque, puis les gens.** L'ordre
    // n'est pas cosmétique : si le réseau lâche en route, ce qui est parti est
    // ce qui coûte le plus cher à refaire à la main. Un envoi à un ami se
    // recommence en deux gestes depuis le chat ; une story se recommence par
    // une capture.
    final story = plan.story;
    if (story != null) {
      outcomes.add(
        await _tente('Ma story', () async {
          await ref
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
        }),
      );
    }

    final library = plan.library;
    if (library != null) {
      outcomes.add(
        await _tente('Ma bibliothèque', () async {
          await ref
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
          viewDurationSeconds: plan.regles.viewDurationSeconds,
          saveable: lot.saveable && draft.type.canBeSaveable,
          imported: draft.imported,
          frontIsVideo: draft.frontIsVideo,
          backIsVideo: draft.backIsVideo,
        );
      } catch (e) {
        // La Card n'existe pas : personne de ce lot ne peut être servi. On le
        // dit une fois par destination, pas une fois pour tout l'envoi — sinon
        // l'utilisateur ne saurait pas QUI n'a rien reçu.
        for (final c in lot.conversations) {
          outcomes.add(ShareOutcome(label: c.label, erreur: e));
        }
        for (final c in lot.crossed) {
          outcomes.add(ShareOutcome(label: c.label, erreur: e));
        }
        continue;
      }

      for (final conv in lot.conversations) {
        outcomes.add(
          await _tente(conv.label, () async {
            await cards.sendToConversation(
              card,
              conv.conversationId,
              conv.memberIds,
            );
          }),
        );
        if (conv.aussiDansLaBibliotheque) {
          outcomes.add(
            await _tente('${conv.label} · bibliothèque', () async {
              await ref
                  .read(libraryVibesRepositoryProvider)
                  .addVibe(
                    conversationId: conv.conversationId,
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
      }

      for (final croise in lot.crossed) {
        outcomes.add(
          await _tente(croise.label, () async {
            await cards.sendToCrossed(card, croise.userId);
          }),
        );
      }
    }

    // ⚠️ **L'invalidation appartient à l'ÉCRITURE, jamais à l'appelant**
    // (`CLAUDE.md`, 2026-08-25). Envoyer à un croisé crée une demande d'ami :
    // sa ligne doit désormais dire « demande déjà envoyée ». Laisser l'écran
    // s'en charger ferait dépendre l'état affiché de QUI a écrit — et le jour
    // où un second écran enverra à un croisé, l'un montrerait du périmé.
    if (plan.crossed.isNotEmpty) ref.invalidate(crossedRecentlyProvider);

    return ShareResult(outcomes);
  }

  /// ⚠️ **Chaque destination échoue SEULE.** Une exception qui remonterait
  /// abandonnerait les destinations suivantes sans les tenter — et
  /// l'utilisateur croirait que rien n'est parti alors que sa story est en
  /// ligne.
  Future<ShareOutcome> _tente(
    String label,
    Future<void> Function() geste,
  ) async {
    try {
      await geste();
      return ShareOutcome(label: label);
    } catch (e) {
      return ShareOutcome(label: label, erreur: e);
    }
  }
}

final sharePublisherProvider = Provider((ref) => SharePublisher(ref));
