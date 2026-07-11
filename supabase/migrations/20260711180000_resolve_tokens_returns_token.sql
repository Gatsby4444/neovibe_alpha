-- resolve_ble_tokens renvoie aussi le token scanné : nécessaire au client pour
-- associer chaque profil à la trame BLE correspondante. Pas de fuite : l'appelant
-- possède déjà ces tokens (il les a captés en scan).
drop function public.resolve_ble_tokens(uuid[]);

create or replace function public.resolve_ble_tokens(tokens uuid[])
returns table (ble_token uuid, user_id uuid, display_name text, avatar_url text, is_connected boolean)
language sql stable security definer set search_path = public, private
as $$
  select p.ble_token, p.id, p.display_name, p.avatar_url, are_connected(auth.uid(), p.id)
  from profiles p
  where p.ble_token = any (tokens)
    and p.id <> auth.uid();
$$;

revoke execute on function public.resolve_ble_tokens(uuid[]) from public, anon;
