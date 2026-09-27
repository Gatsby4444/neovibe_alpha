-- Retirer quelqu'un d'une soirée privée (ou la quitter) fonctionne enfin.
--
-- Trouvé le 2026-09-27 en traduisant les soirées pour le serveur Rust, puis
-- REPRODUIT sous l'identité de Charles (preuve `08_soirees`, situations
-- « retirer un invité de ma soirée privée » et « partir soi-même d'une
-- soirée privée ») : `remove_from_event` échouait À CHAQUE FOIS dès qu'il
-- arrivait à l'écriture :
--   column "left_reason" is of type event_leave_reason but expression is of type text
-- La raison de sortie était calculée par un `case` sur deux textes, que la
-- base refuse de ranger dans une colonne d'énumération. Le bouton
-- « Retirer » de l'app (`EventsRepository.remove`) ne pouvait donc jamais
-- réussir.
--
-- Réparation : la valeur est convertie en `event_leave_reason`. Rien
-- d'autre ne change.
create or replace function public.remove_from_event(p_event uuid, p_user uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'private'
as $$
declare
  me uuid := auth.uid();
  e public.events;
begin
  if me is null then raise exception 'Non authentifié'; end if;
  select * into e from public.events where id = p_event;
  if not found or e.kind <> 'private' then raise exception 'Événement introuvable'; end if;
  if p_user = e.created_by then raise exception 'Le créateur ne se retire pas'; end if;
  if p_user <> me and not private.may_remove_from_event(p_event, me) then
    raise exception 'Tu ne peux pas retirer quelqu''un ici';
  end if;
  update public.event_presences
     set left_at = now(),
         left_reason = (case when p_user = me then 'manual' else 'removed' end)::public.event_leave_reason
   where event_id = p_event and user_id = p_user and left_at is null;
  delete from public.event_positions where event_id = p_event and user_id = p_user;
  delete from public.event_group_members where event_id = p_event and user_id = p_user;
  delete from public.conversation_members
   where conversation_id = e.conversation_id and user_id = p_user;
end;
$$;
