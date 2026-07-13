-- Durcissement des fonctions du chantier BLE (advisors Supabase) :
-- search_path figé (pas de détournement par un schéma utilisateur) et
-- exécution interdite aux non-authentifiés (anon).

create or replace function private.verify_ed25519(
  message text, sig_b64 text, pub_b64 text
) returns boolean
language plpgsql immutable
set search_path = pgsodium, public as $$
begin
  return pgsodium.crypto_sign_verify_detached(
    decode(sig_b64, 'base64'),
    convert_to(message, 'utf8'),
    decode(pub_b64, 'base64')
  );
exception when others then
  return false;
end;
$$;

revoke execute on function public.report_encounter(jsonb) from anon, public;
revoke execute on function public.submit_ble_connection(jsonb) from anon, public;
grant execute on function public.report_encounter(jsonb) to authenticated;
grant execute on function public.submit_ble_connection(jsonb) to authenticated;
