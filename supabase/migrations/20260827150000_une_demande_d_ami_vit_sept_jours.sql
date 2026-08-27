-- Une demande d'ami vit SEPT JOURS, et il n'y a plus qu'un endroit qui le dit.
--
-- Décision de Jay du 2026-08-27, après le constat suivant : la durée de vie
-- d'une demande de proximité était écrite à **trois endroits**, avec deux
-- valeurs différentes.
--
-- | Où | Valeur | Effet réel |
-- |---|---|---|
-- | `request_connection_from_proximity` | `now() + 7 days` | ce qui est posé à l'insertion |
-- | le défaut de la colonne `expires_at` | `now() + 90 secondes` | ce que reçoit tout AUTRE chemin d'insertion |
-- | `ProximityRepository._refresh()` (client) | réécrit à `now() + 90 s` | **écrasait les 7 jours en moins de 30 secondes** |
--
-- ⚠️ **La prémisse est morte, pas la règle.** « La demande expire dès que les
-- appareils sortent de portée » (spec 4.2) était juste tant qu'il fallait être
-- **à portée pour répondre** : la réponse voyageait dans le canal BLE co-signé.
-- Depuis le 2026-08-27, répondre est un appel serveur ordinaire — on accepte de
-- n'importe où, n'importe quand. L'expiration rapide ne protège donc plus rien.
--
-- ⚠️ **Et elle ne se contentait pas de masquer.** Le cron `neovibe_purge`
-- passe toutes les cinq minutes et fait :
--
--     update connection_requests set status = 'expired'
--       where status = 'pending' and expires_at < now();
--
-- Une demande raccourcie à 90 secondes était donc **détruite définitivement**
-- une minute et demie après que les deux personnes se soient séparées. Ce
-- n'était pas un affichage qui disparaissait : c'était la demande elle-même.
--
-- ⚠️ **La barrière de présence physique n'est PAS affaiblie par ce changement.**
-- Elle est vérifiée **à l'émission**, et elle le reste : sans paire mutuelle de
-- moins de dix minutes, `request_connection_from_proximity` refuse. Ce qui
-- change n'est pas qui peut demander — c'est combien de temps la personne d'en
-- face a pour répondre.
--
-- ⚠️ **Ce défaut de colonne n'était atteignable par aucun chemin vivant** :
-- `request_connection_from_proximity` est le seul à insérer (vérifié le
-- 2026-08-27, côté serveur ET côté Dart). Il est corrigé quand même — la
-- politique `requests_insert_sender` autorise encore une insertion directe
-- (`RAPPELS.md` #70), et le jour où un chemin la reprendrait, il hériterait
-- d'une valeur que plus personne n'assume.

alter table public.connection_requests
  alter column expires_at set default (now() + interval '7 days');

comment on column public.connection_requests.expires_at is
  'Sept jours. Au-delà, le cron neovibe_purge passe la demande en `expired`. '
  'Ne pas raccourcir depuis le client : répondre ne demande plus d''être à '
  'portée (2026-08-27).';
