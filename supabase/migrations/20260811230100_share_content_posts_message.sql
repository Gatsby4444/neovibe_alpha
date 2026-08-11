-- Le repartage devient VISIBLE : `share_content` poste désormais un message
-- dans la conversation, en plus d'ajouter les chemins d'accès.
--
-- Sans lui, la fonctionnalité était livrée à moitié : le destinataire obtenait
-- le droit d'ouvrir un contenu qu'il n'avait **aucun moyen de trouver**. Le
-- mécanisme serveur existait sans son point d'entrée.

alter table public.messages
  add column if not exists content_id uuid
    references public.contents (id) on delete set null;

-- `on delete set null`, et surtout **pas** `cascade` : quand la source
-- disparaît (story expirée, publication retirée, contenu révoqué), le message
-- RESTE et affiche « ce contenu n'est plus disponible ».
--
-- C'est la règle arrêtée par Jay : la référence meurt avec la source, mais
-- elle le dit au lieu de s'évaporer en silence. Un raccourci vers rien doit
-- s'annoncer comme tel.

create or replace function public.share_content(
  p_content_id uuid,
  p_conversation_id uuid
)
returns integer
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_me uuid := auth.uid();
  v_shareable boolean;
  v_context public.content_context;
  v_added integer;
begin
  select shareable, context into v_shareable, v_context
  from contents where id = p_content_id and revoked_at is null;

  if not found then
    raise exception 'Contenu introuvable';
  end if;

  -- Un partage direct dans le cercle n'est JAMAIS repartageable : il s'adresse
  -- à des personnes nommées. Idem pour une bibliothèque de conversation, qui
  -- appartient à ses membres.
  if v_context = 'direct' or v_context = 'conversation_library' then
    raise exception 'Ce contenu n''est pas partageable';
  end if;

  if not v_shareable then
    raise exception 'Ce contenu n''est pas partageable';
  end if;

  -- Faire partie de l'audience suffit pour relayer : c'est cette seule
  -- condition qui produit la propagation sans limite de sauts.
  if not private.content_audience(p_content_id, v_me) then
    raise exception 'Contenu introuvable';
  end if;

  if not exists (
    select 1 from conversation_members
    where conversation_id = p_conversation_id and user_id = v_me
  ) then
    raise exception 'Conversation introuvable';
  end if;

  insert into content_grants (content_id, grantee_id, granted_by, conversation_id)
  select p_content_id, m.user_id, v_me, p_conversation_id
  from conversation_members m
  where m.conversation_id = p_conversation_id
    and m.user_id <> v_me;

  get diagnostics v_added = row_count;

  -- Le message qui rend le partage visible. Il suit le TTL de 24 h des
  -- messages comme tout le reste du fil : la conversation est éphémère par
  -- conception, donc la référence l'est aussi — **même quand le contenu visé
  -- est permanent**. La publication, elle, reste dans la bibliothèque.
  insert into messages (conversation_id, sender_id, kind, content_id)
  values (p_conversation_id, v_me, 'content_share', p_content_id);

  return v_added;
end;
$$;

revoke all on function public.share_content(uuid, uuid) from public, anon;
grant execute on function public.share_content(uuid, uuid) to authenticated;
