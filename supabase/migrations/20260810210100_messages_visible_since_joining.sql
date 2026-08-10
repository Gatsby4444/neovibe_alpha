-- Regle d'acces decidee par Jay, 2026-08-10 :
--
--   « un nouveau membre du groupe peut avoir acces a la bibliotheque depuis le
--     debut du groupe, mais a la conversation uniquement depuis son arrivee. »
--
-- La BIBLIOTHEQUE est deja conforme : sa politique de lecture ne regarde que
-- l'appartenance, sans date — un nouveau membre voit donc tous les albums,
-- depuis le premier jour. C'est voulu : la bibliotheque est la MEMOIRE du
-- groupe, elle se partage en entier.
--
-- Les MESSAGES ne l'etaient pas : la politique testait l'appartenance et la
-- date d'expiration, jamais la date d'arrivee. En pratique le TTL de 24 h
-- limitait deja beaucoup la fuite — un arrivant ne voyait que les messages des
-- dernieres 24 h — mais la regle n'etait pas ECRITE, et elle ne doit pas
-- dependre d'un reglage de purge susceptible de changer.

drop policy if exists messages_select_member_unexpired on public.messages;

create policy messages_select_member_unexpired on public.messages
  for select to authenticated
  using (
    private.is_conversation_member(conversation_id, (select auth.uid()))
    and expires_at > now()
    -- Rien de ce qui precede l'arrivee : la conversation ne se rattrape pas.
    and created_at >= (
      select m.joined_at from conversation_members m
      where m.conversation_id = messages.conversation_id
        and m.user_id = (select auth.uid())
    )
  );
