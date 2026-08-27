-- Le canal de proximité se FERME quand les deux ne sont plus proches.
--
-- Décision de Jay du 2026-08-27 : *« On ferme le canal et le chat reste en
-- lecture seule et après 24 h sans échange il disparaît de la liste (lorsqu'il
-- n'y a plus aucun contenu). »*
--
-- ## ⚠️ Ce qui existait avant : une promesse que rien ne tenait
--
-- L'écran affichait, dès la sortie de portée, un bandeau orange :
-- *« Hors de portée — ce canal se fermera sans échange mutuel »*. **Rien ne
-- fermait quoi que ce soit** — vérifié dans les trois couches le 2026-08-27 :
--
--   1. `_Composer` n'avait aucun paramètre `enabled` : le champ de saisie
--      restait actif, et `outOfRange` ne servait qu'à peindre le bandeau ;
--   2. `messages_insert_member` ne vérifiait que l'appartenance et le TTL —
--      **aucune condition de proximité** ;
--   3. rien ne supprimait jamais une conversation.
--
-- Une conversation de proximité ouverte une fois restait donc ouverte **pour
-- toujours**, et les deux pouvaient s'écrire à des kilomètres. C'était un
-- contournement complet de la barrière de présence physique : il suffisait
-- d'ouvrir le canal une seule fois.
--
-- ## ⚠️ Pourquoi la règle est ICI et pas dans l'écran
--
-- Une règle qui vit dans l'interface n'est pas une règle : elle se contourne
-- avec n'importe quel client. Le bandeau restera, mais il ne sera plus seul —
-- il décrira ce que le serveur applique.
--
-- ## ⚠️ Pourquoi DIX MINUTES, et pas les 30 secondes du bandeau
--
-- C'est **le même seuil que l'ouverture du canal** (voir
-- `get_or_create_proximity_conversation`) et que la demande d'ami
-- (`request_connection_from_proximity`). Un seul nombre, une seule question :
-- *« leur proximité a-t-elle été constatée récemment ? »*
--
-- Prendre les 30 secondes de l'affichage produirait deux défauts :
--
--   * **une contradiction** — on pourrait rouvrir un canal (10 min) qu'on n'a
--     pas le droit d'utiliser (30 s) ;
--   * **des refus injustes** — le BLE perd des annonces en permanence, une
--     porte qui s'ouvre suffit à couper le signal. Les 30 secondes du bandeau
--     existent précisément pour absorber ça côté affichage ; les imposer à
--     l'écriture referait le défaut à l'envers.

-- ---------------------------------------------------------------------------
-- Le droit d'écrire, en un seul endroit
-- ---------------------------------------------------------------------------

create or replace function private.can_write_in_conversation(
  conv_id uuid,
  uid uuid
) returns boolean
language sql
stable
security definer
set search_path = public, private
as $$
  select case
    -- Une conversation directe ou de groupe n'a aucune condition de
    -- proximité : l'appartenance suffit, et c'est la politique qui la vérifie.
    when c.conversation_type <> 'proximity' then true
    else exists (
      select 1
      from public.conversation_members autre
      join public.ping_pairs pp
        on (pp.user_low = least(uid, autre.user_id)
            and pp.user_high = greatest(uid, autre.user_id))
      where autre.conversation_id = c.id
        and autre.user_id <> uid
        and pp.last_seen_at > now() - interval '10 minutes'
    )
  end
  from public.conversations c
  where c.id = conv_id;
$$;

-- ⚠️ **OBLIGATOIRE, et déjà payé une fois** (panne du 2026-08-11, `CLAUDE.md`).
-- Une politique s'évalue avec les droits de celui qui interroge : une fonction
-- citée par une politique et non exécutable par `authenticated` casse **toutes**
-- les écritures. Le schéma `private` n'étant pas exposé par PostgREST, ce GRANT
-- n'ouvre aucun chemin d'appel direct.
grant execute on function private.can_write_in_conversation(uuid, uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- La politique d'écriture
-- ---------------------------------------------------------------------------

drop policy if exists messages_insert_member on public.messages;

create policy messages_insert_member on public.messages
  for insert to authenticated
  with check (
    sender_id = (select auth.uid())
    and private.is_conversation_member(conversation_id, (select auth.uid()))
    and expires_at <= (now() + interval '24 hours')
    -- ⚠️ La ligne qui manquait. Sans elle, la barrière de présence physique
    -- tombait dès qu'un canal avait été ouvert une fois.
    and private.can_write_in_conversation(conversation_id, (select auth.uid()))
  );

comment on policy messages_insert_member on public.messages is
  'Écrire exige : être l''auteur, être membre, un TTL <= 24 h, et — pour un '
  'canal de PROXIMITÉ — une proximité mutuelle constatée depuis moins de 10 '
  'minutes. Ne pas retirer la dernière condition : c''est elle qui empêche '
  'qu''un canal ouvert une fois serve pour toujours (2026-08-27).';

-- ---------------------------------------------------------------------------
-- Le ménage : plus aucun contenu, plus de conversation
-- ---------------------------------------------------------------------------

-- ⚠️ **Une conversation de proximité VIDE n'a aucune raison de survivre.** Les
-- messages expirent à 24 h (cron `neovibe_purge`) : 24 heures après le dernier
-- échange, la conversation ne contient plus rien. Elle disparaît alors de la
-- liste — c'est la demande de Jay, et c'est cohérent avec l'éphémère.
--
-- ⚠️ **On supprime, on ne masque pas.** Masquer laisserait la ligne, ses deux
-- `conversation_members` et sa clé de paire : un objet que plus rien n'affiche
-- mais qui empêche encore d'en créer un autre (`pair_key` est unique).
-- Supprimer rouvre proprement le jour où les deux se recroisent.
--
-- ⚠️ **Sens sortant relevé avant d'écrire** (règle 8) : toutes les clés
-- étrangères vers `conversations` sont en `CASCADE` — `conversation_members`,
-- `messages`, `conversation_category_members`, `library_vibes`. La seule
-- exception est `content_grants.conversation_id`, en `SET NULL` — sans objet
-- ici : le canal de proximité est **limité au texte**, il n'a ni Vibe ni
-- bibliothèque. La garde `not exists (content_grants)` ci-dessous rend cette
-- affirmation vérifiable au lieu de la supposer.
--
-- ⚠️ **Le délai de grâce de 5 minutes** évite de détruire une conversation que
-- quelqu'un vient d'ouvrir depuis l'écran Ping et où il n'a pas encore écrit.
create or replace function public.purge_empty_proximity_conversations()
returns integer
language plpgsql
security definer
set search_path = public, private
as $$
declare
  supprimees integer;
begin
  with mortes as (
    delete from public.conversations c
    where c.conversation_type = 'proximity'
      and c.created_at < now() - interval '5 minutes'
      and not exists (
        select 1 from public.messages m where m.conversation_id = c.id
      )
      and not exists (
        select 1 from public.content_grants g where g.conversation_id = c.id
      )
    returning 1
  )
  select count(*) into supprimees from mortes;
  return supprimees;
end;
$$;

revoke all on function public.purge_empty_proximity_conversations() from public;

select cron.schedule(
  'neovibe_purge_proximity_conversations',
  '*/5 * * * *',
  $$ select public.purge_empty_proximity_conversations() $$
);
