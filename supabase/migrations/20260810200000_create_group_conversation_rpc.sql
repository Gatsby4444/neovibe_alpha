-- Creation de groupe : erreur 42501 signalee par Jay au test de la v0.9.44.
--
-- ─── Cause reelle, diagnostiquee en base et non supposee ────────────────────
-- Le client faisait `.insert({...}).select().single()`. PostgREST ajoute alors
-- un RETURNING, et PostgreSQL applique la politique **SELECT** a la ligne
-- renvoyee. Or cette politique est `is_conversation_member(id, auth.uid())` :
-- au moment de l'insertion, le createur n'est PAS encore membre — il ne le
-- devient qu'a l'insertion suivante dans `conversation_members`. La ligne
-- etait donc bien creee, puis refusee au retour.
--
-- Preuves relevees : la meme insertion SANS returning passe ; et ajouter une
-- politique d'insertion `with check (true)` ne change rien — ce n'etait donc
-- pas la politique d'INSERT qui bloquait, contrairement a ce que le message
-- d'erreur laisse croire.
--
-- ─── Correctif ─────────────────────────────────────────────────────────────
-- Une RPC SECURITY DEFINER, exactement comme le font deja
-- `get_or_create_direct_conversation` et `get_or_create_proximity_conversation`.
-- Les groupes etaient le SEUL type de conversation a passer par des insertions
-- brutes depuis le client — c'est pour cela qu'eux seuls cassaient.
--
-- Benefice supplementaire : la creation devient ATOMIQUE (conversation,
-- createur et membres dans une transaction) au lieu de trois allers-retours
-- dont les derniers pouvaient echouer en laissant un groupe a moitie forme.

create or replace function public.create_group_conversation(
  p_title text,
  p_member_ids uuid[] default '{}'
)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_me uuid := auth.uid();
  v_id uuid;
  v_member uuid;
begin
  if v_me is null then
    raise exception 'Non authentifie';
  end if;

  insert into conversations (conversation_type, title, created_by)
  values ('group', nullif(btrim(coalesce(p_title, '')), ''), v_me)
  returning id into v_id;

  -- Le createur d'abord : c'est son adhesion qui rend la conversation visible.
  insert into conversation_members (conversation_id, user_id)
  values (v_id, v_me);

  -- On n'ajoute que des CONNEXIONS etablies : la regle fondatrice du produit
  -- est qu'on n'entre pas dans le cercle de quelqu'un sans lien prealable.
  -- Un identifiant sans connexion est ignore en silence plutot que de faire
  -- echouer toute la creation.
  --
  -- NB : les colonnes sont `user_low` / `user_high` (paire ordonnee) et le
  -- statut d'un lien etabli est 'full' — releve en base, une premiere version
  -- de cette fonction supposait `user_a`/`user_b` et 'active'.
  foreach v_member in array coalesce(p_member_ids, '{}')
  loop
    if v_member <> v_me and exists (
      select 1 from connections c
      where c.status = 'full'
        and c.user_low = least(v_me, v_member)
        and c.user_high = greatest(v_me, v_member)
    ) then
      insert into conversation_members (conversation_id, user_id)
      values (v_id, v_member)
      on conflict do nothing;
    end if;
  end loop;

  return v_id;
end;
$fn$;

revoke execute on function public.create_group_conversation(text, uuid[])
  from public, anon;
grant execute on function public.create_group_conversation(text, uuid[])
  to authenticated;
