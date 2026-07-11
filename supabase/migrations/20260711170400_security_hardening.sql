-- NeoVibe V1 — durcissement suite aux advisors Supabase
-- 1) Les helpers RLS partent dans un schéma `private` non exposé par l'API REST
--    (sinon tout utilisateur authentifié pourrait sonder le graphe social via RPC).
-- 2) Révocation des EXECUTE anon/public sur les RPC et fonctions trigger.

create schema if not exists private;
grant usage on schema private to authenticated, anon;

-- Déplacement (les policies référencent les fonctions par OID : elles suivent)
alter function public.are_connected(uuid, uuid) set schema private;
alter function public.has_any_connection(uuid, uuid) set schema private;
alter function public.is_conversation_member(uuid, uuid) set schema private;
alter function public.can_view_profile(uuid, uuid) set schema private;
alter function public.can_view_library(uuid, uuid) set schema private;

-- Les corps de fonctions résolvent les noms via search_path au moment de l'appel :
-- toute fonction qui appelle un helper doit maintenant voir `private`.
alter function private.can_view_profile(uuid, uuid) set search_path = public, private;
alter function private.can_view_library(uuid, uuid) set search_path = public, private;
alter function private.are_connected(uuid, uuid) set search_path = public, private;
alter function private.has_any_connection(uuid, uuid) set search_path = public, private;
alter function private.is_conversation_member(uuid, uuid) set search_path = public, private;
alter function public.resolve_ble_tokens(uuid[]) set search_path = public, private;
alter function public.forward_recommendation(uuid, uuid) set search_path = public, private;
alter function public.get_or_create_direct_conversation(uuid) set search_path = public, private;
alter function public.get_or_create_proximity_conversation(uuid) set search_path = public, private;
alter function public.enforce_card_delivery_rules() set search_path = public, private;

-- search_path immuable sur le trigger updated_at
alter function public.set_updated_at() set search_path = '';

-- Fonctions trigger : jamais appelables via l'API (le déclenchement par trigger
-- ne vérifie pas EXECUTE au runtime, seulement à la création du trigger)
revoke execute on function public.enforce_message_rules() from public, anon, authenticated;
revoke execute on function public.maybe_create_partial_connection() from public, anon, authenticated;
revoke execute on function public.enforce_card_delivery_rules() from public, anon, authenticated;
revoke execute on function public.enforce_library_card_rules() from public, anon, authenticated;
revoke execute on function public.set_updated_at() from public, anon, authenticated;

-- RPC métier : réservés aux utilisateurs connectés (jamais anon)
revoke execute on function public.resolve_ble_tokens(uuid[]) from public, anon;
revoke execute on function public.accept_connection_request(uuid) from public, anon;
revoke execute on function public.decline_connection_request(uuid) from public, anon;
revoke execute on function public.forward_recommendation(uuid, uuid) from public, anon;
revoke execute on function public.accept_recommendation(uuid) from public, anon;
revoke execute on function public.decline_recommendation(uuid) from public, anon;
revoke execute on function public.get_or_create_direct_conversation(uuid) from public, anon;
revoke execute on function public.get_or_create_proximity_conversation(uuid) from public, anon;
revoke execute on function public.confirm_partial_connection(uuid) from public, anon;
revoke execute on function public.mark_card_viewed(uuid) from public, anon;
revoke execute on function public.destroy_oneshot(uuid) from public, anon;

-- Helpers dans private : EXECUTE nécessaire à l'évaluation des policies RLS
-- (exécutées avec les droits de l'utilisateur courant), mais plus d'exposition REST.
grant execute on function private.are_connected(uuid, uuid) to authenticated, anon;
grant execute on function private.has_any_connection(uuid, uuid) to authenticated, anon;
grant execute on function private.is_conversation_member(uuid, uuid) to authenticated, anon;
grant execute on function private.can_view_profile(uuid, uuid) to authenticated, anon;
grant execute on function private.can_view_library(uuid, uuid) to authenticated, anon;
