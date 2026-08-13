-- La purge des stories supprimait le MAUVAIS BOUT du graphe.
--
-- `stories.id` référence `contents.id` avec `on delete cascade` : supprimer le
-- CONTENU emporte la story. L'inverse est faux — supprimer la story laissait
-- derrière elle le `contents`, son `content_media_keys`, ses `content_grants`
-- et ses `content_views`.
--
-- Relevé en base le 2026-08-13 : 14 `contents` orphelins de contexte `story`,
-- 14 clés, 6 autorisations, et 26 objets dans le coffre `stories` — pour
-- ZÉRO story vivante. La table grossissait sans borne, et la clé d'un contenu
-- survivait au contenu.
--
-- ⚠️ Ce n'était PAS une faille de confidentialité : `private.can_view_story_file`
-- interroge `stories`, donc la disparition de cette ligne suffisait déjà à
-- interdire toute lecture. Mais c'est exactement la « sécurité qui s'énonce par
-- une négation » que la règle 4 de `CLAUDE.md` proscrit — rien n'était lisible
-- *parce que plus rien ne l'indexait*, pas parce que ça n'existait plus.
--
-- ⚠️ Les OCTETS restent dans le coffre : `storage.objects` n'a aucune clé
-- étrangère vers le contenu, et la suppression directe y est refusée par le
-- trigger `storage.protect_delete`. Fuite de stockage inscrite en
-- `RAPPELS.md` (avant-prod #16).
--
-- ⚠️ `cron.schedule` REMPLACE un job de même nom : la commande est réécrite
-- ENTIÈREMENT, tout ce qui n'est pas recopié serait perdu en silence.
select cron.schedule(
  'neovibe_purge',
  '*/5 * * * *',
  $job$
  delete from public.messages where expires_at < now();
  update public.connection_requests set status = 'expired'
    where status = 'pending' and expires_at < now();
  update public.recommendations set status = 'expired'
    where status in ('requested', 'forwarded') and expires_at < now();
  delete from public.connections
    where status = 'partial' and partial_expires_at < now();
  delete from public.encounters where last_seen_at < now() - interval '24 hours';
  delete from public.contents c
    where c.context = 'story'
      and exists (select 1 from public.stories s
                  where s.id = c.id and s.expires_at < now());
  $job$
);

-- Rattrapage des orphelins déjà accumulés : un contenu de story sans story.
delete from public.contents c
where c.context = 'story'
  and not exists (select 1 from public.stories s where s.id = c.id);
